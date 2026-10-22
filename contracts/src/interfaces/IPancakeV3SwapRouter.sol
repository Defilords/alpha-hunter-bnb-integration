// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @dev PancakeSwap V3 SwapRouter (BSC: 0x1b81D678ffb9C0263b24A97847620C99d213eB14),
/// the same router the bot's smartRouter.ts executes through. Its ExactInputParams
/// carries `deadline` in the struct (the v3-periphery SwapRouter layout), unlike
/// PancakeSwap's SmartRouter/SwapRouter02, which drops it -- don't mix the two up.
interface IPancakeV3SwapRouter {
    struct ExactInputParams {
        bytes path; // tokenIn | fee(uint24) | token | fee | ... | tokenOut
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }

    function exactInput(ExactInputParams calldata params) external payable returns (uint256 amountOut);
}
