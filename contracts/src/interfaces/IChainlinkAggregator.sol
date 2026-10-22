// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/**
 * @dev Minimal slice of Chainlink's AggregatorV3Interface -- only the two
 *      functions PriceOracle actually needs. Deliberately not pulling in
 *      the full Chainlink contracts npm package for one interface, same
 *      pattern as IPancakeRouter.sol in this same directory.
 */
interface IChainlinkAggregator {
    function decimals() external view returns (uint8);

    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        );
}
