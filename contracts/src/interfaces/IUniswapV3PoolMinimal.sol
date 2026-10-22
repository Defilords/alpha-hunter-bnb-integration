// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/**
 * @dev Minimal slice of the PancakeSwap V3 / Uniswap V3 pool ABI -- only
 *      what PriceOracle's TWAP path needs. Same shape as Uniswap's own
 *      IUniswapV3Pool (PancakeSwap V3 is a direct fork, identical ABI for
 *      these read functions), hand-written narrow rather than importing
 *      the full interface -- same pattern as IPancakeRouter.sol.
 */
interface IUniswapV3PoolMinimal {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function liquidity() external view returns (uint128);

    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s);
}
