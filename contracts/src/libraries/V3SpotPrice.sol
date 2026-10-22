// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @dev "How much quoteToken is `baseAmount` raw units of baseToken worth" at
/// a pool's current sqrtPriceX96 -- the same math as PriceOracle's
/// _quoteAtTick, starting from the price instead of a tick. Branches on the
/// price's size only to keep the squaring step from overflowing; mulDiv does
/// the overflow-safe multiplication either way.
library V3SpotPrice {
    function quote(uint160 sqrtPriceX96, uint256 baseAmount, address baseToken, address quoteToken)
        internal
        pure
        returns (uint256)
    {
        if (sqrtPriceX96 <= type(uint128).max) {
            uint256 ratioX192 = uint256(sqrtPriceX96) * sqrtPriceX96;
            return baseToken < quoteToken
                ? Math.mulDiv(ratioX192, baseAmount, 1 << 192)
                : Math.mulDiv(1 << 192, baseAmount, ratioX192);
        }
        uint256 ratioX128 = Math.mulDiv(sqrtPriceX96, sqrtPriceX96, 1 << 64);
        return baseToken < quoteToken
            ? Math.mulDiv(ratioX128, baseAmount, 1 << 128)
            : Math.mulDiv(1 << 128, baseAmount, ratioX128);
    }
}
