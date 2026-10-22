// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @dev The subset of PriceOracle PositionManager calls. A separate local
/// interface rather than extending `IPriceOracleView` (the vault's own
/// interface) deliberately -- `IPriceOracleView` is a file the LIVE,
/// deployed AlphaSelectVault depends on; PositionManager gets its own
/// narrow view instead of adding `hasFeed` to a shared file the running
/// vault doesn't need touched for this work. Field/function shapes match
/// the real PriceOracle contract exactly, so this can point at the same
/// deployed oracle the vault uses.
interface IPositionOracle {
    enum Tier { None, Chainlink, Twap }

    function getTier(address token) external view returns (Tier);
    function hasFeed(address token) external view returns (bool);

    function getChainlinkPriceWad(address token) external view returns (uint256 priceWad, uint256 updatedAt);

    /// @dev Added 16 Oct 2026: PositionManager computes its own Chainlink-vs-TWAP divergence
    /// check locally now (twapToleranceBpsByToken), instead of delegating to the oracle's shared
    /// checkTwapDivergence/deviationBpsByToken -- that value is live mainnet storage shared with
    /// the vault's own divergence check (5% today), too tight for PositionManager's own trigger
    /// prices and not something PositionManager should be able to influence by raising it. Reading
    /// the raw TWAP price directly needs no special permission -- getTwapPriceWad is already a
    /// public view on the real PriceOracle.
    function getTwapPriceWad(address token) external view returns (uint256 priceWad);
}
