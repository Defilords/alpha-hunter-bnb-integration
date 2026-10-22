// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {IPancakeRouter} from "./interfaces/IPancakeRouter.sol";
import {IPancakeV3SwapRouter} from "./interfaces/IPancakeV3SwapRouter.sol";
import {IPositionOracle} from "./interfaces/IPositionOracle.sol";
import {IERC20DecimalsMinimal} from "./interfaces/IERC20DecimalsMinimal.sol";
import {V3Path} from "./libraries/V3Path.sol";

/**
 * @title PositionManager
 * @notice Self-directed trading for Alpha Hunter (14 Oct 2026 build brief,
 *         from Ted Baker). Separate from AlphaSelectVault -- users open and
 *         close their OWN positions here, in their own tokens; the vault
 *         keeps running unchanged alongside. Quote currency is USDT on BSC
 *         only. Non-upgradeable for the first release, per the brief.
 *
 *         Reused from the vault, same patterns, not copied verbatim:
 *           - PriceOracle: getChainlinkPriceWad / checkTwapDivergence /
 *             getTier / hasFeed, via the new, narrow IPositionOracle (see
 *             that file's header for why it isn't IPriceOracleView).
 *           - The vault's V2/V3 swap shape (router + path allowlist checks,
 *             balance-delta accounting, custom-error style, exact-amount
 *             approve-then-swap).
 *           - V3Path.tokens() for V3 hop decoding/allowlist checks.
 *         NOT reused: ValuationLib. Its public functions take a per-token
 *         spot-pool (`pool`, `quoteToken`) PositionManager has no registry
 *         for -- it's the vault's own TWAP/spot-fallback machinery, not a
 *         general "value this token" utility. Every USD value here goes
 *         through `_checkedPrice`, exactly the function the brief itself
 *         specifies for trigger pricing, reused for open/close pricing too
 *         rather than introducing a second valuation path.
 *
 *         Known build-brief gap, flagged rather than silently resolved
 *         (see the PR/report, "contradictions" section): `_checkedPrice`
 *         as specified calls `checkTwapDivergence`, which internally calls
 *         `getTwapPriceWad`, which REQUIRES an active TWAP source for the
 *         token. PriceOracle no longer enforces Chainlink/TWAP mutual
 *         exclusion (the S1 fix), so dual registration is POSSIBLE, but it
 *         is not the default state of any token today. A Chainlink-only
 *         token (the common case right now) makes every `_checkedPrice`
 *         call -- and therefore every position open/trigger check -- revert
 *         until that token also gets an active TWAP source registered on
 *         the oracle. This is an operational prerequisite, not a bug in
 *         this contract; built exactly as specified rather than silently
 *         loosening it to "TWAP-check only if configured". It also applies
 *         to WBNB specifically: `_gasCostUsdt` calls `_checkedPrice(WBNB)`
 *         on every gas-repaying action regardless of which token a position
 *         holds, so WBNB needs the same dual registration or EVERY gas
 *         repayment reverts, not just trades in a Chainlink-only token.
 */
