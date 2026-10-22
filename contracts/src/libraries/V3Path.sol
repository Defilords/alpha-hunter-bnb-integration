// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @dev Decodes a V3 multi-hop path (token | fee(uint24) | token | ... | token)
/// into its token list, so the vault can allowlist-check every hop the same
/// way executeSwap() checks a V2 path (Critical #3a).
library V3Path {
    error BadV3Path();

    uint256 private constant ADDR = 20;
    uint256 private constant HOP = 23; // fee (3) + next token (20)

    function tokens(bytes calldata path) internal pure returns (address[] memory out) {
        if (!(path.length >= ADDR + HOP && (path.length - ADDR) % HOP == 0)) revert BadV3Path();
        uint256 hops = (path.length - ADDR) / HOP;
        out = new address[](hops + 1);
        for (uint256 i = 0; i <= hops; i++) {
            uint256 at = i * HOP;
            out[i] = address(bytes20(path[at:at + ADDR]));
        }
    }
}
