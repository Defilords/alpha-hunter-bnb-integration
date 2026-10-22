// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IPancakeRouter} from "../interfaces/IPancakeRouter.sol";
import {IPancakeV3PoolState} from "../interfaces/IPancakeV3PoolState.sol";
import {IPriceOracleView} from "../interfaces/IPriceOracleView.sol";
import {IERC20DecimalsMinimal} from "../interfaces/IERC20DecimalsMinimal.sol";
import {V3SpotPrice} from "./V3SpotPrice.sol";

/// @notice The vault's token-valuation reads, moved out of AlphaSelectVault
/// purely to free contract size (EIP-170). Called by delegatecall (external
/// library functions), so `address(this)` is the vault: the oracle and router
/// see the vault as the caller, exactly as before. The library holds no
/// funds, no storage and no permissions of its own.
///
/// It only COMPUTES `(value, ok)`. Every decision about what to do when a
/// price is unavailable (revert, exclude, grace period) stays in the vault.
/// Bodies are the vault's former internal functions, moved without change:
///   quoteViaSpot        <- _quoteTokenValueViaSpot / _quoteTokenValueViaV3Spot
///   fetchTrustedPrice   <- _fetchTrustedPrice
///   quoteAtTrustedPrice <- _quoteAtTrustedPrice
///   quoteEx             <- _quoteTokenValueEx
/// The vault passes what those functions used to read from its own storage:
/// the token's V3 spot source (`pool`, `quoteToken`), `router` (primaryRouter),
/// `asset` and `oracle` (priceOracle).
library ValuationLib {
    function quoteViaSpot(
        address pool,
        address quoteToken,
        address router,
        address asset,
        address oracle,
        address token,
        uint256 amount
    ) external view returns (uint256, bool) {
        return _viaSpot(pool, quoteToken, router, asset, oracle, token, amount);
    }

    function fetchTrustedPrice(
        address pool,
        address quoteToken,
        address router,
        address asset,
        address oracle,
        address token,
        IPriceOracleView.Tier tier
    ) external view returns (bool withinTolerance, uint256 trustedPriceWad, bool ok) {
        return _fetchTrusted(pool, quoteToken, router, asset, oracle, token, tier);
    }

    function quoteAtTrustedPrice(
        address pool,
        address quoteToken,
        address router,
        address asset,
        address oracle,
        address token,
        uint256 amount,
        IPriceOracleView.Tier tier,
        bool requireWithinTolerance
    ) external view returns (uint256, bool) {
        return _atTrusted(pool, quoteToken, router, asset, oracle, token, amount, tier, requireWithinTolerance);
    }

    /// @dev An unregistered token (getTier() == None, including every token
    /// while `oracle` is unset) falls back to the spot-only read.
    function quoteEx(
        address pool,
        address quoteToken,
        address router,
        address asset,
        address oracle,
        address token,
        uint256 amount,
        bool requireWithinTolerance
    ) external view returns (uint256, bool) {
        if (oracle != address(0)) {
            IPriceOracleView.Tier tier = IPriceOracleView(oracle).getTier(token);
            if (tier != IPriceOracleView.Tier.None) {
                return _atTrusted(pool, quoteToken, router, asset, oracle, token, amount, tier, requireWithinTolerance);
            }
        }
        return _viaSpot(pool, quoteToken, router, asset, oracle, token, amount);
    }

    /// @dev Used only by adminEmergencyExitV3's last-resort exit -- see
    /// PriceOracle.getDistressPriceWad's own doc for why this is a
    /// different read from quoteAtTrustedPrice, not a duplicate of it.
    function quoteAtDistressPrice(address oracle, address token, uint256 amount) external view returns (uint256, bool) {
        if (amount == 0) return (0, true);
        (uint256 priceWad, bool ok) = IPriceOracleView(oracle).getDistressPriceWad(token);
        if (!ok) return (0, false);
        uint8 tokenDecimals = IERC20DecimalsMinimal(token).decimals();
        return (Math.mulDiv(amount, priceWad, 10 ** tokenDecimals), true);
    }

    function _viaSpot(
        address pool,
        address quoteToken,
        address router,
        address asset,
        address oracle,
        address token,
        uint256 amount
    ) private view returns (uint256, bool) {
        if (pool != address(0)) return _viaV3Spot(pool, quoteToken, asset, oracle, token, amount);

        address[] memory path = new address[](2);
        path[0] = token;
        path[1] = asset;
        try IPancakeRouter(router).getAmountsOut(amount, path) returns (uint256[] memory amounts) {
            return (amounts[amounts.length - 1], true);
        } catch {
            // Spec §2: an unavailable price must never fall back to a
            // last-known number. Zero here plus healthy=false at the
            // totalAssets() level are the actual safety net.
            return (0, false);
        }
    }

    /// @dev Mid price at the pool's current slot0 -- no price-impact haircut,
    /// same as the oracle path's trusted-price x amount. Every failure is
    /// (0, false). Results are in `asset` units on the contract-wide
    /// assumption that asset is an 18-decimal, $1 stablecoin: a non-asset
    /// quote token is converted through its Chainlink USD price.
    function _viaV3Spot(address pool, address quoteToken, address asset, address oracle, address token, uint256 amount)
        private
        view
        returns (uint256, bool)
    {
        uint160 sqrtPriceX96;
        try IPancakeV3PoolState(pool).slot0() returns (uint160 p, int24, uint16, uint16, uint16, uint32, bool) {
            sqrtPriceX96 = p;
        } catch {
            return (0, false);
        }
        if (sqrtPriceX96 == 0) return (0, false);

        uint256 quoteAmount = V3SpotPrice.quote(sqrtPriceX96, amount, token, quoteToken);
        // Security-audit fix (29 Sept 2026): same truncation gap
        // PriceOracle._quoteAtTick already guards against (found by its own
        // fuzz/invariant suite, contracts/test/PriceOracleInvariants.t.sol) --
        // a small `amount` against a large price ratio can floor this
        // division to exactly zero for a token that is NOT actually
        // worthless. Left unguarded, that read as a normal (0, true): the
        // position silently dropped out of totalAssets() with no
        // TokenExcludedFromSettlement event and `healthy` still true, unlike
        // every other valuation failure in this contract. Fail the same
        // conservative (0, false) way as an unreadable pool instead.
        if (amount != 0 && quoteAmount == 0) return (0, false);
        if (quoteToken == asset) return (quoteAmount, true);

        if (oracle == address(0)) return (0, false);
        try IPriceOracleView(oracle).getChainlinkPriceWad(quoteToken) returns (uint256 quoteUsdWad, uint256) {
            uint8 quoteDecimals = IERC20DecimalsMinimal(quoteToken).decimals();
            return (Math.mulDiv(quoteAmount, quoteUsdWad, 10 ** quoteDecimals), true);
        } catch {
            return (0, false); // stale/missing feed -- never guess the quote token's price
        }
    }

    /// @dev A live spot quote (the divergence check's other input), then the
    /// oracle's own trusted Chainlink/TWAP price. `ok=false` means the live
    /// quote or the oracle call could not be completed at all -- distinct
    /// from `withinTolerance=false`, where both succeeded but disagree.
    function _fetchTrusted(
        address pool,
        address quoteToken,
        address router,
        address asset,
        address oracle,
        address token,
        IPriceOracleView.Tier tier
    ) private view returns (bool withinTolerance, uint256 trustedPriceWad, bool ok) {
        uint8 tokenDecimals = IERC20DecimalsMinimal(token).decimals();
        (uint256 livePriceWad, bool liveOk) = _viaSpot(pool, quoteToken, router, asset, oracle, token, 10 ** tokenDecimals);
        if (!liveOk) return (false, 0, false);

        if (tier == IPriceOracleView.Tier.Chainlink) {
            try IPriceOracleView(oracle).checkChainlinkDivergence(token, livePriceWad) returns (bool wt, uint256 trusted) {
                return (wt, trusted, true);
            } catch {
                return (false, 0, false);
            }
        } else {
            try IPriceOracleView(oracle).checkTwapDivergence(token, livePriceWad) returns (bool wt, uint256 trusted) {
                return (wt, trusted, true);
            } catch {
                return (false, 0, false);
            }
        }
    }

    /// @dev `requireWithinTolerance = true` for NAV/BUY-side pricing (a
    /// Degraded token is unpriceable there); `false` for the exit-only
    /// reads (trusted price used regardless of live-spot tolerance).
    /// Caller must already have confirmed `tier != None`.
    function _atTrusted(
        address pool,
        address quoteToken,
        address router,
        address asset,
        address oracle,
        address token,
        uint256 amount,
        IPriceOracleView.Tier tier,
        bool requireWithinTolerance
    ) private view returns (uint256, bool) {
        if (amount == 0) return (0, true);
        (bool withinTolerance, uint256 trustedPriceWad, bool ok) =
            _fetchTrusted(pool, quoteToken, router, asset, oracle, token, tier);
        if (!ok || (requireWithinTolerance && !withinTolerance)) return (0, false);
        uint8 tokenDecimals = IERC20DecimalsMinimal(token).decimals();
        return (Math.mulDiv(amount, trustedPriceWad, 10 ** tokenDecimals), true);
    }
}