contract PositionManager is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    // ── Roles ────────────────────────────────────────────────────────────
    bytes32 public constant FEE_MANAGER_ROLE = keccak256("FEE_MANAGER_ROLE");
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");

    // ── Swap routing ─────────────────────────────────────────────────────
    /// @dev The brief asks for "V2 path or V3 path + router, as in the
    /// vault" but the vault itself has no single SwapRoute type -- it has
    /// two separate entrypoints (executeSwap / executeSwapV3). This struct
    /// is PositionManager's own unification of that, flagged as a design
    /// choice, not a literal reuse.
    struct SwapRoute {
        bool isV3;
        address router;
        address[] path;   // V2 only; must start at tokenIn, end at tokenOut
        bytes v3Path;      // V3 only; token | fee(uint24) | token | ...
    }

    // ── Triggers / Position ─────────────────────────────────────────────
    struct Triggers {
        uint256 stopLossPrice;    // WAD; 0 = off. Fires at or below.
        uint256 takeProfitPrice;  // WAD; 0 = off. Fires at or above.
        uint16 trailingBps;       // trailing stop, % below peakPrice; 0 = off
        uint16 activationBps;     // trailing profit: gain over entry needed to arm; 0 = off
        uint16 trailProfitBps;    // trailing profit: % below profitPeak once armed
        uint16 lockBps;           // trailing profit: minimum gain locked once armed
        uint16 maxSlippageBps;    // worst slippage accepted on an automatic close
    }

    enum Status { None, Open, Closed }

    struct Position {
        address owner;
        address token;
        uint128 quantity;   // token units held for this position
        uint64 openedAt;
        Status status;
        uint16 feeBpsAtOpen; // caps the close fee
        bool profitArmed;
        uint256 entryPrice;  // WAD, oracle price at open
        uint256 peakPrice;   // WAD, trailing stop high; only rises
        uint256 profitPeak;  // WAD, trailing profit high since arming; only rises
        uint256 gasOwedUsdt; // keeper gas accrued (peak updates), repaid at close
        uint256 usdtIn;      // exact USDT committed at open (pre-fee) -- the SAME value totalOpenUsdt
            // was incremented by, so decrementing by this exact field on every close/withdraw path
            // can never drift from what was actually added, no matter how the swap actually filled.
        Triggers triggers;
    }

    mapping(uint256 => Position) public positions;
    mapping(address => uint256[]) internal _positionsOf;
    uint256 public nextPositionId;

    // ── Fixed infra ──────────────────────────────────────────────────────
    IERC20 public immutable asset; // USDT, 18 decimals on BSC
    address public immutable WBNB;
    IPositionOracle public oracle;

    // ── Fee ──────────────────────────────────────────────────────────────
    uint16 public constant MAX_FEE_BPS = 300; // hard ceiling (3%)
    uint16 public tradeFeeBps;
    uint16 public pendingFeeBps;
    uint64 public pendingFeeEta; // raise takes effect after FEE_RAISE_DELAY
    uint64 public constant FEE_RAISE_DELAY = 48 hours;
    address public feeRecipient;

    // ── Gas repayment ────────────────────────────────────────────────────
    uint256 public gasUnitsTriggerClose; // fixed gas estimate per action, set by admin
    uint256 public gasUnitsPokePeak;
    uint256 public maxGasPriceWei; // cap on tx.gasprice used in repayment
    uint256 public maxGasRepayPerPositionUsdt;
    address public keeperGasRecipient; // not named in the brief's function list, but
    // named in its role table ("admin changes ... keeperGasRecipient") -- added a
    // setter (setKeeperGasRecipient) alongside the admin functions given verbatim.

    // ── Limits and allowlists ────────────────────────────────────────────
    mapping(address => bool) public tokenAllowed;
    /// @dev Read and stored ONCE, in setTokenAllowed, the moment a token is enabled -- every value
    /// calculation (open's slippage band, closeByTrigger's minUsdtOut) divides by 10**tokenDecimals[token]
    /// instead of a hardcoded 1e18, since a token's raw `quantity` is in ITS OWN decimals, not USDT's.
    mapping(address => uint8) public tokenDecimals;
    mapping(address => bool) public routerAllowed;
    uint256 public minPositionUsdt;
    uint256 public maxPositionUsdt;
    uint256 public totalOpenCapUsdt;
    uint256 public totalOpenUsdt; // running total of USDT committed to open positions; not in the
    // brief's storage list, but needed to enforce totalOpenCapUsdt at all -- the brief names the cap
    // but never a counter to check it against.
    bool public userAllowlistEnabled;
    mapping(address => bool) public userAllowed;
    bool public openingPaused; // never blocks closes or withdrawals

    /// @dev Also not in the brief's storage list, but required by the
    /// `_checkedPrice` function the brief specifies verbatim (it reads
    /// `maxPriceAge`). Admin-settable via `setMaxPriceAge`, proposed
    /// default 3600s (1h) -- not sourced from any stated requirement,
    /// flagged for Richard/Ted to confirm.
    uint256 public maxPriceAge;

    /// @dev Per-token override of maxPriceAge (Richard, 16 Oct: ~15 min for BNB/ETH/BTC, looser
    /// for thinner tokens). 0 = unset, falls back to the global maxPriceAge above -- so a token
    /// never has NO staleness limit, it just inherits the global one until explicitly overridden.
    mapping(address => uint32) public maxPriceAgeByToken;

    /// @dev PositionManager's OWN Chainlink-vs-TWAP divergence tolerance (Richard, 16 Oct), used
    /// in _checkedPrice INSTEAD of oracle.checkTwapDivergence/deviationBpsByToken. That value is
    /// live mainnet storage SHARED with the vault's own Chainlink-vs-spot divergence check (5%
    /// today) -- PositionManager moving it would weaken the vault's check too, and 5% is too tight
    /// for trigger prices that need to tolerate a lagging TWAP during a fast real move. Computed
    /// locally from oracle.getTwapPriceWad(token), same percentage-of-trusted-price formula
    /// PriceOracle's own _withinTolerance uses, just against this contract's own setting. Same
    /// global+per-token override shape as maxPriceAge/maxPriceAgeByToken above.
    uint16 public twapToleranceBps;
    mapping(address => uint16) public twapToleranceBpsByToken;

    uint16 public constant MAX_TRIGGER_BPS = 5_000; // 50% ceiling on every trigger bps field
    uint16 public constant MAX_TRIGGER_SLIPPAGE_BPS = 300; // contract maximum for maxSlippageBps

    // ── Events ───────────────────────────────────────────────────────────
    event PositionOpened(
        uint256 indexed id, address indexed owner, address indexed token,
        uint256 usdtIn, uint256 fee, uint256 quantity, uint256 entryPrice
    );
    event TriggersUpdated(uint256 indexed id, Triggers triggers);
    event PeakUpdated(uint256 indexed id, uint256 peakPrice, uint256 profitPeak, bool profitArmed);
    event PositionClosed(
        uint256 indexed id, address indexed owner, uint8 reason, // 0 manual, 1-4 trigger
        uint256 usdtOut, uint256 fee, uint256 gasRepaid, uint256 price
    );
    event WithdrawnInKind(uint256 indexed id, address indexed owner, uint256 quantity);
    event FeeCharged(uint256 indexed id, uint8 side, uint256 amount); // 0 open, 1 close
    event FeeChanged(uint16 oldBps, uint16 newBps);
    event FeeRaiseScheduled(uint16 bps, uint64 eta);
    // Not in the brief's own event list; every admin setter below now emits one, so a role change,
    // a limit change, an allowlist change, etc. is reconstructable from logs alone, same reasoning
    // as every other write in this contract.
    event TokenAllowedSet(address indexed token, bool allowed);
    event RouterAllowedSet(address indexed router, bool allowed);
    event OracleSet(address indexed oracle);
    event FeeRecipientSet(address indexed to);
    event KeeperGasRecipientSet(address indexed to);
    event LimitsSet(uint256 minUsdt, uint256 maxUsdt, uint256 totalCapUsdt);
    event GasRepaySet(uint256 unitsClose, uint256 unitsPoke, uint256 maxGasPrice, uint256 maxPerPosition);
    event UserAllowlistSet(bool enabled);
    event UserAllowedSet(address indexed user, bool allowed);
    event MaxPriceAgeSet(uint256 seconds_);
    event MaxPriceAgeForTokenSet(address indexed token, uint32 seconds_);
    event TwapToleranceBpsSet(uint16 bps);
    event TwapToleranceBpsForTokenSet(address indexed token, uint16 bps);
    event OpeningPausedSet(bool paused);

    // ── Errors ───────────────────────────────────────────────────────────
    error NotOwner();
    error NotOpen();
    error TriggerNotMet();
    error PriceStale(address token);
    error TokenNotAllowed(address token);
    error RouterNotAllowed(address router);
    error BadTriggers();
    error SizeOutOfRange();
    error CapReached();
    error OpeningPaused();
    error UserNotAllowed();
    error FeeTooHigh();
    error FeeRaiseNotReady();
    error SlippageExceeded();
    error ZeroAddress(); // not in the brief's list; used only for constructor/setter zero-checks
    error BadRoute();    // not in the brief's list; SwapRoute shape/path mismatch (this contract's
    // own addition, see SwapRoute's header -- the brief's error list predates that struct existing)
    error DecimalsTooHigh(); // not in the brief's list; setTokenAllowed rejects a token with >18 decimals

    constructor(
        address asset_,
        address wbnb_,
        address oracle_,
        address admin,
        address feeManager,
        address guardian,
        address keeper,
        address feeRecipient_,
        address keeperGasRecipient_
    ) {
        if (
            asset_ == address(0) || wbnb_ == address(0) || oracle_ == address(0) || admin == address(0)
                || feeManager == address(0) || guardian == address(0) || keeper == address(0)
                || feeRecipient_ == address(0) || keeperGasRecipient_ == address(0)
        ) revert ZeroAddress();

        asset = IERC20(asset_);
        WBNB = wbnb_;
        oracle = IPositionOracle(oracle_);
        feeRecipient = feeRecipient_;
        keeperGasRecipient = keeperGasRecipient_;

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(FEE_MANAGER_ROLE, feeManager);
        _grantRole(GUARDIAN_ROLE, guardian);
        _grantRole(KEEPER_ROLE, keeper);

        tradeFeeBps = 50; // proposed start, 0.5%
        maxPositionUsdt = 500 ether; // beta, proposed; USDT is 18 decimals on BSC
        maxPriceAge = 3600; // proposed, see the storage-section note above
        twapToleranceBps = 1500; // proposed default (15%), Richard/Anand's value to confirm
        maxGasRepayPerPositionUsdt = 0.10 ether; // proposed ~0.10 USDT
    }

    // ════════════════════════════════════════════════════════════════════
    // Users
    // ════════════════════════════════════════════════════════════════════

    function openPosition(
        address token,
        uint256 usdtIn,
        SwapRoute calldata route,
        uint256 minTokensOut,
        Triggers calldata triggers,
        uint256 deadline
    ) external nonReentrant returns (uint256 id) {
        if (openingPaused) revert OpeningPaused();
        if (!tokenAllowed[token]) revert TokenNotAllowed(token);
        if (!routerAllowed[route.router]) revert RouterNotAllowed(route.router);
        if (userAllowlistEnabled && !userAllowed[msg.sender]) revert UserNotAllowed();
        if (!(usdtIn >= minPositionUsdt && usdtIn <= maxPositionUsdt)) revert SizeOutOfRange();
        if (totalOpenUsdt + usdtIn > totalOpenCapUsdt) revert CapReached();

        asset.safeTransferFrom(msg.sender, address(this), usdtIn);

        uint256 fee = _fee(usdtIn, tradeFeeBps);
        emit FeeCharged(nextPositionId, 0, fee);
        if (fee > 0) asset.safeTransfer(feeRecipient, fee);
        uint256 usdtForSwap = usdtIn - fee;

        uint256 quantity = _swap(route, address(asset), token, usdtForSwap, minTokensOut, deadline);

        // Oracle slippage band: the brief doesn't name which bps bounds this
        // check at open (only "the oracle slippage band"); reused the same
        // triggers.maxSlippageBps the caller is already submitting and
        // having validated below, rather than inventing a second field.
        // Flagged for confirmation -- see the PR report.
        // Value math uses THIS token's own decimals, not a hardcoded 1e18 --
        // `quantity` is in token units, which a non-18-decimal token (e.g.
        // 8-decimal DOGE on BSC) would otherwise misvalue by a factor of
        // 10**(18-decimals), rejecting every fair-priced fill as "slippage".
        uint256 priceWad = _checkedPrice(token);
        uint256 valueOutUsd = (uint256(quantity) * priceWad) / (10 ** tokenDecimals[token]);
        uint256 minAcceptableUsd = (usdtForSwap * (10_000 - triggers.maxSlippageBps)) / 10_000;
        if (valueOutUsd < minAcceptableUsd) revert SlippageExceeded();

        _validateTriggers(triggers, priceWad);

        id = nextPositionId++;
        positions[id] = Position({
            owner: msg.sender,
            token: token,
            quantity: quantity.toUint128(), // reverts on overflow instead of silently truncating
            openedAt: uint64(block.timestamp),
            status: Status.Open,
            feeBpsAtOpen: tradeFeeBps,
            profitArmed: false,
            entryPrice: priceWad,
            peakPrice: priceWad,
            profitPeak: 0,
            gasOwedUsdt: 0,
            usdtIn: usdtIn, // exact pre-fee amount -- see the Position struct's own comment
            triggers: triggers
        });
        _positionsOf[msg.sender].push(id);
        totalOpenUsdt += usdtIn;

        emit PositionOpened(id, msg.sender, token, usdtIn, fee, quantity, priceWad);
    }

    function updateTriggers(uint256 id, Triggers calldata triggers) external {
        Position storage p = positions[id];
        if (p.status != Status.Open) revert NotOpen();
        if (p.owner != msg.sender) revert NotOwner();
        // Never touches peakPrice / profitPeak / profitArmed -- see the
        // contract header and this function's own omission of those three
        // fields from every write below. A user cannot reset them to dodge
        // a trigger.
        _validateTriggers(triggers, p.entryPrice);
        p.triggers = triggers;
        emit TriggersUpdated(id, triggers);
    }

    function closePosition(
        uint256 id,
        SwapRoute calldata route,
        uint256 minUsdtOut,
        uint256 deadline
    ) external nonReentrant {
        Position storage p = positions[id];
        if (p.status != Status.Open) revert NotOpen();
        if (p.owner != msg.sender) revert NotOwner();
        // price=0 on a manual close, deliberately: fetching it here would
        // mean a broken/diverging oracle could block the owner's own
        // manual exit, which must always be available regardless of
        // oracle health (same reasoning as withdrawInKind).
        _close(id, p, route, minUsdtOut, deadline, 0 /* manual */, 0);
    }

    function withdrawInKind(uint256 id) external nonReentrant {
        Position storage p = positions[id];
        if (p.status != Status.Open) revert NotOpen();
        if (p.owner != msg.sender) revert NotOwner();
        // Deliberately no pause check, no oracle read: must work "while
        // paused and while the oracle is down" per the brief. Gas owed is
        // skipped (proposed) -- there is no USDT proceeds to take it from.
        uint256 qty = p.quantity;
        address token = p.token;
        p.status = Status.Closed; // before the external transfer, same CEI principle as _close
        totalOpenUsdt -= Math.min(p.usdtIn, totalOpenUsdt); // see _close's matching comment
        IERC20(token).safeTransfer(msg.sender, qty);
        emit WithdrawnInKind(id, msg.sender, qty);
    }

    // ════════════════════════════════════════════════════════════════════
    // Keeper (KEEPER_ROLE first; permissionless later per the brief)
    // ════════════════════════════════════════════════════════════════════

    function closeByTrigger(uint256 id, SwapRoute calldata route, uint256 deadline)
        external
        nonReentrant
        onlyRole(KEEPER_ROLE)
    {
        Position storage p = positions[id];
        if (p.status != Status.Open) revert NotOpen();

        uint256 price = _checkedPrice(p.token);
        _poke(p, price);
        uint8 reason = _fires(p, price);
        if (reason == 0) revert TriggerNotMet();

        // Minimum USDT on a trigger close = quantity * price * (1 - maxSlippageBps),
        // per the brief, verbatim -- divided by THIS token's own decimals, same reasoning as
        // openPosition's slippage band (see that comment). Computed as ONE Math.mulDiv, not two
        // sequential `* / `s: the old form divided by 10**decimals FIRST, truncating, then
        // multiplied and divided by 10_000 again -- two separate roundings instead of one correctly-
        // rounded division at the end. Math.mulDiv also carries the full 512-bit intermediate
        // product, so quantity * price * (10_000 - bps) can never silently overflow before the
        // division happens, the way three chained uint256 operations could for large enough inputs.
        uint256 minUsdtOut = Math.mulDiv(
            uint256(p.quantity) * (10_000 - p.triggers.maxSlippageBps),
            price,
            (10 ** tokenDecimals[p.token]) * 10_000
        );

        _close(id, p, route, minUsdtOut, deadline, reason, price);
    }

    function pokePeak(uint256[] calldata ids) external onlyRole(KEEPER_ROLE) {
        for (uint256 i = 0; i < ids.length; i++) {
            Position storage p = positions[ids[i]];
            if (p.status != Status.Open) continue;
            uint256 price = _checkedPrice(p.token);
            bool changed = _poke(p, price);
            if (changed) {
                p.gasOwedUsdt += _gasCostUsdt(gasUnitsPokePeak);
                emit PeakUpdated(ids[i], p.peakPrice, p.profitPeak, p.profitArmed);
            }
        }
    }

    // ════════════════════════════════════════════════════════════════════
    // Views
    // ════════════════════════════════════════════════════════════════════

    /// @dev Reverts when the price itself is unreadable (stale / diverges),
    /// same as every other price-dependent call here -- there is no
    /// meaningful (fires, reason, price) to return in that case, and a
    /// silent default would misinform the keeper/frontend rather than
    /// surface the real state.
    function triggerStatus(uint256 id) external view returns (bool fires, uint8 reason, uint256 price) {
        Position storage p = positions[id];
        if (p.status != Status.Open) revert NotOpen();
        price = _checkedPrice(p.token);
        // _fires alone, without _poke: a view can't write state. The keeper
        // calls pokePeak first in its own step, per the brief's keeper
        // ordering (poke, then close) -- this view reports against the
        // CURRENTLY STORED peak, not a hypothetical post-poke one.
        reason = _fires(p, price);
        fires = reason != 0;
    }

    function positionsOf(address owner) external view returns (uint256[] memory) {
        return _positionsOf[owner];
    }

    function quoteFee(uint256 usdtAmount) external view returns (uint256 fee) {
        return _fee(usdtAmount, tradeFeeBps);
    }

    // ════════════════════════════════════════════════════════════════════
    // Admin (DEFAULT_ADMIN_ROLE -- via TimelockAdmin once one exists, see
    // the PR report's "contradictions" section: none is deployed yet)
    // ════════════════════════════════════════════════════════════════════

    function setTokenAllowed(address token, bool allowed) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (token == address(0)) revert ZeroAddress();
        if (allowed) {
            uint8 dec = IERC20DecimalsMinimal(token).decimals();
            if (dec > 18) revert DecimalsTooHigh();
            tokenDecimals[token] = dec;
        }
        tokenAllowed[token] = allowed;
        emit TokenAllowedSet(token, allowed);
    }

    function setRouterAllowed(address router, bool allowed) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (router == address(0)) revert ZeroAddress();
        routerAllowed[router] = allowed;
        emit RouterAllowedSet(router, allowed);
    }

    function setOracle(address oracle_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (oracle_ == address(0)) revert ZeroAddress();
        oracle = IPositionOracle(oracle_);
        emit OracleSet(oracle_);
    }

    function scheduleFeeRaise(uint16 bps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (bps > MAX_FEE_BPS) revert FeeTooHigh();
        pendingFeeBps = bps;
        pendingFeeEta = uint64(block.timestamp) + FEE_RAISE_DELAY;
        emit FeeRaiseScheduled(bps, pendingFeeEta);
    }

    function setFeeRecipient(address to) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (to == address(0)) revert ZeroAddress();
        feeRecipient = to;
        emit FeeRecipientSet(to);
    }

    function setKeeperGasRecipient(address to) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (to == address(0)) revert ZeroAddress();
        keeperGasRecipient = to;
        emit KeeperGasRecipientSet(to);
    }

    function setLimits(uint256 minUsdt, uint256 maxUsdt, uint256 totalCapUsdt) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (!(minUsdt <= maxUsdt)) revert SizeOutOfRange();
        minPositionUsdt = minUsdt;
        maxPositionUsdt = maxUsdt;
        totalOpenCapUsdt = totalCapUsdt;
        emit LimitsSet(minUsdt, maxUsdt, totalCapUsdt);
    }

    function setGasRepay(uint256 unitsClose, uint256 unitsPoke, uint256 maxGasPrice, uint256 maxPerPosition)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        gasUnitsTriggerClose = unitsClose;
        gasUnitsPokePeak = unitsPoke;
        maxGasPriceWei = maxGasPrice;
        maxGasRepayPerPositionUsdt = maxPerPosition;
        emit GasRepaySet(unitsClose, unitsPoke, maxGasPrice, maxPerPosition);
    }

    function setUserAllowlist(bool enabled) external onlyRole(DEFAULT_ADMIN_ROLE) {
        userAllowlistEnabled = enabled;
        emit UserAllowlistSet(enabled);
    }

    function setUserAllowed(address user, bool allowed) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (user == address(0)) revert ZeroAddress();
        userAllowed[user] = allowed;
        emit UserAllowedSet(user, allowed);
    }

    /// @dev Not named in the brief's admin-function list, but `maxPriceAge`
    /// is read by `_checkedPrice` (given verbatim) with no setter proposed
    /// anywhere -- added here rather than hardcoding it as a constant.
    function setMaxPriceAge(uint256 seconds_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (seconds_ == 0) revert ZeroAddress(); // reusing ZeroAddress for "zero not allowed" rather than adding a 5th generic error
        maxPriceAge = seconds_;
        emit MaxPriceAgeSet(seconds_);
    }

    /// @dev seconds_ == 0 is allowed here (unlike setMaxPriceAge above) -- it means "clear the
    /// override, fall back to the global maxPriceAge", a legitimate and expected admin action,
    /// not a mistaken zero.
    function setMaxPriceAgeForToken(address token, uint32 seconds_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (token == address(0)) revert ZeroAddress();
        maxPriceAgeByToken[token] = seconds_;
        emit MaxPriceAgeForTokenSet(token, seconds_);
    }

    /// @dev Bound 0 < bps <= 5000 (50%), same convention PriceOracle's own setDeviationBps uses --
    /// 0 is disallowed here (unlike the per-token override below) because this is the fallback
    /// every token relies on until given its own value; it must always be a real tolerance.
    function setTwapToleranceBps(uint16 bps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (bps == 0 || bps > 5000) revert BadTriggers(); // reusing BadTriggers for "out of range bps", not a new generic error
        twapToleranceBps = bps;
        emit TwapToleranceBpsSet(bps);
    }

    /// @dev seconds_ == 0 is allowed (same reasoning as setMaxPriceAgeForToken) -- it clears the
    /// override back to the global twapToleranceBps, a legitimate admin action.
    function setTwapToleranceBpsForToken(address token, uint16 bps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (token == address(0)) revert ZeroAddress();
        if (bps > 5000) revert BadTriggers();
        twapToleranceBpsByToken[token] = bps;
        emit TwapToleranceBpsForTokenSet(token, bps);
    }

    // ── Fee manager / guardian ───────────────────────────────────────────

    function lowerFee(uint16 bps) external onlyRole(FEE_MANAGER_ROLE) {
        if (bps >= tradeFeeBps) revert FeeTooHigh();
        uint16 old = tradeFeeBps;
        tradeFeeBps = bps;
        emit FeeChanged(old, bps);
    }

    function applyFeeRaise() external {
        if (pendingFeeEta == 0 || block.timestamp < pendingFeeEta) revert FeeRaiseNotReady();
        uint16 old = tradeFeeBps;
        tradeFeeBps = pendingFeeBps;
        pendingFeeEta = 0;
        emit FeeChanged(old, pendingFeeBps);
    }

    function setOpeningPaused(bool paused) external onlyRole(GUARDIAN_ROLE) {
        openingPaused = paused;
        emit OpeningPausedSet(paused);
    }

    // ════════════════════════════════════════════════════════════════════
    // Internal: trigger pricing and logic (per the brief, verbatim where given)
    // ════════════════════════════════════════════════════════════════════

    /// @dev See the contract header's "known build-brief gap" note: this
    /// reverts for any token without BOTH an active Chainlink feed AND an
    /// active TWAP source on the oracle. The brief's own sample code
    /// discarded `checkTwapDivergence`'s return value, which would make
    /// the stated "reverts if the DEX TWAP disagrees too much" never
    /// actually happen -- fixed here to check `withinTolerance` for real.
    /// @dev Divergence check is now computed LOCALLY against this contract's own
    /// twapToleranceBps(ByToken), not oracle.checkTwapDivergence/deviationBpsByToken (Richard, 16
    /// Oct -- see the storage section's own comment on twapToleranceBps for why). Same
    /// percentage-of-trusted-price formula PriceOracle's own _withinTolerance uses internally
    /// (diff * 10_000 <= trusted * toleranceBps), just against this contract's setting instead of
    /// the oracle's shared one. minUsdtOut on a trigger close still prices off the Chainlink
    /// figure this function returns, unaffected by the TWAP side of this check.
    function _checkedPrice(address token) internal view returns (uint256 p) {
        (uint256 cl, uint256 updatedAt) = oracle.getChainlinkPriceWad(token);
        uint256 maxAge = maxPriceAgeByToken[token] != 0 ? maxPriceAgeByToken[token] : maxPriceAge;
        if (cl == 0 || block.timestamp - updatedAt > maxAge) revert PriceStale(token);

        uint256 twap = oracle.getTwapPriceWad(token);
        uint16 toleranceBps = twapToleranceBpsByToken[token] != 0 ? twapToleranceBpsByToken[token] : twapToleranceBps;
        uint256 diff = twap > cl ? twap - cl : cl - twap;
        if (diff * 10_000 > twap * toleranceBps) revert PriceStale(token);

        return cl;
    }

    // reason: 0 none, 1 stop-loss, 2 take-profit, 3 trailing stop, 4 trailing profit
    function _fires(Position storage p, uint256 price) internal view returns (uint8) {
        Triggers storage t = p.triggers;
        if (t.stopLossPrice != 0 && price <= t.stopLossPrice) return 1;
        if (t.takeProfitPrice != 0 && price >= t.takeProfitPrice) return 2;
        if (t.trailingBps != 0 && price <= p.peakPrice * (10_000 - t.trailingBps) / 10_000) return 3;
        if (t.activationBps != 0 && p.profitArmed) {
            uint256 trail = p.profitPeak * (10_000 - t.trailProfitBps) / 10_000;
            uint256 floor = p.entryPrice * (10_000 + t.lockBps) / 10_000;
            if (price <= (trail > floor ? trail : floor)) return 4;
        }
        return 0;
    }

    function _poke(Position storage p, uint256 price) internal returns (bool changed) {
        if (price > p.peakPrice) { p.peakPrice = price; changed = true; }
        Triggers storage t = p.triggers;
        if (t.activationBps != 0) {
            if (!p.profitArmed && price >= p.entryPrice * (10_000 + t.activationBps) / 10_000) {
                p.profitArmed = true; p.profitPeak = price; changed = true;
            } else if (p.profitArmed && price > p.profitPeak) {
                p.profitPeak = price; changed = true;
            }
        }
    }

    function _validateTriggers(Triggers calldata t, uint256 entryPrice) internal pure {
        if (t.stopLossPrice != 0 && t.stopLossPrice >= entryPrice) revert BadTriggers();
        if (t.takeProfitPrice != 0 && t.takeProfitPrice <= entryPrice) revert BadTriggers();
        if (
            t.trailingBps > MAX_TRIGGER_BPS || t.activationBps > MAX_TRIGGER_BPS
                || t.trailProfitBps > MAX_TRIGGER_BPS || t.lockBps > MAX_TRIGGER_BPS
        ) revert BadTriggers();
        if (t.lockBps >= t.activationBps && t.activationBps != 0) revert BadTriggers(); // lockBps < activationBps
        if (t.activationBps != 0 && t.trailProfitBps == 0) revert BadTriggers(); // trailProfitBps > 0 whenever activationBps > 0
        if (t.maxSlippageBps == 0 || t.maxSlippageBps > MAX_TRIGGER_SLIPPAGE_BPS) revert BadTriggers();
    }

    // ════════════════════════════════════════════════════════════════════
    // Internal: fee, gas, swap, close
    // ════════════════════════════════════════════════════════════════════

    function _fee(uint256 usdt, uint16 bps) internal pure returns (uint256) {
        return usdt * bps / 10_000;
    }

    function _gasCostUsdt(uint256 units) internal view returns (uint256) {
        uint256 gp = tx.gasprice < maxGasPriceWei ? tx.gasprice : maxGasPriceWei;
        uint256 bnbUsd = _checkedPrice(WBNB);
        return units * gp * bnbUsd / 1e18; // USDT has 18 decimals on BSC
    }

    /// @dev Mirrors the vault's own swap shape: exact-amount approve, call,
    /// balance-delta accounting (never trusts a router's own return value
    /// for how much actually landed). V3Path.tokens() allowlist-checks
    /// every hop, same as AlphaSelectVault.executeSwapV3.
    function _swap(
        SwapRoute calldata route,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minOut,
        uint256 deadline
    ) internal returns (uint256 amountOut) {
        if (!routerAllowed[route.router]) revert RouterNotAllowed(route.router);
        uint256 balBefore = IERC20(tokenOut).balanceOf(address(this));

        if (route.isV3) {
            address[] memory hops = V3Path.tokens(route.v3Path);
            if (hops[0] != tokenIn || hops[hops.length - 1] != tokenOut) revert BadRoute();
            for (uint256 i = 0; i < hops.length; i++) {
                if (hops[i] != address(asset) && !tokenAllowed[hops[i]]) revert TokenNotAllowed(hops[i]);
            }
            IERC20(tokenIn).forceApprove(route.router, amountIn);
            IPancakeV3SwapRouter.ExactInputParams memory params = IPancakeV3SwapRouter.ExactInputParams({
                path: route.v3Path,
                recipient: address(this),
                deadline: deadline,
                amountIn: amountIn,
                amountOutMinimum: minOut
            });
            IPancakeV3SwapRouter(route.router).exactInput(params);
        } else {
            if (route.path.length < 2 || route.path[0] != tokenIn || route.path[route.path.length - 1] != tokenOut) {
                revert BadRoute();
            }
            for (uint256 i = 0; i < route.path.length; i++) {
                if (route.path[i] != address(asset) && !tokenAllowed[route.path[i]]) revert TokenNotAllowed(route.path[i]);
            }
            IERC20(tokenIn).forceApprove(route.router, amountIn);
            IPancakeRouter(route.router).swapExactTokensForTokens(amountIn, minOut, route.path, address(this), deadline);
        }

        uint256 balAfter = IERC20(tokenOut).balanceOf(address(this));
        amountOut = balAfter - balBefore;
        if (amountOut < minOut) revert SlippageExceeded();
    }

    function _close(
        uint256 id,
        Position storage p,
        SwapRoute calldata route,
        uint256 minUsdtOut,
        uint256 deadline,
        uint8 reason,
        uint256 priceAtClose
    ) internal {
        address token = p.token;
        uint256 qty = p.quantity;
        address owner = p.owner;

        // Mark Closed, and update totalOpenUsdt, BEFORE the swap below -- the brief's own
        // instruction, literally: Effects before the Interaction, not just before the LATER
        // interactions (fee/gas/proceeds transfers). Safe to reorder: the swap only ever needs
        // the cached locals above (token/qty), never reads p.status or p.quantity itself, so
        // nothing downstream depends on the write happening after the external call.
        p.status = Status.Closed;
        // Subtract the EXACT usdtIn this position added at open, not a value recomputed from
        // entryPrice/quantity -- a fill that lands even slightly off the oracle price (better OR
        // worse) would otherwise desync the running total from what was actually added, and on a
        // sufficiently good fill, underflow and revert every exit for the position (and potentially
        // every other open position sharing the same counter). Math.min is a defensive clamp, not
        // the real guarantee -- the invariant suite (invariant_TotalOpenUsdtEqualsSumOfOpenUsdtIn)
        // proves the clamp never actually engages, i.e. p.usdtIn <= totalOpenUsdt always holds.
        totalOpenUsdt -= Math.min(p.usdtIn, totalOpenUsdt);

        uint256 usdtOut = _swap(route, token, address(asset), qty, minUsdtOut, deadline);

        // Fee first, then gas repaid out of what's left, then the owner gets the remainder --
        // possibly 0 on a crashed position. Never reverts: fee is bps-bounded (<=MAX_FEE_BPS, well
        // under 100%) so fee < usdtOut whenever usdtOut > 0, and gasRepaid is explicitly clamped to
        // what's left after the fee, not to its own uncapped "owed" figure. A position that crashed
        // to near-zero value still closes cleanly; it just pays out ~nothing, it doesn't get stuck.
        // Fee never turns a win into a loss (Richard, 16 Oct, PENDING his final confirmation):
        // usdtOut <= p.usdtIn -> no fee at all (closed flat or at a loss). Otherwise the fee is
        // capped at the position's actual profit (usdtOut - p.usdtIn), so a thin win can never be
        // charged more than it actually made -- the normal bps fee still applies whenever it's
        // smaller than the profit, same as before.
        uint16 feeBps = tradeFeeBps < p.feeBpsAtOpen ? tradeFeeBps : p.feeBpsAtOpen;
        uint256 fee;
        if (usdtOut > p.usdtIn) {
            uint256 bpsFee = _fee(usdtOut, feeBps);
            uint256 profit = usdtOut - p.usdtIn;
            fee = bpsFee < profit ? bpsFee : profit;
        }
        emit FeeCharged(id, 1, fee);
        uint256 afterFee = usdtOut - fee;

        uint256 gasRepaid = 0;
        if (reason != 0) {
            // trigger close only
            uint256 owed = p.gasOwedUsdt + _gasCostUsdt(gasUnitsTriggerClose);
            gasRepaid = owed > maxGasRepayPerPositionUsdt ? maxGasRepayPerPositionUsdt : owed;
        } else if (p.gasOwedUsdt > 0) {
            // manual close still repays any gas already owed from earlier pokes
            gasRepaid = p.gasOwedUsdt > maxGasRepayPerPositionUsdt ? maxGasRepayPerPositionUsdt : p.gasOwedUsdt;
        }
        if (gasRepaid > afterFee) gasRepaid = afterFee; // clamp to what's actually left, never revert

        uint256 remainder = afterFee - gasRepaid;

        if (fee > 0) asset.safeTransfer(feeRecipient, fee);
        if (gasRepaid > 0) asset.safeTransfer(reason != 0 ? msg.sender : keeperGasRecipient, gasRepaid);
        if (remainder > 0) asset.safeTransfer(owner, remainder);

        emit PositionClosed(id, owner, reason, usdtOut, fee, gasRepaid, priceAtClose);
    }
}
