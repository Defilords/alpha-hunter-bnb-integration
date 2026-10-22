// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @dev The slice of a PancakeSwap V3 pool the vault reads for spot valuation.
/// slot0's `feeProtocol` is uint32 on PancakeSwap (uint8 on Uniswap V3) -- a
/// live BSC pool returns 0x0d480d48 there, which a uint8 declaration would
/// fail to ABI-decode, reverting every read. Don't "fix" this back to the
/// Uniswap layout.
interface IPancakeV3PoolState {
    function token0() external view returns (address);
    function token1() external view returns (address);

    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint32 feeProtocol,
            bool unlocked
        );
}
