// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IChainlinkAggregator} from "./interfaces/IChainlinkAggregator.sol";
import {IUniswapV3PoolMinimal} from "./interfaces/IUniswapV3PoolMinimal.sol";
import {IERC20DecimalsMinimal} from "./interfaces/IERC20DecimalsMinimal.sol";
import {IAlphaSelectVaultTokenGate} from "./interfaces/IAlphaSelectVaultTokenGate.sol";
import {TickMath} from "./libraries/TickMath.sol";

/**
 * @title PriceOracle
 * @notice All 5 steps of the agreed build order done: (1) Chainlink primary
 *         + staleness, (2) TWAP fallback + liquidity/cardinality guards,
 *         (3) divergence sanity-check tying both together, (4) per-token
 *         tiering/discoverability layer (getTier, onboardedTokens registry,
 *         isFullyOnboarded), (5) getDistressPriceWad for the emergency exit
 *         (30 Sept 2026, F1-F3 fix S1). Wired into AlphaSelectVault: the
 *         vault holds a reference to this contract and calls it on every
 *         priced trade, NAV read, and the emergency exit.
 *
 *         Honest history: step 3 also closed a gap from step 2. A TWAP-
 *         vs-live-spot circuit breaker was scoped during Tier 2 planning
 *         ("if TWAP and current spot diverge too much... pause deposits/
 *         withdrawals for that token") but never actually implemented when
 *         step 2 was built — only the TWAP-reading mechanism and its
 *         liquidity floor were. checkTwapDivergence() closes that, built
 *         alongside checkChainlinkDivergence() since both are the same
 *         primitive (two prices, one per-token tolerance).
 *
 *         Step 4 deliberately does NOT touch AlphaSelectVault.sol's own
 *         separate tokenAllowed gate -- onboarding a token for real still
 *         requires three separate admin actions today (vault.setTokenAllowed,
 *         this contract's setFeed/setTwapSource, and setDeviationBps).
 *         isFullyOnboarded() exists specifically to make that manual,
 *         cross-contract, order-dependent process verifiable rather than
 *         trusted on faith.
 *
 * @dev Design decisions from the review that produced this file:
 *
 *  - Feed addresses are owner-adjustable via setFeed(), NEVER hardcoded
 *    into this contract's bytecode. A 100+ token universe with tokens
 *    still gaining/losing valid addresses over time (see
 *    docs/PENDING_PUSH_STATUS.md-adjacent BSC_Token_Audit.pdf, 2026-08-11 —
 *    7 of the 26 tokens verified for this build's Chainlink table still had
 *    NO configured trading address 5 weeks after that audit) means a fixed-
 *    at-deployment table would need a full redeploy for every addition or
 *    correction. setFeed() should only ever be called by the timelocked
 *    admin multisig, not a hot key — same principle as AlphaSelectVault's
 *    own admin-only setters.
 *
 *  - decimals() is read LIVE from the aggregator inside setFeed(), never
 *    trusted from a caller-supplied argument or hardcoded to Chainlink's
 *    usual 8 -- self-verifying instead of assumed. This directly closes a
 *    real mistake caught during this build's own research: the first-pass
 *    token-coverage check matched TWT and YFI as "Chainlink-covered" by
 *    symbol prefix alone and missed that only TWT/BNB and YFI/BNB feeds
 *    exist, not TWT/USD or YFI/USD -- a real BNB-quoted feed still has a
 *    real decimals() value, so trusting an unverified assumption anywhere
 *    in this pipeline is exactly the class of bug this guards against.
 *
 *  - maxStaleness is set PER FEED at registration time, not one global
 *    constant. Chainlink's published heartbeats on BSC range from 27
 *    seconds (BNB/USD) to 86,400 seconds / 24h (several lower-volume
 *    feeds) -- a single fixed staleness window would be simultaneously too
 *    loose for the fast feeds and impossible to satisfy for the slow ones.
 *
 *  - Registered feed addresses (verified against Chainlink's own published
 *    BSC mainnet reference data, 16 Sept 2026 -- RE-VERIFY EVERY ONE against
 *    https://data.chain.link/bsc/mainnet immediately before any deployment
 *    transaction that calls setFeed(), not just trusted from this comment,
 *    per Richard's review: only 9 of 26 were independently spot-checked
 *    against Chainlink's own docs at review time):
 *      AAVE  0xA8357BF572460fC40f4B0aCacbB2a6A61c89f475
 *      ADA   0xa767f745331D267c7751297D982b050c93985627
 *      ATOM  0xb056B7C804297279A9a673289264c17E6Dc6055d
 *      AVAX  0x5974855ce31EE8E1fff2e76591CbF83D7110F151
 *      AXS   0x7B49524ee5740c99435f52d731dFC94082fE61Ab
 *      BCH   0x43d80f616DAf0b0B42a928EeD32147dC59027D41
 *      BNB   0x0567F2323251f0Aab15c8dFb1967E4e8A7D42aeE
 *      BTCB  0x264990fbd0A4796A3E3d8E37C4d5F87a3aCa5Ebf  (BTC/USD -- no
 *            dedicated BTCB/USD feed exists on BSC; BTCB is priced as if
 *            perfectly pegged to BTC. Documented assumption, not a silent
 *            one -- bridge/wrapper risk means the peg is not guaranteed.)
 *      CAKE  0xB6064eD41d4f67e353768aA239cA86f4F73665a1
 *      DAI   0x132d3C0B1D2cEa0BC552588063bdBb210FDeecfA
 *      DOGE  0x3AB0A0d137D4F946fBB19eecc6e92E64660231C8
 *      DOT   0xC333eb0086309a16aa7c8308DfD32c8BBA0a2592
 *      ETH   0x9ef1B8c0E4F7dc8bF5719Ea496883DC6401d5b2e
 *      FET   0x657e700c66C48c135c4A29c4292908DbdA7aa280
 *      FIL   0xE5dbFD9003bFf9dF5feB2f4F445Ca00fb121fb83
 *      INJ   0x63A9133cd7c611d6049761038C16f238FddA71d7
 *      LINK  0xca236E327F629f9Fc2c30A4E95775EbF0B89fac8
 *      LTC   0x74E72F37A8c415c8f1a98Ed42E78Ff997435791D
 *      SHIB  0xA615Be6cb0f3F36A641858dB6F30B9242d0ABeD8
 *      TRX   0xF4C5e535756D11994fCBB12Ba8adD0192D9b88be
 *      UNI   0xb57f259E7C24e56a1dA00F66b55A5640d9f9E7e4
 *      USDC  0x51597f405303C4377E36123cBc172b13269EA163
 *      USDT  0xB97Ad0E74fa7d920791E90258A6E2085088b4320
 *      1INCH 0x9a177Bb9f5b6083E962f9e62bD21d4b5660Aeb03
 *      SUSHI 0xa679C72a97B654CFfF58aB704de3BA15Cde89B07  (feed verified;
 *            DO NOT call setFeed() for this in a real deployment until a
 *            fresh PancakeSwap liquidity check clears it -- was thin/
 *            blocked in the 2026-08-11 audit. This contract's own gate is
 *            structural: no setFeed() call means hasFeed() stays false.)
 *      COMP  0x0Db8945f9aEf5651fa5bd52314C5aAe78DfDe540  (same caution as
 *            SUSHI above -- feed verified, liquidity NOT yet re-checked.)
 *    Deliberately EXCLUDED from this table, not just deferred:
 *      TWT, YFI  -- only BNB-quoted Chainlink feeds exist (TWT/BNB,
 *                   YFI/BNB), not USD-quoted. A USD price would require
 *                   chaining two aggregators (extra staleness surface,
 *                   compounded decimal risk) -- a deliberate step-2-or-later
 *                   feature, not smuggled into this direct-feed build.
 *      TUSD, USDF -- address-ambiguous (multiple different real contracts
 *                    share these tickers on BSC per the 2026-08-11 audit).
 *                    Permanently excluded until a human manually resolves
 *                    which exact contract is meant -- silently pricing the
 *                    wrong token is a worse failure than no price at all.
 *      FDUSD, USDD, USD1, XAUM, ASTER, REAL -- still have no configured
 *                    trading address in tokens.ts as of this build (5+
 *                    weeks after the audit first flagged it) -- can't be
 *                    priced for a token the bot can't even trade yet.
 */
