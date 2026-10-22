// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @dev Just decimals() -- PriceOracle needs each token's real on-chain
///      decimal count to interpret raw TWAP amounts correctly, separate
///      from (and not to be confused with) a Chainlink feed's own decimals.
interface IERC20DecimalsMinimal {
    function decimals() external view returns (uint8);
}
