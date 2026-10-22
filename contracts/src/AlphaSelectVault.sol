// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IPancakeRouter} from "./interfaces/IPancakeRouter.sol";
import {IPancakeV3SwapRouter} from "./interfaces/IPancakeV3SwapRouter.sol";
import {IPancakeV3PoolState} from "./interfaces/IPancakeV3PoolState.sol";
import {IPriceOracleView} from "./interfaces/IPriceOracleView.sol";
import {IERC20DecimalsMinimal} from "./interfaces/IERC20DecimalsMinimal.sol";
import {V3Path} from "./libraries/V3Path.sol";
import {ValuationLib} from "./libraries/ValuationLib.sol";

/**
 * @title AlphaSelectVault
 * @notice DRAFT — first-pass implementation, NOT audited, NOT deployed.
 *         Built against docs/VAULT_ARCHITECTURE_SPEC.md (this repo, Phase 3).
 *         Do not point real funds at this until an external audit has run.
 *
 * @dev Design summary (mirrors the spec doc section-for-section):
 *
 *  §1 Strategy vs risk profile — this contract is strategy-agnostic; it only
 *     knows "which address is my approved keeper." One deployment per
 *     (strategy × risk) combination the product actually offers, all sharing
 *     this same audited code — see initialize().
 *
 *  §2 totalAssets() valuation — values idle stablecoin at par plus every
 *     held token quoted live through the same PancakeSwap pools the bot
 *     already trades through (no separate oracle to trust). A quote that
 *     fails values that position at zero for that read — conservative
 *     under-statement, never an inflated NAV. See totalAssets()/_quoteTokenValueEx().
 *
 *  §2b Deposits — FIXED 11 Sept 2026, Richard's review of the 9 Sept status
 *     update (measured, not just argued): §2's live spot quote has no TWAP,
 *     no manipulation resistance at the price-read level itself.
 *     test_Fork_TotalAssetsCanBeDistortedByExternalPoolManipulation (fork
 *     test suite) proves the exposure against REAL BSC liquidity: a single
 *     outside actor with no relationship to the vault, needing no capital
 *     of their own in the real attack (a flash loan), pushed totalAssets()
 *     67.5% above its correct value with one large swap, reverting to
 *     normal once they restored the pool. Redemptions were already immune
 *     (§5's async queue means a manipulator would need to sustain the push
 *     across an entire settlement, not just one block) — deposits used to
 *     be the exposed side, minting shares SYNCHRONOUSLY against whatever
 *     totalAssets() said in that same transaction.
 *
 *     Deposits are now async, mirroring §5 exactly: requestDeposit()
 *     escrows the USDT and queues a request; settleDeposits() (keeper-
 *     callable, same FIFO/liquidity-style loop as settleRedemptions) mints
 *     shares only after MIN_DEPOSIT_SETTLE_DELAY has passed, at THAT
 *     moment's live NAV — never the request-time one. A same-transaction
 *     price push can no longer buy shares cheap, since minting happens in
 *     a later block the attacker doesn't control; sustaining a push across
 *     the whole delay window costs real capital and carries real
 *     arbitrage risk, a fundamentally different threat than a free flash
 *     loan. A pending request's escrowed cash is excluded from every NAV
 *     read via pendingDepositTotal (see _netAssetsWithHealth()) so it
 *     can't inflate its own — or anyone else's — share price before it's
 *     actually settled, and the keeper is physically blocked from trading
 *     it (see executeSwap()'s balance check). A depositor can cancel their
 *     own not-yet-settled request at any time for a full refund — unlike a
 *     redemption, nothing has been bought yet, so there's no reason to
 *     force anyone to wait out a keeper outage for their own money.
 *     test_Fork_DepositRequestedDuringManipulationSettlesAtFairPriceNotManipulatedOne
 *     proves the fix directly: totalAssets() swings to 2.4x its fair value
 *     during a real, live pool push, yet the pending deposit settles
 *     within 0.13% of the pre-attack fair estimate once the delay elapses
 *     and the pool is restored.
 *
 *  §3 Keeper permissions — "the bot key can suggest, the contract can
 *     refuse." KEEPER_ROLE's only capability is executeSwap(), bounded by
 *     the router allowlist, token allowlist, max position size, and a
 *     slippage floor checked against the router's own live quote. The
 *     keeper can never call anything that moves funds to an arbitrary
 *     address — swap output always lands back in this contract.
 *
 *  §4 Emergency pause — two independent switches. tradingPaused blocks new
 *     deposits and executeSwap(); it does NOT block redemption settlement —
 *     a paused vault must never read as "funds are trapped." Settlement
 *     ALWAYS recomputes NAV live via totalAssets() at the moment it runs;
 *     nothing is ever cached or reused from an earlier block (resolved 11
 *     Sept 2026 — see _totalAssetsWithHealth()'s doc for the full story:
 *     the spec doc's own §4b used to describe a "last confirmed-good NAV"
 *     that this contract has never actually implemented). Either
 *     KEEPER_ROLE or DEFAULT_ADMIN_ROLE can pause (fail-safe, fast); only
 *     DEFAULT_ADMIN_ROLE (the multisig) can unpause (deliberate, slow) —
 *     asymmetric on purpose.
 *
 *  §5 Redemption queue — withdrawals are NOT instant (funds are actively
 *     deployed). requestRedeem() locks shares and queues a request;
 *     settleRedemptions() (keeper-callable, matching the bot's own
 *     liquidity-aware pacing proposal) pays out FIFO up to whatever idle
 *     stablecoin is actually free, at SETTLEMENT-time NAV — never
 *     request-time, which would let a request snipe a stale price. A
 *     request waiting past MAX_REDEMPTION_WAIT can be force-settled by
 *     ANYONE, permissionless — the hard backstop that stops "the keeper is
 *     pacing withdrawals prudently" from ever silently becoming "funds are
 *     stuck." This is the liquidity-aware design proposed 8 Sept, formalized.
 *
 *  §6 Fee accounting — loyalty-tiered performance fee (12/10/7/5% by
 *     holding duration) on a PER-USER high-water mark, tracked in USD-value
 *     terms so users entering at different NAVs and users topping up an
 *     already-profitable position are both handled correctly (see
 *     userHighWaterValue's doc and _trySettleOne()). Fee is charged only on
 *     the profit above a user's own prior high point, atomically to the
 *     treasury multisig, at redemption settlement.
 *
 *  §7 Richard's full security review, 14 Sept 2026 (3 Critical / 2 High /
 *     3 Medium / 3 Low) — every Critical, High, and Low finding is fixed
 *     below, each with a dedicated regression test proving it:
 *   - Critical #1 (permissionless force-settle can be sandwiched): a manipulated
 *     price could be forced through forceSettleStale by anyone once
 *     MAX_REDEMPTION_WAIT elapses. Fixed with lastSettledNavPerShareWad — a
 *     trusted NAV/share reference updated only by real settlements — plus
 *     maxForceSettleNavDeviationBps (admin-tunable, default 10%): a
 *     force-settle whose live NAV strays further than that from the last
 *     trusted point reverts instead of settling at a manipulated price.
 *     See test_ForceSettleStaleRevertsWhenLiveNavDeviatesTooFarFromLastTrustedSettlement.
 *     FOLLOW-UP, security audit, 29 Sept 2026: that single-step bound didn't
 *     stop a CHAIN of forced settlements from compounding past it — each
 *     forced settlement was itself moving lastSettledNavPerShareWad, so a
 *     sequence of individually-legal ~9% pushes across several separately-
 *     stale requests compounded to +53.9% with no ceiling
 *     (test_POC_CompoundingForceSettleStaleDeviation proved it before this
 *     fix). forceSettleStale no longer updates the trusted reference itself
 *     — only a genuine keeper/admin settlement does — so a forced
 *     settlement's own live NAV is always checked against the last REAL
 *     settlement, not the last forced one. See forceSettleStale's own doc.
 *   - Critical #2 (settlement could spend escrowed pending-deposit cash):
 *     _trySettleOne's idle-liquidity calc now excludes pendingDepositTotal,
 *     the same fix §2b already applied to the size-check in executeSwap.
 *     See test_RedemptionCannotSettleUsingPendingDepositEscrow.
 *   - Critical #3 (executeSwap had three separate gaps): (a) only the FIRST
 *     and LAST hop of a swap path were ever allowlist-checked — a keeper
 *     could route through an attacker-created pool as a middle hop; every
 *     hop is checked now (test_SwapBlockedWhenMiddleHopTokenNotAllowlisted).
 *     (b) maxPositionUsd only ever capped BUYS — a sell or token-to-token
 *     swap of any size was uncapped; the same cap now applies to both
 *     directions via a live USD valuation of the input side
 *     (test_SellBlockedOverMaxPositionSize). (c) the slippage floor checks
 *     minOut against the SAME router's own quote, which is circular
 *     protection if that router's pool is thin or attacker-controlled (the
 *     real ZEC incident). A cross-check against primaryRouter's
 *     independent quote is added when router != primaryRouter — genuine
 *     protection only when they're actually different liquidity sources;
 *     when they're the same router (or only one is ever allowlisted) this
 *     remains the same "no oracle yet" limitation §2 already carries,
 *     flagged honestly rather than claimed solved.
 *   - High #4 (a paused vault could trap funds in a bad position): pausing
 *     used to block ALL trading, including selling out of a token that
 *     needs to be exited urgently. Now only new exposure is blocked while
 *     paused (test_SellStillWorksWhilePausedButBuyDoesNot). Paired with
 *     adminForceRemoveHeldToken(), so admin can also drop a token that has
 *     become entirely unpriceable (no live quote at all) without that one
 *     token freezing every future totalAssets() read
 *     (test_AdminCanForceRemoveUnpriceableTokenToUnfreezeTheVault).
 *   - High #5 (share-price manipulation via the deposit queue): (a) a
 *     zero-share deposit (rounds to 0 shares at an inflated NAV) used to
 *     revert and jam the FIFO queue behind it; it's now skipped and
 *     refunded instead (test_DustDepositIsSkippedAndRefundedNotBlockingTheQueueBehindIt).
 *     (b) the classic ERC-4626 first-depositor donation-inflation attack
 *     was still possible pre-launch; initialize() now takes a mandatory
 *     seed deposit, minted 1:1 to a permanently-locked dead address, same
 *     spirit as OpenZeppelin's own recommended mitigation
 *     (test_SeedDepositExistsAtDeadAddressAndIsPermanentlyLocked).
 *   - Low (executeSwap's deadline was a no-op): the router call used
 *     `block.timestamp + 300` computed INSIDE the transaction, which can
 *     never expire relative to itself. executeSwap now takes a real
 *     caller-supplied deadline parameter.
 *   - Medium findings (no timelock on admin functions, heldTokensList's
 *     unbounded gas growth, fee-vs-HWM naming precision, loyalty clock not
 *     resetting on full exit) are NOT yet implemented — deferred pending
 *     product/priority discussion, not silently dropped.
 *
 *  Known v1 simplifications, flagged for review before audit (not silently
 *  glossed over):
 *   - Loyalty-tier clock is anchored to a user's FIRST deposit only — a
 *     later top-up doesn't get its own separate clock. Simpler than true
 *     per-cohort tracking; matches the spec's fairness intent for the
 *     common case, worth dedicated test coverage for the "deposit again
 *     much later" edge before audit. (Flagged again as Medium in the 14
 *     Sept review — clock doesn't reset on a full exit either; still open.)
 *   - Multiple simultaneous pending redemption requests from the same user
 *     are handled (each against their balance at that request's own time)
 *     but not yet covered by dedicated tests — do that before audit.
 *   - Custom hand-rolled reentrancy guard (`_reentrancyLock`) — its
 *     upgrade-safe storage layout is an explicit audit item; see its own
 *     doc comment above the declaration.
 *   - MIN_DEPOSIT_SETTLE_DELAY (10 minutes) is a fixed constant, not an
 *     admin-tunable parameter — a deliberate v1 simplification matching
 *     MAX_REDEMPTION_WAIT's own pattern; revisit if a shorter/longer
 *     window turns out to matter in practice.
 *   - Admin-only setters (setRiskParams, pause/unpause, allowlist changes,
 *     etc.) go through a 48h TimelockController after handover — the
 *     29 Sept testnet rehearsal (throwaway keys) confirmed the old
 *     deployer key loses this power and the Safe can only act through the
 *     delay. Medium finding, 14 Sept review, closed by that handover.
 *   - heldTokensList only ever grows via push in v1 outside of
 *     adminForceRemoveHeldToken's explicit swap-and-pop — a keeper trading
 *     many distinct tokens over time raises totalAssets()'s gas cost
 *     unboundedly. Medium finding, 14 Sept review, deferred.
 */