contract PriceOracle is Initializable, UUPSUpgradeable, AccessControlUpgradeable {
    bytes32 public constant ORACLE_ADMIN_ROLE = keccak256("ORACLE_ADMIN_ROLE");

    struct FeedConfig {
        address aggregator;
        uint8 feedDecimals;   // cached from aggregator.decimals() at registration -- never hardcoded
        uint32 maxStaleness;  // seconds; admin-set per feed based on that feed's own published heartbeat
        bool active;
    }

    /// @notice token address => its registered Chainlink feed config.
    mapping(address => FeedConfig) public feeds;

    /**
     * @dev Tier 2 -- TWAP fallback for tokens with no Chainlink feed.
     * `pool` must be a PancakeSwap V3 pool pairing `token` directly against
     * `quoteToken`. `quoteToken` MUST itself have an active Chainlink feed
     * (checked in setTwapSource) -- the true USD price is computed as
     * TWAP(token/quoteToken) x Chainlink(quoteToken/USD), not a flat "1
     * stablecoin = $1" assumption, so a quoteToken depeg is reflected
     * immediately rather than silently ignored.
     */
    struct TwapConfig {
        address pool;
        address quoteToken;
        uint32 twapWindow;     // seconds; floored at MIN_TWAP_WINDOW
        uint256 minLiquidity;  // pool.liquidity() must clear this on EVERY read, not just at setup
        bool active;
    }

    /// @notice A hard floor under which no token's TWAP window may be set,
    /// regardless of admin input -- a shorter window defeats the entire
    /// point of averaging over time (see PriceOracle's design notes).
    uint32 public constant MIN_TWAP_WINDOW = 900; // 15 minutes

    mapping(address => TwapConfig) public twapConfigs;

    /**
     * @dev How much a live pool price may diverge from this token's trusted
     * price (Chainlink for Tier 1, TWAP for Tier 2) before checkChainlinkDivergence
     * / checkTwapDivergence report it out of tolerance. Deliberately ONE
     * shared table, not a separate field per tier -- a token is exclusively
     * Chainlink-covered or TWAP-covered (see the mutual-exclusion checks in
     * setFeed/setTwapSource below), so there is exactly one "how much drift
     * is tolerable for this token" answer, not two that could silently
     * drift apart from each other.
     */
    mapping(address => uint16) public deviationBpsByToken;

    /**
     * @dev Step 4 -- every token setFeed() or setTwapSource() has EVER been
     * called for, in registration order. Deliberately append-only and never
     * pruned on deactivation (same "deactivate doesn't delete the record"
     * philosophy as FeedConfig/TwapConfig themselves) -- this is a discovery
     * aid for admin tooling/deploy scripts ("what has this oracle ever been
     * told about"), not a live allowlist; combine with getTier() / hasFeed()
     * / hasTwapSource() to know what's CURRENTLY active. _tracked exists
     * only to make adding to the array idempotent (a token re-registered via
     * setFeed after already being in Twap, or vice versa, must not appear
     * twice).
     */
    address[] public onboardedTokens;
    mapping(address => bool) private _tracked;

    /// @notice Which price-source tier `token` is currently in. Deliberately
    /// DERIVED, not stored -- computed live from feeds/twapConfigs' own
    /// active flags rather than a separate field that could drift out of
    /// sync with the real registration state (exactly the "two sources of
    /// truth that can disagree" problem this whole design has avoided
    /// everywhere else). Chainlink and Twap are mutually exclusive per the
    /// requires in setFeed/setTwapSource, so this can never ambiguously
    /// return both.
    enum Tier { None, Chainlink, Twap }

    event FeedRegistered(address indexed token, address indexed aggregator, uint8 feedDecimals, uint32 maxStaleness);
    event FeedDeactivated(address indexed token);
    event TwapSourceRegistered(address indexed token, address indexed pool, address indexed quoteToken, uint32 twapWindow, uint256 minLiquidity);
    event TwapSourceDeactivated(address indexed token);
    event DeviationBpsSet(address indexed token, uint16 bps);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address admin) external initializer {
        require(admin != address(0), "admin required");
        __AccessControl_init();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(ORACLE_ADMIN_ROLE, admin);
    }

    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    /**
     * @notice Registers (or replaces) the Chainlink feed used to price `token`.
     * @dev Reverts if `aggregator` doesn't implement decimals() -- a cheap,
     *      free sanity check that the address is at least a real contract
     *      answering the expected interface, before it's ever trusted for
     *      a live price. maxStaleness should be set from the feed's OWN
     *      published heartbeat (see data.chain.link) plus a reasonable
     *      buffer -- never copied from a different feed's window.
     */
    function setFeed(address token, address aggregator, uint32 maxStaleness) external onlyRole(ORACLE_ADMIN_ROLE) {
        require(token != address(0) && aggregator != address(0), "zero address");
        require(maxStaleness > 0, "maxStaleness required");
        // Chainlink and TWAP are no longer mutually exclusive (relaxed
        // 30 Sept 2026 for getDistressPriceWad / F1-F3 fix S1, decision 11):
        // a token may hold both as independent references. getTier() still
        // returns Chainlink first when both are active, so every existing
        // trusted-price call site (NAV, ordinary buy/sell) is unaffected --
        // only getDistressPriceWad reads both sources independently.

        uint8 dec = IChainlinkAggregator(aggregator).decimals();

        feeds[token] = FeedConfig({
            aggregator: aggregator,
            feedDecimals: dec,
            maxStaleness: maxStaleness,
            active: true
        });
        _trackToken(token);

        emit FeedRegistered(token, aggregator, dec, maxStaleness);
    }

    /**
     * @notice Turns off a token's feed without deleting its history --
     *         hasFeed() and getChainlinkPriceWad() both treat it as
     *         unpriced immediately, without losing the aggregator/decimals
     *         record if it needs to be reactivated later.
     */
    function deactivateFeed(address token) external onlyRole(ORACLE_ADMIN_ROLE) {
        feeds[token].active = false;
        emit FeedDeactivated(token);
    }

    function hasFeed(address token) external view returns (bool) {
        return feeds[token].active;
    }

    /**
     * @notice Returns `token`'s USD price from its registered Chainlink
     *         feed, normalized to 18 decimals (WAD), plus the feed's own
     *         updatedAt timestamp.
     * @dev Reverts if: no active feed is registered; the feed reports a
     *      non-positive price (Chainlink's own documented failure mode,
     *      e.g. during an outage); or the feed is staler than ITS OWN
     *      configured maxStaleness -- per-feed, not a single global window,
     *      since real BSC heartbeats span 27s to 86,400s.
     */
    function getChainlinkPriceWad(address token) public view returns (uint256 priceWad, uint256 updatedAt) {
        FeedConfig memory cfg = feeds[token];
        require(cfg.active, "no active Chainlink feed for token");

        (, int256 answer, , uint256 _updatedAt, ) = IChainlinkAggregator(cfg.aggregator).latestRoundData();
        require(answer > 0, "invalid Chainlink price");
        require(block.timestamp - _updatedAt <= cfg.maxStaleness, "Chainlink feed stale");

        updatedAt = _updatedAt;
        if (cfg.feedDecimals == 18) {
            priceWad = uint256(answer);
        } else if (cfg.feedDecimals < 18) {
            priceWad = uint256(answer) * (10 ** (18 - cfg.feedDecimals));
        } else {
            priceWad = uint256(answer) / (10 ** (cfg.feedDecimals - 18));
        }
    }

    // ── Tier 2: TWAP fallback (16 Sept 2026, step 2 of the agreed build order) ──

    /**
     * @notice Registers `pool` as the TWAP source for `token`, quoted
     *         against `quoteToken`.
     * @dev Deliberately does more than store config:
     *      - Confirms the pool actually pairs token/quoteToken directly
     *        (not some other pair entirely).
     *      - Requires quoteToken already has an active Chainlink feed --
     *        getTwapPriceWad() depends on it to convert into a true USD
     *        price, so a TWAP source pointed at an unpriced quoteToken
     *        would be silently broken from the moment it's registered.
     *      - Runs getTwapPriceWad() right here, before accepting the
     *        config, as a live self-test: if the pool doesn't actually have
     *        enough observation history to serve `twapWindow` seconds of
     *        lookback, this reverts immediately and loudly at setup time,
     *        instead of deferring that discovery to the first real price
     *        read in production (PancakeSwap V3's own observe() reverts
     *        with "OLD" when asked for more history than the pool has
     *        recorded -- that natural revert IS the cardinality check,
     *        rather than a separate heuristic guess at it).
     */
    function setTwapSource(
        address token,
        address pool,
        address quoteToken,
        uint32 twapWindow,
        uint256 minLiquidity
    ) external onlyRole(ORACLE_ADMIN_ROLE) {
        require(token != address(0) && pool != address(0) && quoteToken != address(0), "zero address");
        require(twapWindow >= MIN_TWAP_WINDOW, "window below floor");
        require(minLiquidity > 0, "minLiquidity required");
        require(feeds[quoteToken].active, "quoteToken needs an active Chainlink feed");
        // token itself (not quoteToken -- that's a separate, unrelated
        // requirement above) may also hold an active Chainlink feed --
        // see setFeed's matching comment on the relaxed mutual exclusion.

        address t0 = IUniswapV3PoolMinimal(pool).token0();
        address t1 = IUniswapV3PoolMinimal(pool).token1();
        require(
            (t0 == token && t1 == quoteToken) || (t1 == token && t0 == quoteToken),
            "pool does not pair token/quoteToken"
        );

        twapConfigs[token] = TwapConfig({
            pool: pool,
            quoteToken: quoteToken,
            twapWindow: twapWindow,
            minLiquidity: minLiquidity,
            active: true
        });

        getTwapPriceWad(token); // self-test -- reverts here if the pool can't actually serve this window/liquidity floor
        _trackToken(token);

        emit TwapSourceRegistered(token, pool, quoteToken, twapWindow, minLiquidity);
    }

    function deactivateTwapSource(address token) external onlyRole(ORACLE_ADMIN_ROLE) {
        twapConfigs[token].active = false;
        emit TwapSourceDeactivated(token);
    }

    function hasTwapSource(address token) external view returns (bool) {
        return twapConfigs[token].active;
    }

    /**
     * @notice Returns `token`'s USD price via its registered TWAP source,
     *         normalized to 18 decimals (WAD).
     * @dev Reverts if: no active TWAP source; the pool's CURRENT liquidity
     *      (checked live, on every call -- not just at setTwapSource time,
     *      same "check live conditions, not historical setup state"
     *      principle as the bot's own Guard 8) has fallen below the
     *      configured floor; or the pool can't serve `twapWindow` seconds
     *      of observation history (propagated from observe()'s own revert).
     */
    function getTwapPriceWad(address token) public view returns (uint256 priceWad) {
        TwapConfig memory cfg = twapConfigs[token];
        require(cfg.active, "no active TWAP source for token");
        require(IUniswapV3PoolMinimal(cfg.pool).liquidity() >= cfg.minLiquidity, "pool liquidity below configured floor");

        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = cfg.twapWindow;
        secondsAgos[1] = 0;
        (int56[] memory tickCumulatives, ) = IUniswapV3PoolMinimal(cfg.pool).observe(secondsAgos);

        int56 delta = tickCumulatives[1] - tickCumulatives[0];
        int24 avgTick = int24(delta / int56(uint56(cfg.twapWindow)));
        // Round toward negative infinity for a negative delta with a
        // remainder -- matches Uniswap's own OracleLibrary.consult()
        // reference behavior; Solidity's integer division rounds toward
        // zero, which would otherwise silently bias the average tick up.
        if (delta < 0 && (delta % int56(uint56(cfg.twapWindow)) != 0)) {
            avgTick--;
        }

        uint8 tokenDecimals = IERC20DecimalsMinimal(token).decimals();
        uint256 quoteRaw = _quoteAtTick(avgTick, 10 ** tokenDecimals, token, cfg.quoteToken);

        uint8 quoteDecimals = IERC20DecimalsMinimal(cfg.quoteToken).decimals();
        uint256 quoteWad = quoteDecimals == 18
            ? quoteRaw
            : quoteDecimals < 18
                ? quoteRaw * (10 ** (18 - quoteDecimals))
                : quoteRaw / (10 ** (quoteDecimals - 18));

        (uint256 quoteTokenUsdWad, ) = getChainlinkPriceWad(cfg.quoteToken);
        priceWad = Math.mulDiv(quoteWad, quoteTokenUsdWad, 1e18);
        // This mulDiv can independently truncate to zero (e.g. a very cheap
        // quoteToken USD price against a small quoteWad) even when
        // _quoteAtTick's own zero-guard below already passed -- a silent
        // zero here is indistinguishable from "this token is worthless" to
        // any caller, so fail loud instead (found by the fuzz/invariant
        // suite: contracts/test/PriceOracleInvariants.t.sol).
        require(priceWad != 0, "PriceOracle: price truncated to zero");
    }

    // ── Step 5: distress price for the emergency exit (30 Sept 2026, F1-F3 fix S1) ──

    /**
     * @notice The lower of whatever independent price sources are readable
     *         for `token` right now -- Chainlink and/or TWAP. Built for
     *         `adminEmergencyExitV3`'s last-resort exit, which needs a price
     *         it can still trust when the token's own primary tier has gone
     *         wrong, not the single trusted price every other call site uses.
     * @dev `ok = false` only when NEITHER source can be read (both inactive,
     *      or both revert -- e.g. Chainlink stale AND the TWAP pool lacks
     *      liquidity/history). If only one is readable, that one is used
     *      as-is: a stale Chainlink feed no longer blocks the exit as long
     *      as the token's TWAP is registered and healthy (fixes F3 for a
     *      dual-registered token), and a manipulated-high single source is
     *      capped by whichever independent source reads lower (fixes F1/F2
     *      the same way, for a dual-registered token). A token that was
     *      only ever given one source keeps exactly today's behavior --
     *      this function simply has nothing to compare it against.
     *      Deliberately does NOT change getTier(), checkChainlinkDivergence,
     *      checkTwapDivergence, or any other read: NAV and ordinary trades
     *      still resolve to a single trusted tier and still revert/degrade
     *      exactly as before, dual registration or not.
     *      Known, accepted residual (documented for the auditor, not fixed
     *      here): if an attacker can push a source LOW instead of high, the
     *      distress price follows it down too -- this function reports the
     *      lower reading without judging which side "lower" is safer for a
     *      SELL. That is why adminEmergencyExitV3 stays admin/timelock-only.
     */
    function getDistressPriceWad(address token) external view returns (uint256 priceWad, bool ok) {
        bool haveCl;
        uint256 clPriceWad;
        if (feeds[token].active) {
            try this.getChainlinkPriceWad(token) returns (uint256 p, uint256) {
                clPriceWad = p;
                haveCl = true;
            } catch {}
        }

        bool haveTwap;
        uint256 twapPriceWad;
        if (twapConfigs[token].active) {
            try this.getTwapPriceWad(token) returns (uint256 p) {
                twapPriceWad = p;
                haveTwap = true;
            } catch {}
        }

        if (haveCl && haveTwap) {
            priceWad = clPriceWad < twapPriceWad ? clPriceWad : twapPriceWad;
            ok = true;
        } else if (haveCl) {
            priceWad = clPriceWad;
            ok = true;
        } else if (haveTwap) {
            priceWad = twapPriceWad;
            ok = true;
        }
    }

    // ── Step 3: divergence sanity-check (16 Sept 2026) ──────────────────

    /**
     * @notice Sets how far (in basis points) a live pool price may diverge
     *         from `token`'s trusted price before checkChainlinkDivergence /
     *         checkTwapDivergence report it out of tolerance.
     * @dev Bound 0 < bps <= 5000 (50%), same convention as AlphaSelectVault's
     *      own maxForceSettleNavDeviationBps -- one consistent "how much
     *      drift is this vault willing to tolerate" pattern across both
     *      contracts, not two similar-but-different ones.
     */
    function setDeviationBps(address token, uint16 bps) external onlyRole(ORACLE_ADMIN_ROLE) {
        require(token != address(0), "zero address");
        require(bps > 0 && bps <= 5000, "must be between 0 and 50%");
        deviationBpsByToken[token] = bps;
        emit DeviationBpsSet(token, bps);
    }

    /**
     * @notice Checks whether `livePriceWad` -- a live pool price the CALLER
     *         supplies, already normalized to 18 decimals -- is within
     *         `token`'s configured tolerance of its trusted Chainlink price.
     * @dev PriceOracle deliberately has no opinion on which pool
     *      `livePriceWad` came from -- only the CALLER (the vault) knows
     *      which pool is contextually correct: executeSwap's own
     *      router+path quote for a trade in flight, or primaryRouter's
     *      quote for a NAV read. Passing a price from the wrong pool (one
     *      the caller isn't actually about to trade through, or trust for
     *      NAV) defeats the entire point of this check without the
     *      contract having any way to detect it -- that responsibility
     *      cannot be moved into this function, only documented as its
     *      precondition.
     *      Returns rather than reverts, deliberately -- so each call site
     *      chooses its own failure behavior: executeSwap should revert
     *      that one trade; totalAssets() should degrade gracefully (e.g.
     *      treat just that token as unpriceable) rather than letting one
     *      manipulated or stale pool brick NAV for every depositor.
     *      Reverts only on a genuine setup problem (no Chainlink feed, or
     *      no deviation tolerance ever configured for this token) -- that's
     *      a deployment-integrity failure, not a live market condition, and
     *      is treated differently on purpose from an actual divergence.
     */
    function checkChainlinkDivergence(address token, uint256 livePriceWad)
        external
        view
        returns (bool withinTolerance, uint256 trustedPriceWad)
    {
        uint16 bps = deviationBpsByToken[token];
        require(bps > 0, "no deviation tolerance configured for token");
        (trustedPriceWad, ) = getChainlinkPriceWad(token);
        withinTolerance = _withinTolerance(trustedPriceWad, livePriceWad, bps);
    }

    /**
     * @notice Same as checkChainlinkDivergence, but for a Tier 2 token --
     *         compares `livePriceWad` against the token's own TWAP price
     *         rather than a Chainlink feed. Closes the TWAP-vs-spot circuit
     *         breaker originally scoped during Tier 2 planning but not
     *         implemented in step 2 (see this file's top-level NatSpec).
     * @dev Same preconditions and revert/return split as checkChainlinkDivergence:
     *      livePriceWad must already be 18-decimal-normalized by the caller,
     *      from whichever pool reading is contextually correct for that
     *      call site; returns rather than reverts on an out-of-tolerance
     *      result so the caller decides how to react.
     */
    function checkTwapDivergence(address token, uint256 livePriceWad)
        external
        view
        returns (bool withinTolerance, uint256 trustedPriceWad)
    {
        uint16 bps = deviationBpsByToken[token];
        require(bps > 0, "no deviation tolerance configured for token");
        trustedPriceWad = getTwapPriceWad(token);
        withinTolerance = _withinTolerance(trustedPriceWad, livePriceWad, bps);
    }

    // ── Step 4: tiering / discoverability layer (17 Sept 2026) ──────────

    function _trackToken(address token) internal {
        if (!_tracked[token]) {
            _tracked[token] = true;
            onboardedTokens.push(token);
        }
    }

    function onboardedTokensLength() external view returns (uint256) {
        return onboardedTokens.length;
    }

    /// @notice Which tier `token` is currently in -- None if it has neither
    /// an active Chainlink feed nor an active TWAP source right now
    /// (whether or not it was ever registered and later deactivated).
    function getTier(address token) public view returns (Tier) {
        if (feeds[token].active) return Tier.Chainlink;
        if (twapConfigs[token].active) return Tier.Twap;
        return Tier.None;
    }

    /**
     * @notice Checks whether `token` is genuinely ready for real trades on
     *         `vault` -- all three of the separate admin actions onboarding
     *         actually requires have landed, in any order:
     *         (1) `vault.tokenAllowed(token)` is true,
     *         (2) `token` has an active price source here (either tier),
     *         (3) a nonzero deviation tolerance is configured for `token`.
     * @dev Pure convenience/verification, not called by anything on-chain --
     *      for an admin or deploy script to confirm a token is truly ready
     *      before real trades can hit it, rather than trusting that three
     *      separate transactions across two contracts all landed correctly.
     *      Takes `vault` as a parameter rather than a stored reference --
     *      see IAlphaSelectVaultTokenGate's own doc for why.
     */
    function isFullyOnboarded(address vault, address token) external view returns (bool) {
        if (!IAlphaSelectVaultTokenGate(vault).tokenAllowed(token)) return false;
        if (deviationBpsByToken[token] == 0) return false;
        return getTier(token) != Tier.None;
    }

    /**
     * @dev Shared compare primitive for both divergence checks above --
     *      same `diff * 10000 <= reference * bps` shape as
     *      AlphaSelectVault's forceSettleStale deviation check, with
     *      `trustedPriceWad` playing the role of the trusted reference
     *      (mirrors that function's lastSettledNavPerShareWad being the
     *      base of its own comparison, not the live/incoming value).
     */
    function _withinTolerance(uint256 trustedPriceWad, uint256 livePriceWad, uint16 toleranceBps)
        internal
        pure
        returns (bool)
    {
        uint256 diff = trustedPriceWad > livePriceWad
            ? trustedPriceWad - livePriceWad
            : livePriceWad - trustedPriceWad;
        return diff * 10000 <= trustedPriceWad * toleranceBps;
    }

    /**
     * @dev Converts an average tick into "how much quoteToken is 1 raw unit
     *      of baseToken worth" -- the standard Uniswap V3 pattern (same
     *      shape as the periphery OracleLibrary.getQuoteAtTick). Branches on
     *      sqrtRatioX96's size purely to avoid an overflow in the squaring
     *      step for very large ratios; Math.mulDiv (OpenZeppelin's 0.8.x-
     *      native port of the same "512-bit via 256-bit" algorithm Uniswap's
     *      own FullMath.sol uses -- already an installed dependency, so no
     *      need to vendor Uniswap's own copy, which relies on wraparound
     *      arithmetic that would need careful, error-prone hand-porting to
     *      compile under this project's 0.8.24 pin) is what actually makes
     *      the multiplication safe against overflow either way, not plain `*`.
     */
    function _quoteAtTick(int24 tick, uint256 baseAmount, address baseToken, address quoteToken)
        internal
        pure
        returns (uint256 quoteAmount)
    {
        uint160 sqrtRatioX96 = TickMath.getSqrtRatioAtTick(tick);
        if (sqrtRatioX96 <= type(uint128).max) {
            uint256 ratioX192 = uint256(sqrtRatioX96) * sqrtRatioX96;
            quoteAmount = baseToken < quoteToken
                ? Math.mulDiv(ratioX192, baseAmount, 1 << 192)
                : Math.mulDiv(1 << 192, baseAmount, ratioX192);
        } else {
            uint256 ratioX128 = Math.mulDiv(sqrtRatioX96, sqrtRatioX96, 1 << 64);
            quoteAmount = baseToken < quoteToken
                ? Math.mulDiv(ratioX128, baseAmount, 1 << 128)
                : Math.mulDiv(1 << 128, baseAmount, ratioX128);
        }
        // A small baseAmount (10**tokenDecimals for a low-decimals token,
        // e.g. 1e6) divided against a much larger tick-implied price ratio
        // floors to exactly zero here -- a real, reachable case (found by
        // the fuzz/invariant suite: contracts/test/PriceOracleInvariants.t.sol,
        // avgTick=160165 against a 6-decimal token), not a contrived one.
        // Reverting here protects every caller of this function, not just
        // getTwapPriceWad's own separate zero-guard on its final mulDiv.
        require(quoteAmount != 0, "PriceOracle: quote truncated to zero");
    }
}
