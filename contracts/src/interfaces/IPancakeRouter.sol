// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @notice Minimal PancakeSwap V2 router interface — only what the vault needs.
/// Matches the same router the off-chain bot already trades through
/// (src/execution/smartRouter.ts's V2_ROUTER_MAINNET).
interface IPancakeRouter {
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    function getAmountsOut(
        uint256 amountIn,
        address[] calldata path
    ) external view returns (uint256[] memory amounts);
}
