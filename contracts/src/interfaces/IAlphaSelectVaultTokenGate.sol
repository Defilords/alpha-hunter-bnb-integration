// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/**
 * @dev Just tokenAllowed() -- the one thing PriceOracle's isFullyOnboarded()
 *      needs to read from a vault. Deliberately not a stored reference:
 *      PriceOracle takes the vault's address as a call-time parameter, not
 *      a fixed field in its own storage, so one PriceOracle deployment can
 *      answer this for any vault that uses it, matching AlphaSelectVault's
 *      own "one deployment per strategy x risk, shared code" pattern --
 *      PriceOracle stays genuinely vault-agnostic, nothing to get out of
 *      sync with a specific deployment.
 */
interface IAlphaSelectVaultTokenGate {
    function tokenAllowed(address token) external view returns (bool);
}