contract AlphaSelectVault is Initializable, UUPSUpgradeable, AccessControlUpgradeable, ERC20Upgradeable {
    using SafeERC20 for IERC20;

    // Minimal, storage-based reentrancy guard, rolled by hand rather than
    // relying on the OZ upgradeable package's version (which has moved to
    // a transient-storage implementation in current releases — an EVM
    // feature worth confirming BSC mainnet support for separately before
    // this is ever deployed; a plain storage bool has no such dependency).
    //
    // Low-severity correction, Richard's review 14 Sept 2026: the earlier
    // version of this comment worried that an upgrade reordering an
    // INHERITED contract's own state could shift this slot. That specific
    // worry doesn't apply — OZ v5's upgradeable contracts (Initializable,
    // UUPSUpgradeable, AccessControlUpgradeable, ERC20Upgradeable, all four
    // inherited here) use ERC-7201 namespaced storage (keccak256-derived
    // slots, not sequential ones), so a change to any of THEIR internals
    // can't move where THIS contract's own variables land. What still
    // genuinely matters, and is still an audit item: append-only discipline
    // WITHIN this contract's own state — a future upgrade must only ADD new
    // variables after existing ones, never reorder or remove them, or THIS
    // contract's own slots (including this one) would shift.
    uint256 private _reentrancyLock;

    modifier nonReentrant() {
        if (!(_reentrancyLock == 0)) revert ReentrantCall();
        _reentrancyLock = 1;
        _;
        _reentrancyLock = 0;
    }

    /// @notice 11 Sept 2026 — answers an open question from Richard's review:
    /// shares are deliberately NON-transferable between users. Both
    /// userHighWaterValue and userFirstDepositAt (the loyalty-tier fee
    /// clock) are keyed purely by address — an unmodified, standard ERC20
    /// would let anyone transfer shares to a fresh wallet to reset the
    /// loyalty clock (jump straight to the 12%→5% tier) or dodge an
    /// existing high-water mark entirely. Blocking transfer closes that
    /// gap outright rather than trying to migrate per-user state on every
    /// transfer (real added complexity for a feature — secondary-market
    /// share liquidity — nothing in the spec actually asks for).
    /// Still allowed: minting (from == 0, on deposit), the redemption-
    /// request lock (to == address(this), in requestRedeem), and the burn
    /// at settlement (from == address(this) → 0, in _trySettleOne).
    function _update(address from, address to, uint256 value) internal override {
        if (!(from == address(0) || to == address(0) || to == address(this))) revert SharesNonTransferable();
        super._update(from, to, value);
    }

    // ── Roles ──────────────────────────────────────────────────────────────
    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    /// @notice Who may requestDeposit() while depositAllowlistEnabled is on.
    /// Administered by DEFAULT_ADMIN_ROLE (OZ default role admin).
    bytes32 public constant DEPOSITOR_ROLE = keccak256("DEPOSITOR_ROLE");
    /// @notice Decision 6 (30 Sept 2026): instant compromised-keeper
    /// revocation, Safe-only. Deliberately NOT PAUSER_ROLE -- that's held by
    /// the keeper wallet itself and (pre-decision-12-handover) a leftover
    /// deployer key, neither of which should gain this power. Administered
    /// by DEFAULT_ADMIN_ROLE like every other role here (no _setRoleAdmin
    /// call anywhere in this contract) -- post-handover that's the 48h
    /// timelock alone, never the Safe directly and never the keeper.
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    // DEFAULT_ADMIN_ROLE (from AccessControlUpgradeable) = the treasury/admin multisig.

    // ── Core asset — the one unit of account (§ "Settle first" #1 of the audit) ──
    IERC20 public asset; // USDT on BSC, 18 decimals

    // ── Allowlists (§3) ──────────────────────────────────────────────────────
    mapping(address => bool) public routerAllowed;
    mapping(address => bool) public tokenAllowed;
    address public primaryRouter; // used for totalAssets() valuation quotes

    // ── Price oracle (18 Sept 2026) ──────────────────────────────────────────
    // Optional by design -- address(0) means "not wired," and every token
    // keeps valuing off primaryRouter's live spot quote exactly as before
    // (see _quoteTokenValueEx()). Once set, only tokens PriceOracle has
    // actually onboarded (getTier() != None) switch to its trusted price;
    // an unregistered token held by the vault is NOT a new failure mode --
    // it falls back to the same spot-quote path every token used before
    // this was wired in, not a revert. See _quoteTokenValueEx()'s doc for
    // the full reasoning, including why a live spot quote is still fetched
    // even for oracle-covered tokens (the divergence cross-check).
    IPriceOracleView public priceOracle;

    address[] public heldTokensList;
    mapping(address => bool) private _isHeldToken;

    // ── Risk params — contract-enforced mirrors of config.risk.* (§3 table) ──
    uint256 public maxPositionUsd;
    uint16 public maxSlippageBps;
    uint16 public maxDailyTrades;
    uint256 public tradeDay;
    uint16 public tradesExecutedToday;

    // ── Pause state (§4) ─────────────────────────────────────────────────────
    bool public tradingPaused;

    // ── Deposit queue (§2b) ──────────────────────────────────────────────────
    struct DepositRequest {
        address user;
        uint256 assets;
        uint256 requestedAt;
        bool settled; // also true for a cancelled request — "closed", not just "paid out"
    }
    DepositRequest[] public depositQueue;
    uint256 public depositQueueHead;
    // Enough that a same-transaction (flash-loan) price push can never span
    // request and settlement — those must land in different blocks. Not a
    // liquidity-pacing delay like MAX_REDEMPTION_WAIT (deposits don't need
    // to raise funds, they only need one block boundary); kept short on
    // purpose so legitimate depositors aren't kept waiting.
    uint256 public constant MIN_DEPOSIT_SETTLE_DELAY = 10 minutes;
    // Sum of assets for every deposit request not yet settled or cancelled.
    // This cash already sits in the vault's own balance (escrowed at
    // request time) but hasn't bought shares yet — every NAV read used for
    // PRICING (settlement, convertToShares/Assets) must exclude it, or a
    // pending deposit would inflate the very price it's about to buy into.
    // See _netAssetsWithHealth().
    uint256 public pendingDepositTotal;

    // ── Redemption queue (§5) ────────────────────────────────────────────────
    struct RedemptionRequest {
        address user;
        uint256 shares;
        uint256 requestedAt;
        bool settled;
        uint256 userTotalSharesAtRequest; // for proportional HWM — see _trySettleOne
    }
    RedemptionRequest[] public redemptionQueue;
    uint256 public redemptionQueueHead;
    uint256 public constant MAX_REDEMPTION_WAIT = 7 days;
    /// @notice F4 fallback (28 Sept 2026): how long a request must have waited
    /// before forceSettleStale may settle it WHILE a held token is degraded or
    /// unpriceable (MAX_REDEMPTION_WAIT + 7 more days). Before this, settlement
    /// is blocked outright; see forceSettleStale and _trySettleOne.
    uint256 public constant MAX_BLOCKED_REDEMPTION_WAIT = 14 days;

    // ── Fee / high-water-mark accounting (§6) ────────────────────────────────
    address public treasury;
    /// @notice Highest USD value this user's position has ever represented.
    /// Raised by exactly the deposited amount on every deposit (so new
    /// principal is never mistaken for profit), lowered proportionally as
    /// redemptions settle. Performance fee = tierBps × max(0, value − this).
    mapping(address => uint256) public userHighWaterValue;
    /// @notice Set once, on a user's first-ever deposit — the loyalty clock.
    mapping(address => uint256) public userFirstDepositAt;

    // ── forceSettleStale sanity bound (Critical #1, Richard's review, 14 Sept 2026) ──
    // forceSettleStale is PERMISSIONLESS and prices at LIVE NAV inside the
    // caller's own transaction -- the exact same same-transaction-
    // manipulation shape async deposits were built to stop (§2b), just
    // aimed at redemptions instead. Attack: request a redemption, wait 7
    // days, then in one atomic transaction -- flash-loan, push a thin held
    // pool's price (ZEC's real pool was $44 deep), call forceSettleStale so
    // the payout prices off the inflated NAV, restore the pool, repay the
    // loan. lastSettledNavPerShareWad is the NAV-per-share (scaled 1e18)
    // from the last TRUSTED settlement (keeper-driven, or a forced one that
    // already passed this same check) -- forceSettleStale refuses to act
    // when live NAV has moved further from it than maxForceSettleNavDeviationBps
    // allows. Real market moves across a normal processing gap rarely
    // approach this; a same-transaction attack routinely will -- the
    // fork-measured real distortions were 67.5% and 2.4x. Not a full fix
    // (no oracle/TWAP exists), but it bounds the damage of exactly the
    // attack shape Richard described to a single-digit percentage instead
    // of unlimited, and repeated exploitation is rate-limited by needing a
    // fresh atomic attack (with its own cost/risk) each time, capped each
    // time.
    uint256 public lastSettledNavPerShareWad;
    // Set in initialize(), NOT here: an initializer on the declaration only
    // runs in the implementation's constructor, never in the proxy's
    // storage -- behind the proxy this read 0, which made forceSettleStale
    // revert on any NAV movement at all (21 Sept 2026 fix).
    uint16 public maxForceSettleNavDeviationBps; // 10% default, admin-tunable

    // ── PancakeSwap V3 (21 Sept 2026) ─────────────────────────────────────
    // Appended after every earlier state variable, per the append-only
    // storage rule in _reentrancyLock's doc. ~90% of the live bots' trades
    // route through V3 (buy side 47 of 50), and V2-only execution measured
    // 0.2-0.6% worse per buy on most traded tokens and 5-74% worse on thin
    // ones (ZEC, WLFI) -- see executeSwapV3() and setV3SpotPool().

    /// @notice V3 routers are a separate allowlist from V2 `routerAllowed`:
    /// different interface, and allowlisting one kind must never make it
    /// callable through the other kind's execution path.
    mapping(address => bool) public v3RouterAllowed;

    /// @notice Optional per-token V3 pool used for this token's LIVE spot
    /// price (valuation fallback when PriceOracle doesn't cover it, and the
    /// live side of the oracle's divergence cross-check when it does).
    /// Unset => the original V2 primaryRouter quote, unchanged. `quoteToken`
    /// is either `asset` or a token PriceOracle has a Chainlink feed for
    /// (typically WBNB) -- see setV3SpotPool().
    struct V3SpotSource {
        address pool;
        address quoteToken;
    }

    mapping(address => V3SpotSource) public v3SpotSource;

    // ── Limited-beta deposit controls (21 Sept 2026) ─────────────────────
    // Both gate NEW deposit requests only -- never redemptions, never a
    // depositor cancelling their own pending request -- so tightening them
    // can never trap anyone already in. Both are set explicitly in
    // initialize() (never declaration initializers: see
    // maxForceSettleNavDeviationBps), and both fail CLOSED if they were
    // ever zero: depositCap 0 blocks deposits rather than uncapping them.

    /// @notice Ceiling on totalAssets() (incl. pending deposits) that a new
    /// request may bring the vault up to. type(uint256).max = uncapped, and
    /// then the check is skipped entirely (no extra pricing calls).
    /// Soft limit: an unpriceable held token is excluded from totalAssets(),
    /// which can let the vault run slightly over the cap, never under-admit.
    uint256 public depositCap;

    /// @notice When true, only DEPOSITOR_ROLE holders can requestDeposit().
    bool public depositAllowlistEnabled;

    /// @notice Per-trade cap on EXITS: swaps from a held token back into the
    /// vault asset. maxPositionUsd caps a position's size when it's opened,
    /// but applying that same cap to the exit meant a position that had
    /// grown past it (or a cap lowered afterwards) could never be sold --
    /// the stop-loss/take-profit reverted forever. Exits get their own,
    /// larger cap instead; buys and token-to-token swaps keep
    /// maxPositionUsd (Critical #3b's one-shot-dump protection is unchanged
    /// for those). The effective exit cap is max(maxExitUsd, maxPositionUsd),
    /// so 0 (unset, and what an upgraded proxy reads) behaves exactly as
    /// before, and raising maxPositionUsd can never make exits tighter than
    /// buys. Appended last: storage slots of an existing proxy don't move.
    uint256 public maxExitUsd;

    /// @notice On-chain redemption reserve (22 Sept 2026, production-
    /// hardening item 1). Sum of `shares` across every redemption request
    /// that has been queued (requestRedeem) but not yet settled --
    /// incremented there, decremented in _trySettleOne() on success (both
    /// settleRedemptions' loop and forceSettleStale funnel through it, so
    /// one edit covers both). Redemptions don't escrow CASH up front the
    /// way a pending deposit does -- only shares get locked -- so before
    /// this, nothing on-chain stopped a BUY from spending idle cash a
    /// queued redemption was waiting on; that reserve existed bot-side
    /// only. See _redemptionReserveUsd() for how this converts to a USD
    /// figure, and _checkTradeBounds's BUY branch for where it's enforced.
    /// Appended last: storage slots of an existing proxy don't move.
    uint256 public pendingRedemptionShares;

    /// @notice Production-hardening item 2 (22 Sept 2026) -- defeats a
    /// same-block front-run of settleRedemptions()/forceSettleStale(): an
    /// attacker who pushes a held token's LIVE SPOT price out of its
    /// PriceOracle divergence tolerance right before a settlement tx used
    /// to make that token value at exactly 0 for that read (see
    /// _totalAssetsWithHealth()), understating the redeemer's payout while
    /// every other holder's relative share gained the difference.
    ///
    /// `divergenceFlaggedSince[token]` records the first block.timestamp a
    /// token was observed diverging; 0 means "not currently flagged." A
    /// token only actually zeros out in _trySettleOne() once it has stayed
    /// flagged for the full DIVERGENCE_CONFIRMATION_WINDOW -- an atomic,
    /// same-transaction manipulation can never span that, the same
    /// block-boundary principle MIN_DEPOSIT_SETTLE_DELAY already uses
    /// against a flash-loan deposit attack (§2b). Inside the window, the
    /// token is valued at the ORACLE's own trusted Chainlink/TWAP price
    /// (checkChainlinkDivergence/checkTwapDivergence already compute and
    /// return this as `trustedPriceWad` even when `withinTolerance` is
    /// false -- see _quoteExcludedTokenAtTrustedPrice()) -- never the
    /// live/manipulated spot number, and never a blind zero. The window
    /// doesn't weaken manipulation resistance: the manipulated spot price
    /// is never the number used, at any point during it -- it only
    /// controls how long a token that's GENUINELY broken (dead pool, bad
    /// feed) keeps using a possibly-stale trusted price before the
    /// contract gives up and excludes it, a staleness tradeoff, not a
    /// security one.
    ///
    /// `flaggedTokensList`/`_isFlagged` track only CURRENTLY-flagged
    /// tokens (expected empty in normal operation) -- same
    /// small-discoverability-list pattern as heldTokensList/_isHeldToken
    /// above -- so clearing a recovered token's flag is a cheap in-memory
    /// comparison against this round's excludedTokens, not a second pass
    /// over every held token.
    mapping(address => uint256) public divergenceFlaggedSince;
    address[] public flaggedTokensList;
    mapping(address => bool) private _isFlagged;
    uint256 public constant DIVERGENCE_CONFIRMATION_WINDOW = 10 minutes;

    /// @notice Production-hardening item 3 (22 Sept 2026) -- admin-tunable
    /// slippage floor for adminEmergencyExitV3(), deliberately WIDER than
    /// maxSlippageBps (this path exists precisely because the normal
    /// path's own divergence gate has already refused the token). Set in
    /// initialize(), not a declaration initializer (same lesson as
    /// maxForceSettleNavDeviationBps -- an initializer on the declaration
    /// only runs in the implementation's own constructor, never behind the
    /// proxy). Ceiling matches PriceOracle.setDeviationBps's own 50%
    /// convention, keeping this contract's admin-tunable-tolerance pattern
    /// consistent rather than introducing a new one.
    uint16 public emergencyExitMaxSlippageBps;

    uint16 public constant FEE_TIER_0_30D = 1200; // 12%
    uint16 public constant FEE_TIER_30_90D = 1000; // 10%
    uint16 public constant FEE_TIER_90_180D = 700; // 7%
    uint16 public constant FEE_TIER_180D_PLUS = 500; // 5%

    // ── Events ───────────────────────────────────────────────────────────────
    event DepositRequested(uint256 indexed requestId, address indexed user, uint256 assets);
    event DepositSettled(uint256 indexed requestId, address indexed user, uint256 assets, uint256 shares);
    event DepositCancelled(uint256 indexed requestId, address indexed user, uint256 refunded);
    event RedeemRequested(uint256 indexed requestId, address indexed user, uint256 shares);
    event RedeemSettled(uint256 indexed requestId, address indexed user, uint256 shares, uint256 grossAssets, uint256 fee);
    event SwapExecuted(address indexed keeper, address indexed router, address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOut);
    event TradingPaused(address indexed by);
    event TradingUnpaused(address indexed by);
    /// @notice Decision 6 (30 Sept 2026). Kept deliberately, unlike
    /// EmergencyExitExecuted (dropped 22 Sept to reclaim bytecode) -- a
    /// keeper revoke is exactly the kind of event the team needs visible
    /// on-chain, not something to infer later from a role-check off SwapExecuted.
    event KeeperEmergencyRevoked(address indexed account, address indexed by);
    event TokenAllowedSet(address indexed token, bool allowed);
    event HeldTokenForceRemoved(address indexed token);
    event RouterAllowedSet(address indexed router, bool allowed);
    event RiskParamsSet(uint256 maxPositionUsd, uint16 maxSlippageBps, uint16 maxDailyTrades);
    event TreasurySet(address indexed treasury);
    event PrimaryRouterSet(address indexed router);
    event PriceOracleSet(address indexed oracle);
    event MaxForceSettleNavDeviationBpsSet(uint16 bps);
    event EmergencyExitMaxSlippageBpsSet(uint16 bps);
    event V3RouterAllowedSet(address indexed router, bool allowed);
    event V3SpotPoolSet(address indexed token, address indexed pool, address indexed quoteToken);
    event DepositCapSet(uint256 cap);
    event MaxExitUsdSet(uint256 maxExitUsd);
    event DepositAllowlistEnabledSet(bool enabled);
    /// @notice 18 Sept 2026, vault roadmap item 3 -- fired whenever a
    /// redemption actually settles against a NAV that excluded one or more
    /// held tokens' value (proportional-exclusion fix). Purely an
    /// observability signal for off-chain tooling/depositors -- nothing in
    /// the contract reads this back. `heldBalance` is the raw token amount
    /// still held, not a USD value, since the whole reason it's excluded
    /// is that no trusted value could be computed for it.
    event TokenExcludedFromSettlement(uint256 indexed requestId, address indexed token, uint256 heldBalance);
    /// @notice 22 Sept 2026, production-hardening item 2 -- a token was just
    /// observed diverging for the first time (or is still within its
    /// confirmation window) and was valued at the oracle's own trusted
    /// price for this settlement rather than excluded. Purely an
    /// observability signal, same spirit as TokenExcludedFromSettlement.
    event TokenDivergenceFlagged(address indexed token, uint256 since);
    /// @notice Fired once a previously-flagged token prices cleanly again
    /// (its live spot is back within tolerance of the oracle's trusted
    /// price) -- the flag and its confirmation clock are both cleared.
    event TokenDivergenceCleared(address indexed token);

    // ── Errors ───────────────────────────────────────────────────────────────
    // Custom errors replaced revert strings on 21 Sept 2026 to free contract
    // size (EIP-170). Same conditions, same call sites, same check order --
    // only the revert payload changed from a string to a selector.
    error ReentrantCall();
    error SharesNonTransferable();
    error ZeroAddress();
    error SeedDepositRequired();
    error DepositsPaused();
    error ZeroDeposit();
    error BadRequestId();
    error NotYourRequest();
    error AlreadySettledOrCancelled();
    error NotAuthorized();
    error ZeroShares();
    error InsufficientShares();
    error AlreadySettled();
    error NotStaleYet();
    /// @dev Live NAV strayed past maxForceSettleNavDeviationBps from the last
    /// trusted settlement -- possible manipulation; wait for the keeper.
    error ForceSettleNavDeviatesTooFar();
    error InsufficientIdleLiquidity();
    error RedemptionBlockedByUnhealthyToken();
    error DeviationBpsOutOfRange();
    error TradingIsPaused(); // `TradingPaused` is taken by the event
    error RouterNotAllowlisted();
    error V3RouterNotAllowlisted();
    error BadPath();
    error TokenInNotAllowlisted();
    error TokenOutNotAllowlisted();
    error PathHopNotAllowlisted();
    error ExceedsTradeableCapital(); // amount exceeds tradeable capital (excludes pending deposits)
    error CannotValueTradeInput();
    error CannotValueTradeOutput();
    error CannotIndependentlyValueTokenOut();
    error ExceedsMaxPositionSize();
    error ExceedsMaxExitSize();
    error MinOutBelowSlippageBound();
    error PrimaryRouterQuoteDiverges();
    error DailyTradeLimitReached();
    error ReceivedLessThanMinOut();
    error NotAHeldToken();
    error SlippageCapTooLoose();
    error PoolDoesNotContainToken();
    error QuoteTokenNotPriceable(); // must be the asset or Chainlink-priced
    error V3SpotPoolCannotPrice();
    error DepositorNotAllowlisted();
    error DepositCapExceeded();
    /// @dev adminEmergencyExitV3 requires an independent, on-chain trusted
    /// price to bound its slippage floor against -- a token PriceOracle has
    /// never priced at all (getTier() == None) has no such reference, so
    /// this path refuses it. adminForceRemoveHeldToken remains the only
    /// lever for that case.
    error TokenNotOracleCovered();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @dev Permanently locked "dead" address for the seed-deposit shares
    /// below — standard convention (no known private key), not the zero
    /// address (minting there isn't the point; making the shares
    /// unspendable by anyone is).
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    /// @param _seedAssets High #5 fix, Richard's review 14 Sept 2026:
    /// "the first depositor mints 1 wei-share, donates USDT directly to
    /// the vault, and every later deposit rounds down: either stolen or
    /// bricking the queue." A real, non-trivial seed deposit (permanently
    /// locked, not redeemable by anyone) means an attacker can never
    /// become a cheap, dominant share of total supply the way they could
    /// against an empty vault — his own prescribed fix ("seed the vault at
    /// deployment"), not a substitute virtual-shares formula, since that
    /// would touch every pricing call site and is more surface area to get
    /// subtly wrong than doing exactly what he asked. Required (not
    /// optional) so no real deployment can accidentally skip it.
    function initialize(
        address _asset,
        address _admin,
        address _keeper,
        address _treasury,
        address _primaryRouter,
        string memory _name,
        string memory _symbol,
        uint256 _seedAssets
    ) external initializer {
        if (!(_asset != address(0) && _admin != address(0) && _keeper != address(0) && _treasury != address(0) && _primaryRouter != address(0))) revert ZeroAddress();
        if (!(_seedAssets > 0)) revert SeedDepositRequired();

        __ERC20_init(_name, _symbol);
        __AccessControl_init();

        asset = IERC20(_asset);
        treasury = _treasury;
        primaryRouter = _primaryRouter;

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(KEEPER_ROLE, _keeper);
        _grantRole(PAUSER_ROLE, _admin);
        _grantRole(PAUSER_ROLE, _keeper); // bot can pause for safety; only admin can unpause

        maxPositionUsd = 25 ether; // sane starting default — admin tunes via setRiskParams
        maxSlippageBps = 300; // 3% ceiling
        maxDailyTrades = 10;
        maxExitUsd = 0; // unset: exits capped at maxPositionUsd until an admin raises it
        maxForceSettleNavDeviationBps = 1000; // 10%
        emergencyExitMaxSlippageBps = 2000; // 20% -- production-hardening item 3
        depositCap = type(uint256).max; // uncapped until a deployment sets one
        depositAllowlistEnabled = false; // explicit, so the default is visible here

        // The deployer must have pre-approved this vault's (deterministic,
        // pre-computed) proxy address for at least _seedAssets before
        // deployment — standard practice for a same-transaction seed.
        asset.safeTransferFrom(msg.sender, address(this), _seedAssets);
        _mint(DEAD, _seedAssets); // 1:1 at genesis, permanently unspendable
    }

    // ── Deposits: request now, settle later at settlement-time NAV (§2b) ────
    // Mirrors the redemption queue exactly — see the top-level NatSpec §2b
    // for why (pool-manipulation resistance).

    function requestDeposit(uint256 assets) external nonReentrant returns (uint256 requestId) {
        if (tradingPaused) revert DepositsPaused();
        if (!(assets > 0)) revert ZeroDeposit();
        if (depositAllowlistEnabled && !hasRole(DEPOSITOR_ROLE, msg.sender)) revert DepositorNotAllowlisted();
        if (depositCap != type(uint256).max && totalAssets() + assets > depositCap) revert DepositCapExceeded();

        asset.safeTransferFrom(msg.sender, address(this), assets);
        pendingDepositTotal += assets;

        requestId = depositQueue.length;
        depositQueue.push(
            DepositRequest({user: msg.sender, assets: assets, requestedAt: block.timestamp, settled: false})
        );
        emit DepositRequested(requestId, msg.sender, assets);
    }

    /// @notice A depositor can cancel their own not-yet-settled request at
    /// any time for a full refund. Unlike a redemption request (shares
    /// already locked, settlement price is the whole point of waiting),
    /// nothing has been bought yet here — no reason to force someone to
    /// wait out a keeper outage to get their own money back.
    function cancelDepositRequest(uint256 requestId) external nonReentrant {
        if (!(requestId < depositQueue.length)) revert BadRequestId();
        DepositRequest storage r = depositQueue[requestId];
        if (!(r.user == msg.sender)) revert NotYourRequest();
        if (r.settled) revert AlreadySettledOrCancelled();

        uint256 refund = r.assets;
        r.settled = true; // reuse as "closed" — settleDeposits skips it either way
        r.assets = 0;
        pendingDepositTotal -= refund;

        asset.safeTransfer(msg.sender, refund);
        emit DepositCancelled(requestId, msg.sender, refund);
    }

    /// @notice Process the FIFO queue up to `maxToProcess` requests.
    /// Keeper-callable every cycle, same shape as settleRedemptions().
    function settleDeposits(uint256 maxToProcess) external nonReentrant {
        if (!(hasRole(KEEPER_ROLE, msg.sender) || hasRole(DEFAULT_ADMIN_ROLE, msg.sender))) revert NotAuthorized();
        uint256 processed = 0;
        uint256 i = depositQueueHead;
        while (i < depositQueue.length && processed < maxToProcess) {
            if (!depositQueue[i].settled) {
                if (!_trySettleDeposit(i)) break; // too soon, or price feed unavailable — stop, preserve FIFO order
                processed++;
            }
            i++;
        }
        _advanceDepositQueueHead();
    }

    function _advanceDepositQueueHead() internal {
        while (depositQueueHead < depositQueue.length && depositQueue[depositQueueHead].settled) {
            depositQueueHead++;
        }
    }

    function _trySettleDeposit(uint256 requestId) internal returns (bool) {
        DepositRequest storage r = depositQueue[requestId];
        if (block.timestamp < r.requestedAt + MIN_DEPOSIT_SETTLE_DELAY) return false;

        // Deposit settlement deliberately keeps the ORIGINAL 11 Sept
        // block-on-unhealthy behavior — the roadmap item 3 fix (exclude,
        // don't block) only applies to redemptions. Minting shares against
        // an understated NAV here would mint MORE shares than correct,
        // diluting every existing holder — the opposite direction of
        // redemption's "pay out less" safety margin, and a real exploit
        // (deliberately deposit while a token is degraded to unpriceable
        // to mint cheap shares). This path must keep refusing to settle
        // until every held token prices cleanly again.
        (uint256 netAssets, bool healthy, ) = _netAssetsWithHealth();
        if (!healthy) return false;

        uint256 supply = totalSupply();
        // netAssets already excludes THIS request's own escrowed cash (and
        // every other still-pending request's) via pendingDepositTotal —
        // see _netAssetsWithHealth(). That's the pre-this-deposit NAV the
        // share price must be computed against.
        uint256 shares = (supply == 0 || netAssets == 0) ? r.assets : (r.assets * supply) / netAssets;

        // High #5 fix, Richard's review 14 Sept 2026: this used to `require`
        // shares > 0, which REVERTS the entire settleDeposits() call. Since
        // the queue is strict FIFO, one dust request that rounds to zero
        // shares would permanently block every request behind it. Skip and
        // refund instead — the depositor gets their money back immediately
        // (same real-world outcome as calling cancelDepositRequest
        // themselves), and the queue keeps moving.
        if (shares == 0) {
            uint256 refund = r.assets;
            pendingDepositTotal -= refund;
            r.settled = true;
            r.assets = 0;
            asset.safeTransfer(r.user, refund);
            emit DepositCancelled(requestId, r.user, refund);
            return true;
        }

        pendingDepositTotal -= r.assets;
        r.settled = true;

        // Loyalty clock anchors to REQUEST time, not settlement time — real
        // capital was already committed (escrowed) at the request; a slow
        // keeper shouldn't be able to unfairly delay a user's own clock.
        if (userFirstDepositAt[r.user] == 0) {
            userFirstDepositAt[r.user] = r.requestedAt;
        }
        userHighWaterValue[r.user] += r.assets;

        _mint(r.user, shares);

        // Same trusted-reference update as _trySettleOne — see
        // lastSettledNavPerShareWad's doc (Critical #1).
        lastSettledNavPerShareWad = _navPerShareWad(netAssets, supply);

        emit DepositSettled(requestId, r.user, r.assets, shares);
        return true;
    }

    // ── Redemption: request now, settle later at settlement-time NAV ────────

    function requestRedeem(uint256 shares) external nonReentrant returns (uint256 requestId) {
        if (!(shares > 0)) revert ZeroShares();
        if (!(balanceOf(msg.sender) >= shares)) revert InsufficientShares();

        uint256 userTotalSharesAtRequest = balanceOf(msg.sender);
        _transfer(msg.sender, address(this), shares); // locked, not burned — burned at settlement
        pendingRedemptionShares += shares;

        requestId = redemptionQueue.length;
        redemptionQueue.push(
            RedemptionRequest({
                user: msg.sender,
                shares: shares,
                requestedAt: block.timestamp,
                settled: false,
                userTotalSharesAtRequest: userTotalSharesAtRequest
            })
        );
        emit RedeemRequested(requestId, msg.sender, shares);
    }

    /// @notice Process the FIFO queue up to `maxToProcess` requests, paying
    /// out whatever idle stablecoin is actually available. Keeper-callable
    /// every cycle (the bot's own liquidity-aware pacing) — NOT blocked by
    /// tradingPaused, since a pause must never mean "withdrawals stop too."
    function settleRedemptions(uint256 maxToProcess) external nonReentrant {
        if (!(hasRole(KEEPER_ROLE, msg.sender) || hasRole(DEFAULT_ADMIN_ROLE, msg.sender))) revert NotAuthorized();
        uint256 processed = 0;
        uint256 i = redemptionQueueHead;
        while (i < redemptionQueue.length && processed < maxToProcess) {
            if (!redemptionQueue[i].settled) {
                if (!_trySettleOne(i)) break; // out of idle liquidity, or a held token is degraded/unpriceable (F4) — stop, preserve FIFO order
                processed++;
            }
            i++;
        }
        _advanceQueueHead();
    }

    /// @notice Permissionless backstop (§5): once a request has waited past
    /// MAX_REDEMPTION_WAIT, ANYONE can force it through — even if that means
    /// the vault is under liquidity pressure. This is what stops "the bot is
    /// pacing withdrawals prudently" from quietly becoming "funds are stuck."
    ///
    /// @dev Security-audit fix (29 Sept 2026) -- Critical #1's deviation
    /// check compared live NAV against lastSettledNavPerShareWad, which
    /// EVERY settlement updated, forced ones included. That let an attacker
    /// with several separately-stale redemption requests chain forced
    /// settlements: each one individually stayed within
    /// maxForceSettleNavDeviationBps (the intended ~10% single-digit-
    /// percentage bound), but each one also RATCHETED the reference a
    /// forced settlement is checked against, so a sequence of small,
    /// individually-legal pushes compounded past it with no ceiling --
    /// proven directly: 5 chained ~9% steps compounded to +53.9% versus
    /// true fair value, each step passing its own check
    /// (test_POC_CompoundingForceSettleStaleDeviation, before this fix).
    /// _trySettleOne's new `updateTrustedNav` parameter closes this: a
    /// forced settlement here still gets checked against, and can still
    /// happen at, up to maxForceSettleNavDeviationBps away from the
    /// reference -- but never gets to MOVE that reference for the next
    /// forced settlement. Only a genuine keeper/admin settlement
    /// (settleRedemptions, or a deposit settling) still updates it. Traded
    /// away on purpose: if the keeper is down long enough for a real market
    /// move to exceed the tolerance from its own last settlement, this
    /// backstop now reverts until the keeper resumes (or admin widens
    /// maxForceSettleNavDeviationBps) rather than self-healing one step at
    /// a time -- the right side of that tradeoff for a check whose entire
    /// point is bounding manipulation, not maximizing uptime under one.
    function forceSettleStale(uint256 requestId) external nonReentrant {
        if (!(requestId < redemptionQueue.length)) revert BadRequestId();
        RedemptionRequest storage r = redemptionQueue[requestId];
        if (r.settled) revert AlreadySettled();
        if (!(block.timestamp >= r.requestedAt + MAX_REDEMPTION_WAIT)) revert NotStaleYet();

        // The NAV deviation check (Critical #1) now lives at the top of
        // _trySettleOne, for mode != 0, so it runs against the SAME corrected
        // NAV the payout uses (mode is read from msg.sig there). 28 Sept 2026 (F4 decision, Option A + fallback):
        // while any held token is degraded or unpriceable, redemption settlement
        // is blocked (see _trySettleOne) and so is this permissionless backstop,
        // until the request has waited MAX_BLOCKED_REDEMPTION_WAIT (14 days, i.e.
        // 7 days past the normal stale threshold) -- a deliberately longer window
        // for the token to recover or for governance to act (oracle fix,
        // adminEmergencyExitV3, or a write-off, all timelocked). After that the
        // request is settled anyway rather than left voided (mode 2, decided in
        // _trySettleOne from the request's age).
        if (!(_trySettleOne(requestId))) revert InsufficientIdleLiquidity();
        _advanceQueueHead();
    }

    function _navPerShareWad(uint256 netAssets, uint256 supply) internal pure returns (uint256) {
        return supply == 0 ? 0 : (netAssets * 1e18) / supply;
    }

    function setMaxForceSettleNavDeviationBps(uint16 bps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (!(bps > 0 && bps <= 5000)) revert DeviationBpsOutOfRange();
        maxForceSettleNavDeviationBps = bps;
        emit MaxForceSettleNavDeviationBpsSet(bps);
    }

    function _advanceQueueHead() internal {
        while (redemptionQueueHead < redemptionQueue.length && redemptionQueue[redemptionQueueHead].settled) {
            redemptionQueueHead++;
        }
    }

    /// Settlement mode is read from the CALLING CONTEXT, not passed as an
    /// argument: 0 = routine (settleRedemptions); 1 = forceSettleStale after
    /// MAX_REDEMPTION_WAIT; 2 = forceSettleStale after
    /// MAX_BLOCKED_REDEMPTION_WAIT (the F4 fallback, see below). (Measured: a
    /// literal mode argument makes the optimizer clone this whole function per
    /// call site, +1.3k bytes. Any future caller other than forceSettleStale
    /// gets mode 0, the blocking one, which is the safe default.)
    ///
    /// @dev Security-audit fix (29 Sept 2026) -- mode 0 (routine,
    /// keeper/admin-gated) is also the only mode that updates
    /// lastSettledNavPerShareWad, below. Before this fix EVERY settlement
    /// updated it, forced ones (mode 1/2) included, which let a chain of
    /// forced settlements each individually pass the ~10% deviation check
    /// above while ratcheting the reference the NEXT one was checked
    /// against -- proven directly: 5 chained ~9% steps compounded to
    /// +53.9% versus true fair value, each step legal on its own terms
    /// (test_ForceSettleStaleCannotCompoundNavDriftAcrossMultipleCalls
    /// exercises this). A forced settlement can still happen, and is still
    /// bounded to ~10% from the reference -- it just never gets to MOVE
    /// that reference for the next forced settlement.
    function _trySettleOne(uint256 requestId) internal returns (bool) {
        RedemptionRequest storage r = redemptionQueue[requestId];
        uint256 supply = totalSupply();
        uint8 mode = msg.sig == this.forceSettleStale.selector
            ? (block.timestamp >= r.requestedAt + MAX_BLOCKED_REDEMPTION_WAIT ? 2 : 1)
            : 0;
        // 18 Sept 2026 fix (vault roadmap item 3) — SUPERSEDES the 11 Sept
        // fix's block-everyone behavior. That fix was written before
        // PriceOracle's divergence check existed; now a single token
        // degrading to unpriceable is the EXPECTED, more frequent outcome
        // of live spot merely disagreeing with a trusted price, not just a
        // genuine outage — blocking every depositor's redemption over one
        // token's temporary divergence is a worse failure mode than the
        // one it was trying to prevent, and is itself a manipulation
        // vector (push one thin token's price out of tolerance, freeze
        // every unrelated redemption).
        //
        // netAssets from _netAssetsWithHealth() already EXCLUDES an
        // unpriceable token's value (_totalAssetsWithHealth's per-token
        // loop contributes exactly 0 for it) -- that conservative
        // understatement is now the actual safety net: settlement
        // proceeds against the PRICEABLE remainder only, never an
        // inflated number. The excluded position itself is untouched --
        // still held, still reachable once it's priceable again, or via
        // adminForceRemoveHeldToken if it never will be. `healthy` is
        // deliberately discarded here, not read -- see this function's
        // NatSpec-level doc and the "all held value unpriceable at once"
        // test for the edge this trades away (idle-cash-only NAV) versus
        // the one it closes (a DoS on every other depositor's exit).
        (uint256 netAssets, , address[] memory excludedTokens) = _netAssetsWithHealth();

        // 28 Sept 2026 -- F4 decision (Richard), plain Option A: redemption
        // settlement is BLOCKED, unconditionally, while ANY held token is
        // degraded or unpriceable (one rule for both; no materiality
        // threshold, no partial case). Left as it was, an excluded token
        // counts as zero here and the redeemer is underpaid while everyone
        // who stays gains the difference (rehearsal F4, audit S3); that also
        // wrote the understated NAV into lastSettledNavPerShareWad. Deposits
        // already block on unhealthy NAV (_trySettleDeposit). Routine
        // settlement returns false, not a revert: settleRedemptions stops at
        // the head (FIFO kept), requests stay queued and their cash stays
        // reserved, and settlement resumes on its own once every held token
        // prices again. forceSettleStale (mode 1) reverts with a specific
        // error instead of the misleading InsufficientIdleLiquidity.
        //
        // This deliberately reverses the 18 Sept item-3 choice ("don't block
        // everyone over one token"): a stalled token now stalls all
        // redemptions, the price of never paying at an understated NAV.
        //
        // The way out is mode 2: forceSettleStale after
        // MAX_BLOCKED_REDEMPTION_WAIT settles anyway, through item 2's loop
        // below, which already does exactly the valuation the fallback needs:
        // a degraded token at the oracle's trusted price, an unpriceable one
        // at zero with a TokenExcludedFromSettlement event. Mode 2 bypasses
        // that loop's 10-minute confirmation window (there is nothing left to
        // confirm after 14 days); the window is otherwise untouched, and in
        // modes 0 and 1 it is unreachable because we return before it.
        if (excludedTokens.length != 0 && mode != 2) {
            if (mode == 1) revert RedemptionBlockedByUnhealthyToken();
            return false;
        }

        // Production-hardening item 2 (22 Sept 2026) -- see
        // divergenceFlaggedSince's doc. A token whose divergence hasn't yet
        // persisted for the full DIVERGENCE_CONFIRMATION_WINDOW is graced
        // back into netAssets at the ORACLE's own trusted price (never the
        // live/manipulated spot number that triggered the exclusion, never
        // a blind zero) instead of being treated as genuinely excluded.
        // Only a CONFIRMED, window-spanning divergence still zeros out --
        // exactly the same outcome as before this fix, just delayed long
        // enough that a same-transaction manipulation can't manufacture it.
        address[] memory confirmedExcluded = new address[](excludedTokens.length);
        uint256 confirmedCount = 0;
        for (uint256 i = 0; i < excludedTokens.length; i++) {
            address token = excludedTokens[i];
            uint256 since = divergenceFlaggedSince[token];
            if (since == 0) {
                since = block.timestamp;
                divergenceFlaggedSince[token] = since;
                _isFlagged[token] = true;
                flaggedTokensList.push(token);
                emit TokenDivergenceFlagged(token, since);
            }
            if (mode == 2) {
                // 30 Sept 2026, audit decision 13: priced at the DISTRESS
                // price (lower of Chainlink/TWAP, S1's own read), not the
                // single trusted-tier price item 2's grace window uses below.
                // Found in F4_S1_INTERACTION_REVIEW_2026-09-30.md: paying
                // every queued redemption at a single trusted price that
                // adminEmergencyExitV3 (S1) can't actually realize on the
                // market overpays redeemers at the expense of whoever's
                // shares remain. Using the same conservative number both
                // paths already agree on closes that gap -- what the vault
                // pays out here and what it can actually get by selling
                // (S1) are now the same read.
                // No oracle wired at all -- _quoteAtDistressPrice/ValuationLib
                // has nothing to call, same "no grace possible" case
                // _quoteExcludedTokenAtTrustedPrice already guards below.
                (uint256 distressValue, bool distressOk) = address(priceOracle) == address(0)
                    ? (0, false)
                    : _quoteAtDistressPrice(token, IERC20(token).balanceOf(address(this)));
                if (distressOk) {
                    netAssets += distressValue;
                } else {
                    // No oracle wired, or neither source is readable -- the
                    // accepted F3 residual (audit decision 11, condition 1).
                    // Same conservative failure as before this fix.
                    confirmedExcluded[confirmedCount++] = token;
                }
            } else if (block.timestamp < since + DIVERGENCE_CONFIRMATION_WINDOW) {
                // Item 2's own grace window, untouched (22 Sept 2026).
                (uint256 graceValue, bool graceOk) = _quoteExcludedTokenAtTrustedPrice(token);
                if (graceOk) {
                    netAssets += graceValue;
                } else {
                    // Even the oracle's own trusted price can't be fetched
                    // right now (feed deactivated, genuinely stale) --
                    // same conservative failure as before this fix.
                    confirmedExcluded[confirmedCount++] = token;
                }
            } else {
                confirmedExcluded[confirmedCount++] = token; // confirmed unhealthy across the full window
            }
        }
        _clearRecoveredDivergenceFlags(excludedTokens);

        // Critical #1 fix (moved here from forceSettleStale, 28 Sept 2026, so
        // it checks the SAME corrected NAV the payout uses, including the mode 2
        // fallback valuation). Forced settlement only. See
        // lastSettledNavPerShareWad's doc. Skipped only on true bootstrap
        // (nothing has ever settled yet); a redemption can't realistically
        // exist before a deposit has settled first.
        //
        // 18 Sept 2026 (vault roadmap item 3): this used to refuse to
        // force-settle AT ALL while any token was unpriceable -- itself a
        // manipulation vector on this permissionless backstop -- so the
        // comparison runs against the corrected NAV instead. In mode 2 that
        // is also what bounds a zero-valued token's underpayment: a token
        // large enough to move NAV past the band keeps the backstop refused,
        // and governance must widen the band (setMaxForceSettleNavDeviationBps)
        // or write the token off.
        if (mode != 0 && lastSettledNavPerShareWad != 0) {
            uint256 liveNav = _navPerShareWad(netAssets, supply);
            uint256 diff = liveNav > lastSettledNavPerShareWad
                ? liveNav - lastSettledNavPerShareWad
                : lastSettledNavPerShareWad - liveNav;
            if (!(diff * 10000 <= lastSettledNavPerShareWad * maxForceSettleNavDeviationBps)) revert ForceSettleNavDeviatesTooFar();
        }

        uint256 grossValue = (r.shares * netAssets) / supply; // settlement-time NAV, not request-time
        // Critical #2 fix, Richard's review 14 Sept 2026: this used to read
        // the RAW balance, which includes every still-pending deposit's
        // escrowed cash (pendingDepositTotal) -- executeSwap() already
        // excludes that cash from what the keeper can trade, but redemption
        // payouts were never excluded from spending it. A redemption could
        // pay out using a depositor's own escrowed money; when that
        // depositor then calls cancelDepositRequest(), the refund transfer
        // reverts because the cash is already gone, breaking the function's
        // own promise that a pending deposit can always be cancelled.
        uint256 rawBalance = asset.balanceOf(address(this));
        uint256 idle = rawBalance > pendingDepositTotal ? rawBalance - pendingDepositTotal : 0;
        if (idle < grossValue) return false;

        // Observability only (roadmap item 3 follow-up) — fired only once
        // settlement is actually going to succeed, not on a failed attempt
        // above. Reports the excluded token's raw held balance, not a USD
        // value, since no trusted value exists for it by definition.
        //
        // 22 Sept 2026 (production-hardening item 2): narrowed to
        // confirmedExcluded -- a token still inside its grace window was
        // valued at the oracle's trusted price above, not actually
        // excluded, so it no longer belongs in this event.
        for (uint256 i = 0; i < confirmedCount; i++) {
            emit TokenExcludedFromSettlement(requestId, confirmedExcluded[i], IERC20(confirmedExcluded[i]).balanceOf(address(this)));
        }

        address user = r.user;
        uint256 proportionalHWM = r.userTotalSharesAtRequest == 0
            ? 0
            : (userHighWaterValue[user] * r.shares) / r.userTotalSharesAtRequest;

        uint256 feeBps = _feeTierFor(user);
        uint256 profit = grossValue > proportionalHWM ? grossValue - proportionalHWM : 0;
        uint256 fee = (profit * feeBps) / 10000;
        uint256 netToUser = grossValue - fee;

        userHighWaterValue[user] =
            userHighWaterValue[user] > proportionalHWM ? userHighWaterValue[user] - proportionalHWM : 0;

        r.settled = true;
        pendingRedemptionShares -= r.shares;
        _burn(address(this), r.shares);

        // Record this settlement's NAV as the new trusted reference for
        // forceSettleStale's sanity check (Critical #1) -- uses supply/
        // netAssets from BEFORE this settlement's own burn, i.e. the price
        // this settlement actually transacted at. Skipped for a forced
        // settlement (mode != 0) -- see this function's own doc
        // (security-audit fix, 29 Sept 2026): letting a forced settlement
        // move this reference is exactly what let a chain of
        // individually-legal forced settlements compound past the intended
        // single-digit-percentage bound.
        //
        // SolidityScan triage, 5 Oct 2026 (H001): this write, and the event
        // below, used to come AFTER the two safeTransfer calls -- a CEI
        // ordering deviation (checks-effects-interactions). `nonReentrant`
        // already blocks reentering any other guarded vault function during
        // the transfers, and the configured `asset` (USDT) has no
        // transfer-time callback today, so this wasn't demonstrated as
        // exploitable -- moved anyway, since it's free and removes the
        // ambiguity if `asset` is ever anything other than a plain ERC20.
        if (mode == 0) {
            lastSettledNavPerShareWad = _navPerShareWad(netAssets, supply);
        }
        emit RedeemSettled(requestId, user, r.shares, grossValue, fee);

        if (fee > 0) asset.safeTransfer(treasury, fee);
        asset.safeTransfer(user, netToUser);
        return true;
    }

    /// @dev Production-hardening item 2 -- values a token that just failed
    /// its live-spot-vs-oracle divergence check at the ORACLE's OWN
    /// trusted price instead, for a token still inside its confirmation
    /// grace window. checkChainlinkDivergence/checkTwapDivergence already
    /// compute and return `trustedPriceWad` even when `withinTolerance` is
    /// false (see PriceOracle.sol) -- this re-runs that same check and
    /// uses trustedPriceWad directly, deliberately ignoring
    /// withinTolerance, rather than fetching anything new. A live spot
    /// quote is still required to make that call (its signature demands
    /// one), even though its value is never used here -- same shape as
    /// _fetchTrustedPrice's own cross-check call. Every failure
    /// (can't fetch a live quote at all, feed deactivated, no deviation
    /// tolerance configured) is (0, false) -- same conservative fallback
    /// as the rest of this valuation stack.
    function _quoteExcludedTokenAtTrustedPrice(address token) internal view returns (uint256, bool) {
        if (address(priceOracle) == address(0)) return (0, false); // no oracle wired -- no grace possible

        uint256 bal = IERC20(token).balanceOf(address(this));
        if (bal == 0) return (0, true);

        IPriceOracleView.Tier tier = priceOracle.getTier(token);
        if (tier == IPriceOracleView.Tier.None) return (0, false); // no oracle coverage -- no independent trusted price exists, no grace possible

        // Shared with _quoteAtTrustedPrice's own callers (22/23 Sept 2026,
        // contract-size pass) -- same live-spot-then-trusted-
        // price fetch, just applied to the token's whole held balance
        // instead of an arbitrary trade amount.
        (, uint256 trustedPriceWad, bool ok) = _fetchTrustedPrice(token, tier);
        if (!ok) return (0, false);
        uint8 tokenDecimals = IERC20DecimalsMinimal(token).decimals();
        return (Math.mulDiv(bal, trustedPriceWad, 10 ** tokenDecimals), true);
    }

    /// @dev Clears the flag (and confirmation clock) for any token that was
    /// previously flagged but priced cleanly again this round -- a cheap
    /// in-memory comparison against `stillExcluded` (this round's fresh
    /// divergence results), not a second pass over every held token.
    /// `flaggedTokensList` is expected to stay empty/tiny in normal
    /// operation, so this loop is bounded by how many tokens are actually
    /// under an active divergence, not by heldTokensList's size.
    function _clearRecoveredDivergenceFlags(address[] memory stillExcluded) internal {
        uint256 len = flaggedTokensList.length;
        for (uint256 i = len; i > 0; i--) {
            address token = flaggedTokensList[i - 1];
            bool stillBad = false;
            for (uint256 j = 0; j < stillExcluded.length; j++) {
                if (stillExcluded[j] == token) {
                    stillBad = true;
                    break;
                }
            }
            if (!stillBad) {
                divergenceFlaggedSince[token] = 0;
                _isFlagged[token] = false;
                flaggedTokensList[i - 1] = flaggedTokensList[flaggedTokensList.length - 1];
                flaggedTokensList.pop();
                emit TokenDivergenceCleared(token);
            }
        }
    }

    function _feeTierFor(address user) internal view returns (uint16) {
        uint256 heldFor = block.timestamp - userFirstDepositAt[user];
        if (heldFor < 30 days) return FEE_TIER_0_30D;
        if (heldFor < 90 days) return FEE_TIER_30_90D;
        if (heldFor < 180 days) return FEE_TIER_90_180D;
        return FEE_TIER_180D_PLUS;
    }

    // ── Keeper execution — the ONLY thing KEEPER_ROLE can do (§3) ────────────

    function executeSwap(
        address router,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minOut,
        address[] calldata path,
        uint256 deadline
    ) external nonReentrant onlyRole(KEEPER_ROLE) returns (uint256 amountOut) {
        // High #4 fix, Richard's review 14 Sept 2026: a paused vault must
        // never mean "we can't even sell our way out of a stuck position" —
        // that directly contradicted §4's own promise. Only NEW exposure
        // (anything that isn't converting back to the stable asset) stays
        // blocked while paused; selling a problem token back to USDT stays
        // available, same principle as settleRedemptions() never blocking
        // on a pause.
        if (tradingPaused && tokenOut != address(asset)) revert TradingIsPaused();
        if (!(routerAllowed[router])) revert RouterNotAllowlisted();
        if (!(path.length >= 2 && path[0] == tokenIn && path[path.length - 1] == tokenOut)) revert BadPath();
        uint256 inValueUsd = _checkTradeBounds(tokenIn, tokenOut, amountIn, path);

        // Slippage floor: minOut must sit within maxSlippageBps of the
        // router's OWN live quote, taken in the same call — the keeper
        // cannot pass an artificially low minOut to itself.
        uint256[] memory quoted = IPancakeRouter(router).getAmountsOut(amountIn, path);
        uint256 quotedOut = quoted[quoted.length - 1];
        uint256 minAcceptable = (quotedOut * (10000 - maxSlippageBps)) / 10000;
        if (!(minOut >= minAcceptable)) revert MinOutBelowSlippageBound();

        // Production-hardening item 4 (23 Sept 2026), Richard's audit C2/S8:
        // the check above approves itself against the SAME router's own
        // quote -- for the bot's actual usage (router == primaryRouter, the
        // common case), the cross-check below never runs, and V2 had NO
        // independent floor at all. Same unconditional, value-based check
        // executeSwapV3 already had (V3 never had a router-quote to trust
        // in the first place) -- see _checkValueBasedSlippage's own doc.
        // Genuinely unconditional: runs regardless of which router.
        _checkValueBasedSlippage(inValueUsd, tokenOut, minOut);

        // Critical #3c fix: the check above approves itself when `router`'s
        // own pool is thin or attacker-controlled — this is the ZEC failure
        // again (that fill was -0.37% against its own quote, 55% below fair
        // value). Cross-check against primaryRouter's OWN independent quote
        // whenever it differs from `router` — real protection only when
        // they're genuinely different liquidity sources; when they're the
        // same (or only one router is ever allowlisted) this is the SAME
        // open "no oracle yet" limitation as totalAssets() itself (§2),
        // honestly flagged, not silently claimed solved. Kept alongside
        // item 4's new check above, not replaced by it -- this one
        // cross-references the ROUTER'S OWN live quote (catches a thin/
        // manipulated alternate pool right now); item 4's checks the
        // KEEPER-SUPPLIED FLOOR itself (catches an artificially low minOut
        // regardless of router). Different inputs, different failure
        // modes, genuinely complementary.
        if (router != primaryRouter) {
            (uint256 outValueUsd, bool outOk) = _valueOutputAmount(tokenOut, quotedOut);
            if (!(outOk)) revert CannotIndependentlyValueTokenOut();
            // Generous cushion beyond the trade's own slippage tolerance,
            // since different routers/pools legitimately quote somewhat
            // different prices — this is a sanity check against gross
            // divergence, not a tight arbitrage bound.
            uint256 minAcceptableUsd = (inValueUsd * (10000 - maxSlippageBps - 1000)) / 10000;
            if (!(outValueUsd >= minAcceptableUsd)) revert PrimaryRouterQuoteDiverges();
        }

        _recordTrade(tokenOut);

        // Exact-amount approval only — same principle as the 9 Sept TS-side
        // fix (src/execution/smartRouter.ts's ensureAllowance): nothing left
        // standing after the trade for a compromised router to reach.
        IERC20(tokenIn).forceApprove(router, amountIn);

        uint256 balBefore = IERC20(tokenOut).balanceOf(address(this));
        // Low-severity fix, Richard's review 14 Sept 2026: this used to
        // compute `block.timestamp + 300` on-chain, evaluated in the exact
        // same block the swap executes — it can NEVER be exceeded, making
        // the deadline protection a complete no-op regardless of how long
        // the transaction actually sat in the mempool. Now takes a real
        // deadline from the caller, who knows when they actually submitted it.
        IPancakeRouter(router).swapExactTokensForTokens(amountIn, minOut, path, address(this), deadline);
        uint256 balAfter = IERC20(tokenOut).balanceOf(address(this));
        amountOut = balAfter - balBefore;

        emit SwapExecuted(msg.sender, router, tokenIn, tokenOut, amountIn, amountOut);
    }

    /// @notice PancakeSwap V3 execution (21 Sept 2026). Same bounds as
    /// executeSwap() -- pause, router allowlist, every hop allowlisted, size
    /// cap in both directions, pending-deposit cash untouchable, daily trade
    /// limit -- via the same shared helpers, so the two paths can't drift.
    ///
    /// The slippage floor is deliberately NOT the V2 shape. V3 has no view
    /// quote function (QuoterV2 simulates by reverting), and a quote from
    /// the pool being traded is the circular check Critical #3c flagged.
    /// Instead minOut is valued independently via _quoteTokenValueEx() --
    /// PriceOracle's trusted price when the token is onboarded, else its
    /// configured spot source -- and must be worth at least
    /// (1 - maxSlippageBps) of the input's value. LP fees count against
    /// that same budget. Honest limit: for a token with no oracle coverage
    /// whose spot source IS the pool being traded, this reduces to "minOut
    /// can't be set far below that pool's current mid price" -- still
    /// stops a keeper passing minOut = 0, but not a pool already pushed
    /// before the trade. Oracle onboarding is what closes that.
    ///
    /// @param path V3-encoded path: tokenIn | fee | token | ... | tokenOut.
    function executeSwapV3(address router, bytes calldata path, uint256 amountIn, uint256 minOut, uint256 deadline)
        external
        nonReentrant
        onlyRole(KEEPER_ROLE)
        returns (uint256 amountOut)
    {
        address[] memory hops = V3Path.tokens(path);
        address tokenIn = hops[0];
        address tokenOut = hops[hops.length - 1];

        if (tradingPaused && tokenOut != address(asset)) revert TradingIsPaused(); // High #4, same as executeSwap
        if (!(v3RouterAllowed[router])) revert V3RouterNotAllowlisted();
        uint256 inValueUsd = _checkTradeBounds(tokenIn, tokenOut, amountIn, hops);

        _checkValueBasedSlippage(inValueUsd, tokenOut, minOut);

        _recordTrade(tokenOut);

        amountOut = _executeV3SwapAndCheck(router, path, tokenIn, tokenOut, amountIn, minOut, deadline);
    }

    /// @dev Values `amount` of `tokenOut` in USD -- the vault's own asset
    /// 1:1, or independently via _quoteTokenValue otherwise. Shared by
    /// executeSwap's primaryRouter cross-check and
    /// _checkValueBasedSlippage (23 Sept 2026, production-hardening item 4).
    function _valueOutputAmount(address tokenOut, uint256 amount) internal view returns (uint256, bool) {
        if (tokenOut == address(asset)) return (amount, true);
        return _quoteTokenValueEx(tokenOut, amount, true);
    }

    /// @notice Production-hardening item 4 (23 Sept 2026), Richard's audit
    /// C2/S8 -- independent, value-based slippage floor: minOut must be
    /// worth at least (1 - maxSlippageBps) of the input's own USD value,
    /// valued via _quoteTokenValue (oracle-aware when tokenOut is
    /// onboarded), never the executing router's own quote. Originally
    /// V3-only (extracted here unchanged, verified by V3's existing
    /// tests) -- V3 never had a router view-quote to trust in the first
    /// place, so this was always its ONLY floor. Now also called
    /// unconditionally from executeSwap (V2), which previously only had
    /// this protection when router != primaryRouter (Critical #3c) --
    /// the common case (router == primaryRouter) had no independent floor
    /// at all until this.
    function _checkValueBasedSlippage(uint256 inValueUsd, address tokenOut, uint256 minOut) internal view {
        (uint256 minOutValueUsd, bool ok) = _valueOutputAmount(tokenOut, minOut);
        if (!(ok)) revert CannotValueTradeOutput();
        if (!(minOutValueUsd * 10000 >= inValueUsd * (10000 - maxSlippageBps))) revert MinOutBelowSlippageBound();
    }

    /// @dev Shared V3 execution tail for executeSwapV3 and
    /// adminEmergencyExitV3 (22 Sept 2026, contract-size pass) -- approves
    /// exactly amountIn, measures the REAL balance delta (never trusts the
    /// router's own return value -- a router that reports one number and
    /// delivers another can't slip past this), and enforces minOut against
    /// that measured amount. Every caller has already computed and checked
    /// its OWN slippage floor against minOut before calling this -- this
    /// function only executes and measures, it doesn't decide what minOut
    /// should be, so the two callers' genuinely different slippage
    /// semantics (maxSlippageBps vs emergencyExitMaxSlippageBps) are
    /// untouched by this extraction.
    function _executeV3SwapAndCheck(
        address router,
        bytes calldata path,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minOut,
        uint256 deadline
    ) internal returns (uint256 amountOut) {
        IERC20(tokenIn).forceApprove(router, amountIn); // exact amount, same as executeSwap
        uint256 balBefore = IERC20(tokenOut).balanceOf(address(this));
        IPancakeV3SwapRouter(router).exactInput(
            IPancakeV3SwapRouter.ExactInputParams({
                path: path,
                recipient: address(this),
                deadline: deadline,
                amountIn: amountIn,
                amountOutMinimum: minOut
            })
        );
        amountOut = IERC20(tokenOut).balanceOf(address(this)) - balBefore;
        if (!(amountOut >= minOut)) revert ReceivedLessThanMinOut();

        emit SwapExecuted(msg.sender, router, tokenIn, tokenOut, amountIn, amountOut);
    }

    /// @dev Bounds shared by executeSwap and executeSwapV3; returns the
    /// input's USD value for the caller's slippage check.
    function _checkTradeBounds(address tokenIn, address tokenOut, uint256 amountIn, address[] memory hops)
        internal
        view
        returns (uint256 inValueUsd)
    {
        if (!(tokenIn == address(asset) || tokenAllowed[tokenIn])) revert TokenInNotAllowlisted();
        if (!(tokenOut == address(asset) || tokenAllowed[tokenOut])) revert TokenOutNotAllowlisted();

        // Critical #3a fix: only the FIRST and LAST hop were ever
        // allowlisted — a keeper could route
        // USDT -> ATTACKER_TOKEN -> CAKE through a pool the attacker
        // created on an otherwise-allowed router. Every hop must clear the
        // allowlist now. Extracted to _checkHopsAllowlisted (22 Sept 2026,
        // contract-size pass) -- byte-for-byte the same loop, shared with
        // adminEmergencyExitV3, which needs the identical check.
        _checkHopsAllowlisted(hops);

        // Critical #3b fix: sells (tokenIn != asset) — including a direct
        // token-to-token swap that never touches the stable at all — had NO
        // size cap whatsoever; maxPositionUsd only ever applied on the BUY
        // side. Valuing amountIn in USD via the same live-quote mechanism
        // totalAssets() uses lets the SAME cap apply regardless of
        // direction — a compromised keeper can no longer push the vault's
        // entire holding of a token through one route.
        if (tokenIn == address(asset)) {
            inValueUsd = amountIn;
            // 11 Sept fix (§2b) — pending deposits' escrowed cash sits in
            // this same balance but doesn't belong to the vault's tradeable
            // capital yet (it hasn't bought shares). The keeper must never
            // be able to spend it before it settles.
            //
            // 22 Sept 2026 fix (production-hardening item 1) — same
            // principle extended to queued REDEMPTIONS: a request waiting
            // in the FIFO queue has locked its shares but the cash it's
            // owed was never carved out on-chain, only estimated bot-side.
            // _redemptionReserveUsd() closes that; see its own doc and
            // pendingRedemptionShares's doc for why it prices at the last
            // TRUSTED settlement rather than a live recompute.
            uint256 rawBalance = asset.balanceOf(address(this));
            uint256 reserved = pendingDepositTotal + _redemptionReserveUsd();
            uint256 tradeable = rawBalance > reserved ? rawBalance - reserved : 0;
            if (!(amountIn <= tradeable)) revert ExceedsTradeableCapital();
        } else {
            bool valuedOk;
            // Production-hardening item 5 (23 Sept 2026) -- was
            // _quoteTokenValue (the same tolerance-gated read a BUY uses),
            // which blocked selling OUT of a Degraded token exactly as hard
            // as it blocks buying INTO one. requireWithinTolerance=false
            // tolerates Degraded (still uses the oracle's trusted price,
            // never live spot) and only reverts for a genuinely Unpriceable
            // token -- see _quoteTokenValueEx's own doc for the full reasoning.
            (inValueUsd, valuedOk) = _quoteTokenValueEx(tokenIn, amountIn, false);
            if (!(valuedOk)) revert CannotValueTradeInput();
        }
        // Exits (token -> asset) get the separate, larger cap -- see
        // maxExitUsd. Buys and token-to-token swaps keep maxPositionUsd.
        // _checkExitCap extracted 22 Sept 2026 (contract-size pass) --
        // same shared reasoning as _checkHopsAllowlisted above.
        if (tokenIn != address(asset) && tokenOut == address(asset)) {
            _checkExitCap(inValueUsd);
        } else if (!(inValueUsd <= maxPositionUsd)) {
            revert ExceedsMaxPositionSize();
        }
    }

    /// @dev Shared by _checkTradeBounds and adminEmergencyExitV3 -- every
    /// hop in a path must clear the token allowlist (Critical #3a), not
    /// just the first and last. Identical loop, one copy of the bytecode
    /// instead of two (22 Sept 2026, contract-size pass).
    function _checkHopsAllowlisted(address[] memory hops) internal view {
        for (uint256 i = 0; i < hops.length; i++) {
            if (!(hops[i] == address(asset) || tokenAllowed[hops[i]])) revert PathHopNotAllowlisted();
        }
    }

    /// @dev Shared by _checkTradeBounds and adminEmergencyExitV3 -- the
    /// exit-cap check (max(maxExitUsd, maxPositionUsd)) is identical in
    /// both; adminEmergencyExitV3 always exits into `asset`, so it only
    /// ever needs this branch, never the maxPositionUsd one.
    function _checkExitCap(uint256 inValueUsd) internal view {
        uint256 exitCap = maxExitUsd > maxPositionUsd ? maxExitUsd : maxPositionUsd;
        if (!(inValueUsd <= exitCap)) revert ExceedsMaxExitSize();
    }

    /// @notice USD value of cash reserved for the redemption queue, in
    /// `asset` units — 22 Sept 2026, production-hardening item 1.
    /// @dev Deliberately prices `pendingRedemptionShares` at
    /// lastSettledNavPerShareWad (the same trusted, stored reference
    /// forceSettleStale's own manipulation guard uses) rather than a live
    /// totalAssets() recompute: a live read would add a full loop over
    /// every held token's price source to EVERY buy (today does none at
    /// all), both a real gas cost on the hot path and a new DoS surface —
    /// one broken/malicious token in heldTokensList could then block every
    /// buy, not just trades involving that token. The cost of the trusted
    /// price being a little stale is a delay, never a loss: this reserve
    /// only gates new BUYs, it is never the number a redemption actually
    /// gets paid — settleRedemptions/_trySettleOne always compute the real
    /// payout from live NAV, same as before this change. Returns 0 before
    /// any settlement has ever recorded a trusted price (bootstrap; a
    /// redemption can't meaningfully exist before a deposit has settled).
    function _redemptionReserveUsd() internal view returns (uint256) {
        if (pendingRedemptionShares == 0 || lastSettledNavPerShareWad == 0) return 0;
        return (pendingRedemptionShares * lastSettledNavPerShareWad) / 1e18;
    }

    /// @notice Public view of the same figure _checkTradeBounds enforces on
    /// every BUY — lets the bot/dashboard read the contract's own number
    /// instead of maintaining a separate off-chain estimate of it.
    function redemptionReserveUsd() external view returns (uint256) {
        return _redemptionReserveUsd();
    }

    /// @dev Daily trade counter + held-token tracking, shared by both swap paths.
    function _recordTrade(address tokenOut) internal {
        uint256 today = block.timestamp / 1 days;
        if (today != tradeDay) {
            tradeDay = today;
            tradesExecutedToday = 0;
        }
        if (!(tradesExecutedToday < maxDailyTrades)) revert DailyTradeLimitReached();
        tradesExecutedToday++;

        if (tokenOut != address(asset) && !_isHeldToken[tokenOut]) {
            _isHeldToken[tokenOut] = true;
            heldTokensList.push(tokenOut);
        }
    }

    // ── Valuation (§2) ───────────────────────────────────────────────────────

    function totalAssets() public view returns (uint256 total) {
        (total, , ) = _totalAssetsWithHealth();
    }

    /// @notice 11 Sept 2026 — resolves the 3-way contradiction Richard's
    /// review flagged between the spec's §4b ("last confirmed-good NAV"),
    /// §5 ("router unavailable → no redemption settles"), and the 9 Sept
    /// status report ("settlement-time NAV"). Ground truth, reading the
    /// code as it actually was: totalAssets() has NEVER cached anything —
    /// every call was always a live, current-block quote. §4b's "last
    /// confirmed-good" framing never matched this contract; that was the
    /// spec doc's wording to fix, not the code's behavior (see
    /// docs/VAULT_ARCHITECTURE_SPEC.md's own correction).
    ///
    /// But §5's promise ("router unavailable → no redemption settles") was
    /// NOT actually true before this fix either: a failed quote on one held
    /// token just zeroed that token's contribution and let totalAssets()
    /// return a silently-understated number — settlement could still
    /// proceed against that wrong total, short-changing whoever happened to
    /// redeem during the outage.
    ///
    /// 18 Sept 2026, vault roadmap item 3 — SUPERSEDES the paragraph above.
    /// `_trySettleOne`/`forceSettleStale` no longer read `healthy` to
    /// refuse settlement outright; PriceOracle's divergence check (17-18
    /// Sept) makes a single token degrading to unpriceable the EXPECTED
    /// outcome of live spot merely disagreeing with a trusted price, not
    /// just a genuine outage, and blocking every depositor's redemption
    /// over one token's temporary divergence is both a worse failure mode
    /// and its own manipulation vector (push one thin token out of
    /// tolerance, freeze every unrelated exit). `total` already excludes
    /// an unpriceable token's value (contributes exactly 0, same as
    /// before) — that conservative understatement IS the safety net now:
    /// settlement proceeds against the priceable remainder, never an
    /// inflated number, and the excluded position stays held, reachable
    /// later once priced again or via adminForceRemoveHeldToken.
    /// `healthy` is kept in the return signature purely as an
    /// observability signal (true only when every held token priced
    /// cleanly this read) — nothing in this contract still gates on it.
    /// `excludedTokens` lists which held tokens contributed 0 this read --
    /// threaded through so settlement can emit TokenExcludedFromSettlement
    /// without a second, duplicate pricing pass (see _trySettleOne).
    function _totalAssetsWithHealth()
        internal
        view
        returns (uint256 total, bool healthy, address[] memory excludedTokens)
    {
        total = asset.balanceOf(address(this));
        healthy = true;
        uint256 len = heldTokensList.length;
        address[] memory excluded = new address[](len);
        uint256 excludedCount = 0;
        for (uint256 i = 0; i < len; i++) {
            address token = heldTokensList[i];
            uint256 bal = IERC20(token).balanceOf(address(this));
            if (bal == 0) continue;
            (uint256 value, bool ok) = _quoteTokenValueEx(token, bal, true);
            if (!ok) {
                healthy = false;
                excluded[excludedCount++] = token;
            }
            total += value;
        }
        excludedTokens = new address[](excludedCount);
        for (uint256 i = 0; i < excludedCount; i++) {
            excludedTokens[i] = excluded[i];
        }
    }

    /// @notice The NAV figure every per-share pricing calculation must
    /// actually use — totalAssets() minus every still-pending deposit's
    /// escrowed cash (pendingDepositTotal). That cash is real, vault-held
    /// USDT, but it doesn't back any minted share yet, so including it
    /// would let a pending deposit inflate the very price (redemption
    /// payouts, its own upcoming settlement, or a UI's convertToShares/
    /// Assets estimate) that existing shares are priced against.
    function _netAssetsWithHealth()
        internal
        view
        returns (uint256 net, bool healthy, address[] memory excludedTokens)
    {
        uint256 total;
        (total, healthy, excludedTokens) = _totalAssetsWithHealth();
        net = total > pendingDepositTotal ? total - pendingDepositTotal : 0;
    }

    /// @notice 18 Sept 2026 — closes the gap the drift-guard discussion
    /// surfaced: totalAssets() (and executeSwap()'s sizing check, which
    /// reuses this same function) used to trust primaryRouter's live spot
    /// quote directly, the exact single-pool-manipulation exposure
    /// PriceOracle was built to remove. Now: if PriceOracle is wired
    /// (§ priceOracle's doc) AND has actually onboarded this token
    /// (getTier() != None), value it off PriceOracle's trusted Chainlink/
    /// TWAP price instead — a single-transaction pool spike can no longer
    /// feed into NAV, the force-settle drift check (which reads
    /// totalAssets() through _netAssetsWithHealth()), OR a routine
    /// settlement's lastSettledNavPerShareWad, since none of those read
    /// the spot pool anymore for a covered token.
    ///
    /// A live spot quote is still fetched even on this path — not for its
    /// value, but as the "is the trusted price itself still believable
    /// right now" input to checkChainlinkDivergence/checkTwapDivergence.
    /// This catches a Chainlink feed that's gone stale-but-not-stale-
    /// enough-to-revert, or a TWAP pool that's been thinned out, the same
    /// way it catches active manipulation — PriceOracle decides tolerance,
    /// this function just supplies the live number and reacts to the
    /// verdict. Out of tolerance degrades to unpriceable (0, false), same
    /// conservative failure as an unreachable quote always was — never an
    /// inflated number, never a stale one.
    ///
    /// An unregistered token (getTier() == None, including every token
    /// while priceOracle == address(0)) falls back to the ORIGINAL spot-
    /// quote-only behavior untouched — this is not a new exposure, it's
    /// the same one every token had before this wiring existed, now
    /// narrowed to only the tokens that genuinely have no trusted price
    /// source yet rather than applying to all of them.
    /// @notice Production-hardening item 5 (23 Sept 2026) -- `requireWithinTolerance`
    /// added, and the once-separate SELL-side dispatcher folded back into
    /// this one function (first cut was a standalone _quoteExitValue,
    /// measured 39 bytes over budget -- same "two near-identical dispatchers"
    /// shape as _quoteAtTrustedPrice's own consolidation, so merged the same
    /// way rather than trimming a guarantee). `true` (via _quoteTokenValue
    /// below, every existing BUY/NAV call site, unchanged) keeps requiring
    /// Healthy. `false` (only from _checkTradeBounds's SELL branch) closes
    /// the gap the trust-status review surfaced: a Degraded token (oracle
    /// still has a trusted price, live spot just disagrees beyond tolerance)
    /// used to hit this exact same tolerance-gated read a BUY does, blocking
    /// an exit from a token that only needs watching, not trapping. Same
    /// trusted-price-regardless-of-tolerance read item 3's admin emergency
    /// exit already uses, just still reachable on the ordinary KEEPER_ROLE
    /// path since this doesn't touch the slippage floor at all (unlike item
    /// 3, which widens it). No confirmation window needed, unlike item 2's
    /// settlement-payout fix -- this never uses live spot as the value (only
    /// as the divergence check's OTHER input), so there is nothing here for
    /// a same-block manipulator to move; the number actually used
    /// (trustedPriceWad) is the Chainlink/TWAP anchor, not the thing an
    /// attacker can cheaply push same-block. An Unpriceable token (oracle
    /// can't produce ANY trusted price) still correctly reverts either way --
    /// that still needs adminEmergencyExitV3, unchanged.
    ///
    /// An unregistered token (getTier() == None, including every token
    /// while priceOracle == address(0)) falls back to the ORIGINAL spot-
    /// quote-only behavior untouched — this is not a new exposure, it's
    /// the same one every token had before this wiring existed, now
    /// narrowed to only the tokens that genuinely have no trusted price
    /// source yet rather than applying to all of them.
    function _quoteTokenValueEx(address token, uint256 amount, bool requireWithinTolerance)
        internal
        view
        returns (uint256, bool) {
        return ValuationLib.quoteEx(v3SpotSource[token].pool, v3SpotSource[token].quoteToken, primaryRouter, address(asset), address(priceOracle), token, amount, requireWithinTolerance);
    }

    /// @dev Mid price at the pool's current slot0 -- no price-impact haircut,
    /// same as the oracle path's trusted-price x amount. Every failure
    /// (pool unreadable, empty, quote token unpriceable) is (0, false),
    /// the same conservative failure as a V2 quote that reverts.
    ///
    /// Results are in `asset` units on the contract-wide assumption that
    /// asset is an 18-decimal, $1 stablecoin (same as the oracle path): a
    /// non-asset quote token is converted through its Chainlink USD price.
    function _quoteTokenValueViaV3Spot(address token, uint256 amount) internal view returns (uint256, bool) {
        // Security-audit fix (29 Sept 2026): the truncation-to-zero guard for
        // this path now lives in ValuationLib._viaV3Spot, alongside the rest
        // of this function's former body -- see that library's own doc.
        return ValuationLib.quoteViaSpot(v3SpotSource[token].pool, v3SpotSource[token].quoteToken, primaryRouter, address(asset), address(priceOracle), token, amount); // pool is set, so this is the V3 read
    }

    /// @dev Shared by _quoteTokenValueViaOracle and _trustedPriceValueForExit
    /// (22 Sept 2026, contract-size pass) -- both need the exact same two
    /// external reads (a live spot quote as the divergence check's other
    /// input, then PriceOracle's own trusted Chainlink/TWAP price), and
    /// only differ in whether they gate on `withinTolerance` afterward.
    /// `ok=false` means the live quote itself, or the oracle call, couldn't
    /// be completed at all (deployment-integrity gap or genuine outage) --
    /// distinct from `withinTolerance=false`, which means both calls
    /// succeeded but disagree.
    function _fetchTrustedPrice(address token, IPriceOracleView.Tier tier)
        internal
        view
        returns (bool withinTolerance, uint256 trustedPriceWad, bool ok) {
        return ValuationLib.fetchTrustedPrice(v3SpotSource[token].pool, v3SpotSource[token].quoteToken, primaryRouter, address(asset), address(priceOracle), token, tier);
    }

    /// @dev Shared valuation core for both the tolerance-gated read
    /// (`requireWithinTolerance = true`, used for NAV/BUY-side pricing,
    /// where a Degraded token must still be treated as unpriceable) and the
    /// exit-only read (`requireWithinTolerance = false`, item 3's emergency
    /// exit and item 5's ordinary-SELL fix below, where the trusted
    /// Chainlink/TWAP price is used regardless of live-spot tolerance --
    /// same underlying insight item 2 uses: the oracle calls return
    /// trustedPriceWad even when withinTolerance is false). Consolidated
    /// 23 Sept 2026 (production-hardening item 5, contract-size pass) from
    /// two near-identical functions (_quoteTokenValueViaOracle /
    /// _trustedPriceValueForExit) that differed only in this one gate.
    /// Caller must already have confirmed `tier != None`.
    function _quoteAtTrustedPrice(address token, uint256 amount, IPriceOracleView.Tier tier, bool requireWithinTolerance)
        internal
        view
        returns (uint256, bool) {
        return ValuationLib.quoteAtTrustedPrice(v3SpotSource[token].pool, v3SpotSource[token].quoteToken, primaryRouter, address(asset), address(priceOracle), token, amount, tier, requireWithinTolerance);
    }

    /// @notice adminEmergencyExitV3's own price read (30 Sept 2026, F1-F3
    /// fix S1) -- the lower of Chainlink/TWAP, not the single trusted tier
    /// _quoteAtTrustedPrice reads. See PriceOracle.getDistressPriceWad.
    function _quoteAtDistressPrice(address token, uint256 amount) internal view returns (uint256, bool) {
        return ValuationLib.quoteAtDistressPrice(address(priceOracle), token, amount);
    }

    /// @notice Low-severity naming note, Richard's review 14 Sept 2026:
    /// convertToShares/convertToAssets/pricePerShare borrow their names
    /// from the ERC-4626 standard, but this contract does NOT implement
    /// ERC-4626 (no synchronous deposit()/mint()/withdraw()/redeem(),
    /// which the standard requires — deposits and redemptions here are
    /// both async, request-then-settle) and doesn't declare/support the
    /// interface. An integrator assuming ERC-4626 compatibility from the
    /// function names alone would be wrong. Kept as plain estimate/display
    /// helpers, not a compliance claim.
    ///
    /// Estimate only — a real deposit prices at SETTLEMENT time
    /// (see requestDeposit()/settleDeposits()), which may differ from what
    /// this returns right now. Nets out pendingDepositTotal so the estimate
    /// matches what settlement will actually compute.
    function convertToShares(uint256 assets) public view returns (uint256) {
        uint256 supply = totalSupply();
        (uint256 netAssets, , ) = _netAssetsWithHealth();
        return supply == 0 || netAssets == 0 ? assets : (assets * supply) / netAssets;
    }

    function convertToAssets(uint256 shares) public view returns (uint256) {
        uint256 supply = totalSupply();
        (uint256 netAssets, , ) = _netAssetsWithHealth();
        return supply == 0 ? shares : (shares * netAssets) / supply;
    }

    function pricePerShare() external view returns (uint256) {
        return convertToAssets(1 ether);
    }

    function pendingRedemptionCount() external view returns (uint256) {
        return redemptionQueue.length - redemptionQueueHead;
    }

    function pendingDepositCount() external view returns (uint256) {
        return depositQueue.length - depositQueueHead;
    }

    // ── Admin (DEFAULT_ADMIN_ROLE = the treasury/governance multisig) ────────

    /// @notice Emergency-only: forcibly removes a token from
    /// heldTokensList even with a nonzero balance still held. High #4 fix,
    /// Richard's review 14 Sept 2026: totalAssets() loops every held token
    /// with an external call — if even ONE becomes permanently unquotable
    /// (no direct pair, delisted, a rug), `healthy` never returns true
    /// again, and EVERY deposit and redemption settlement stops, forever,
    /// with no recovery path (forceSettleStale fails the same way, since it
    /// also requires health). This is the escape hatch.
    ///
    /// The removed token's real value isn't magically zero — this is a
    /// deliberate, visible, on-chain-logged admin action, not a silent NAV
    /// manipulation, reserved for the specific emergency where a token
    /// genuinely can't be priced or sold through any allowlisted router.
    /// Existing holders absorb the loss of that position's value the
    /// moment it's removed — the same direction totalAssets() already
    /// fails safe toward (understating, never inflating) — which is the
    /// correct tradeoff against "nobody can ever withdraw again."
    function adminForceRemoveHeldToken(address token) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (!(_isHeldToken[token])) revert NotAHeldToken();
        _isHeldToken[token] = false;
        uint256 len = heldTokensList.length;
        for (uint256 i = 0; i < len; i++) {
            if (heldTokensList[i] == token) {
                heldTokensList[i] = heldTokensList[len - 1];
                heldTokensList.pop();
                break;
            }
        }
        emit HeldTokenForceRemoved(token);
    }

    /// @notice Production-hardening item 3 (22 Sept 2026) -- the ACTUAL
    /// value-recovering counterpart to adminForceRemoveHeldToken above.
    /// That function is a pure accounting write-off: it never moves a
    /// single token, so the position stays physically stuck in the vault
    /// forever, unreachable. This function actually SELLS it through an
    /// allowlisted V3 router, for the specific case _checkTradeBounds's
    /// normal path can no longer handle: a token whose live spot has
    /// diverged from its PriceOracle-trusted price (or was previously
    /// excluded/written off), even though a real, independent price still
    /// exists for it.
    ///
    /// Admin-only, not keeper -- same trust bar as adminForceRemoveHeldToken,
    /// deliberately NOT PAUSER_ROLE (which includes the keeper wallet): the
    /// wider emergencyExitMaxSlippageBps tolerance below is real economic
    /// room to move, and a compromised keeper key must not be able to
    /// trigger a capital-moving trade at 6.6x the normal slippage bound.
    /// This is not the panic button -- PAUSER_ROLE's instant pause already
    /// covers "stop new exposure right now." This is the slower, scrutinized
    /// "now get this specific position out" lever, and slow-but-scrutinized
    /// is correct for something that actually moves capital.
    ///
    /// Requires oracle coverage (getTier() != None) -- there is no
    /// independent, on-chain-verifiable price for a token PriceOracle has
    /// never priced at all, so this path refuses it rather than trusting
    /// an admin-supplied minOut with no on-chain floor whatsoever.
    /// adminForceRemoveHeldToken remains the only lever for that case --
    /// a real, flagged residual gap, not silently dropped.
    ///
    /// V3-only in this version: if a held token's only real liquidity is a
    /// V2-only pool with no V3 pair, this function can't reach it and the
    /// position stays stuck until a V2 twin is added -- an accepted, known
    /// limitation (contract-size headroom was the deciding constraint), not
    /// a silent gap.
    ///
    /// Bounded the same two ways a normal exit is: the existing
    /// max(maxExitUsd, maxPositionUsd) size cap (supports splitting a
    /// larger position across multiple calls, same chunking spirit as the
    /// bot's own split-exit planner) and _recordTrade's daily-trade limit.
    /// Not gated on tradingPaused -- same High #4 exemption every other
    /// asset-bound exit already gets; this function can only ever produce
    /// `asset` as output.
    function adminEmergencyExitV3(address router, bytes calldata path, uint256 amountIn, uint256 minOut, uint256 deadline)
        external
        nonReentrant
        returns (uint256 amountOut)
    {
        // Fast lane (exit-lane "Option A", docs/DECISION_C_FAST_EXIT_DESIGN_2026-10-02.md):
        // the Safe, holding GUARDIAN_ROLE, can act without waiting out the 48h
        // timelock; DEFAULT_ADMIN_ROLE (the timelock) keeps full access too.
        // Anyone else reverts with the same AccessControlUnauthorizedAccount(
        // caller, DEFAULT_ADMIN_ROLE) the old modifier produced. The floor /
        // distress-price logic below is unchanged -- only who may call changed.
        if (!hasRole(GUARDIAN_ROLE, msg.sender)) _checkRole(DEFAULT_ADMIN_ROLE);
        address[] memory hops = V3Path.tokens(path);
        address tokenIn = hops[0];
        if (!(hops[hops.length - 1] == address(asset))) revert BadPath();
        if (!(v3RouterAllowed[router])) revert V3RouterNotAllowlisted();
        // hops[0] == tokenIn, so _checkHopsAllowlisted already covers the
        // tokenIn-not-allowlisted case (as PathHopNotAllowlisted, not a
        // separate TokenInNotAllowlisted) -- no existing test binds this
        // brand-new function to a specific error here, unlike
        // _checkTradeBounds, so no need for the redundant standalone check.
        _checkHopsAllowlisted(hops);

        if (address(priceOracle) == address(0)) revert TokenNotOracleCovered();
        IPriceOracleView.Tier tier = priceOracle.getTier(tokenIn);
        if (tier == IPriceOracleView.Tier.None) revert TokenNotOracleCovered();

        // F1-F3 fix S1 (30 Sept 2026, decision 11): priced off the DISTRESS
        // price (lower of Chainlink/TWAP), not the single trusted tier --
        // that single tier is exactly what F1/F2/F3 found could be wrong or
        // stale precisely when this function is needed. See
        // PriceOracle.getDistressPriceWad's own doc for the full reasoning
        // and its known, accepted residual (a token given only one source
        // keeps today's behavior; both sources down still reverts here).
        (uint256 inValueUsd, bool inOk) = _quoteAtDistressPrice(tokenIn, amountIn);
        if (!(inOk)) revert CannotValueTradeInput();
        _checkExitCap(inValueUsd);

        // The floor is recomputed here, at execution time, from the CURRENT
        // distress price -- not carried in from calldata -- so a 48h-old
        // timelocked call can't execute against a stale floor. minOut is
        // raised to meet it rather than reverting outright: a caller-supplied
        // minOut below the floor no longer kills the call, it just stops
        // being the binding constraint. If the pool genuinely cannot pay the
        // floor, the swap itself still reverts (the router's own slippage
        // check) -- the guarantee doesn't weaken, it just moves from this
        // function's own revert to the AMM's.
        uint256 floorUsd = (inValueUsd * (10000 - emergencyExitMaxSlippageBps)) / 10000;
        if (minOut < floorUsd) minOut = floorUsd;

        _recordTrade(address(asset));

        // 22 Sept 2026, contract-size pass: the dedicated EmergencyExitExecuted
        // event was dropped to reclaim bytecode -- an observability loss, not
        // a guarantee loss. SwapExecuted (emitted by _executeV3SwapAndCheck)
        // still carries the full fill; distinguishing an emergency exit from
        // a normal keeper trade off-chain now means checking msg.sender's
        // role (DEFAULT_ADMIN_ROLE, never KEEPER_ROLE, ever calls this path)
        // against the same event, not a separate signal.
        amountOut = _executeV3SwapAndCheck(router, path, tokenIn, address(asset), amountIn, minOut, deadline);
    }

    /// @notice Admin-tunable slippage floor for adminEmergencyExitV3() --
    /// see its own doc for why this is deliberately wider than
    /// maxSlippageBps. Ceiling matches PriceOracle.setDeviationBps's own
    /// 50% convention.
    function setEmergencyExitMaxSlippageBps(uint16 bps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (!(bps > 0 && bps <= 5000)) revert DeviationBpsOutOfRange();
        emergencyExitMaxSlippageBps = bps;
        emit EmergencyExitMaxSlippageBpsSet(bps);
    }

    function setTokenAllowed(address token, bool allowed) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (!(token != address(0))) revert ZeroAddress();
        tokenAllowed[token] = allowed;
        emit TokenAllowedSet(token, allowed);
    }

    function setRouterAllowed(address router, bool allowed) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (!(router != address(0))) revert ZeroAddress();
        routerAllowed[router] = allowed;
        emit RouterAllowedSet(router, allowed);
    }

    function setPrimaryRouter(address router) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (!(router != address(0))) revert ZeroAddress();
        primaryRouter = router;
        emit PrimaryRouterSet(router);
    }

    /// @notice Raise, lower, or remove (type(uint256).max) the deposit cap.
    /// Lowering it below current totalAssets() just stops new requests;
    /// nothing already in the vault or the queue is affected.
    function setDepositCap(uint256 cap) external onlyRole(DEFAULT_ADMIN_ROLE) {
        depositCap = cap;
        emit DepositCapSet(cap);
    }

    /// @notice Per-trade cap on exits into the vault asset. 0 = same as
    /// maxPositionUsd; a value below maxPositionUsd has no effect (see
    /// maxExitUsd).
    function setMaxExitUsd(uint256 cap) external onlyRole(DEFAULT_ADMIN_ROLE) {
        maxExitUsd = cap;
        emit MaxExitUsdSet(cap);
    }

    /// @notice Turn the depositor allowlist on or off. Membership itself is
    /// grantRole/revokeRole(DEPOSITOR_ROLE, ...). Off = anyone may deposit.
    function setDepositAllowlistEnabled(bool enabled) external onlyRole(DEFAULT_ADMIN_ROLE) {
        depositAllowlistEnabled = enabled;
        emit DepositAllowlistEnabledSet(enabled);
    }

    function setV3RouterAllowed(address router, bool allowed) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (!(router != address(0))) revert ZeroAddress();
        v3RouterAllowed[router] = allowed;
        emit V3RouterAllowedSet(router, allowed);
    }

    /// @notice Points `token`'s live spot price at a PancakeSwap V3 pool, or
    /// clears it (pool = address(0)) back to the V2 primaryRouter quote.
    /// The pool must pair `token` with either `asset` or a token PriceOracle
    /// has a Chainlink feed for (e.g. WBNB, priced via BNB/USD). The pool is
    /// admin-chosen and trusted as such -- behind the 48h timelock, like
    /// every other allowlist change. Self-tests before returning, same
    /// principle as PriceOracle.setTwapSource: a pool that can't price the
    /// token right now reverts here, not at the first NAV read.
    function setV3SpotPool(address token, address pool) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (!(token != address(0))) revert ZeroAddress();
        if (pool == address(0)) {
            delete v3SpotSource[token];
            emit V3SpotPoolSet(token, address(0), address(0));
            return;
        }

        address t0 = IPancakeV3PoolState(pool).token0();
        address t1 = IPancakeV3PoolState(pool).token1();
        if (!(t0 == token || t1 == token)) revert PoolDoesNotContainToken();
        address quoteToken = t0 == token ? t1 : t0;
        if (!(quoteToken == address(asset) || (address(priceOracle) != address(0) && priceOracle.getTier(quoteToken) == IPriceOracleView.Tier.Chainlink))) revert QuoteTokenNotPriceable();

        v3SpotSource[token] = V3SpotSource({pool: pool, quoteToken: quoteToken});
        (, bool ok) = _quoteTokenValueViaV3Spot(token, 10 ** IERC20DecimalsMinimal(token).decimals());
        if (!(ok)) revert V3SpotPoolCannotPrice();

        emit V3SpotPoolSet(token, pool, quoteToken);
    }

    /// @notice Wires (or unwires, via address(0)) the PriceOracle used by
    /// _quoteTokenValueEx(). address(0) is a deliberate, valid state -- it's
    /// how the vault runs before the oracle is deployed/onboarded, and a
    /// safe rollback if the oracle ever needs to be pulled out of the loop
    /// in an emergency, without touching anything else.
    function setPriceOracle(address oracle) external onlyRole(DEFAULT_ADMIN_ROLE) {
        priceOracle = IPriceOracleView(oracle);
        emit PriceOracleSet(oracle);
    }

    function setRiskParams(uint256 _maxPositionUsd, uint16 _maxSlippageBps, uint16 _maxDailyTrades)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (!(_maxSlippageBps <= 2000)) revert SlippageCapTooLoose(); // sanity ceiling, 20%
        maxPositionUsd = _maxPositionUsd;
        maxSlippageBps = _maxSlippageBps;
        maxDailyTrades = _maxDailyTrades;
        emit RiskParamsSet(_maxPositionUsd, _maxSlippageBps, _maxDailyTrades);
    }

    function setTreasury(address _treasury) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (!(_treasury != address(0))) revert ZeroAddress();
        treasury = _treasury;
        emit TreasurySet(_treasury);
    }

    function pauseTrading() external onlyRole(PAUSER_ROLE) {
        tradingPaused = true;
        emit TradingPaused(msg.sender);
    }

    function unpauseTrading() external onlyRole(DEFAULT_ADMIN_ROLE) {
        tradingPaused = false;
        emit TradingUnpaused(msg.sender);
    }

    /// @notice Decision 6 (30 Sept 2026): lets the Safe instantly strip a
    /// compromised keeper key's power, without waiting on the 48h timelock
    /// that `revokeRole(KEEPER_ROLE, ...)` would otherwise require post-
    /// handover (DEFAULT_ADMIN_ROLE-gated, same as every other role here).
    /// @dev Hardcoded to KEEPER_ROLE only -- unlike AccessControl's own
    /// generic `revokeRole`, this cannot touch PAUSER_ROLE, DEFAULT_ADMIN_ROLE,
    /// GUARDIAN_ROLE itself, or any other role, no matter what the Safe is
    /// tricked or compelled into calling it with. `_revokeRole` is a no-op,
    /// not a revert, if `account` never held KEEPER_ROLE -- same convention
    /// AccessControl's own `revokeRole` already follows, so the Safe can
    /// call this defensively on an uncertain address during an incident
    /// without needing to confirm the role is actually held first. Not
    /// gated on tradingPaused -- stripping a key's power is exactly the
    /// kind of action that must work regardless of pause state.
    function emergencyRevokeKeeper(address account) external onlyRole(GUARDIAN_ROLE) {
        _revokeRole(KEEPER_ROLE, account);
        emit KeeperEmergencyRevoked(account, msg.sender);
    }

    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}
