// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @dev The subset of PriceOracle the vault actually calls, kept as a
///      separate interface so AlphaSelectVault only depends on the shape
///      it needs, not PriceOracle's full implementation. Tier's ordering
///      must match PriceOracle.Tier exactly (None, Chainlink, Twap) --
///      it's an ABI-level enum, not a shared type.
interface IPriceOracleView {
    enum Tier { None, Chainlink, Twap }

    function getTier(address token) external view returns (Tier);

    function checkChainlinkDivergence(address token, uint256 livePriceWad)
        external
        view
        returns (bool withinTolerance, uint256 trustedPriceWad);

    function checkTwapDivergence(address token, uint256 livePriceWad)
        external
        view
        returns (bool withinTolerance, uint256 trustedPriceWad);

    /// @dev Used to convert a V3 spot pool quoted in a non-stable token
    /// (e.g. token/WBNB) into USD -- see AlphaSelectVault.setV3SpotPool().
    function getChainlinkPriceWad(address token) external view returns (uint256 priceWad, uint256 updatedAt);

    /// @dev The lower of whatever independent sources (Chainlink and/or
    /// TWAP) are readable right now -- see PriceOracle.getDistressPriceWad's
    /// own doc. Used only by adminEmergencyExitV3.
    function getDistressPriceWad(address token) external view returns (uint256 priceWad, bool ok);
}
