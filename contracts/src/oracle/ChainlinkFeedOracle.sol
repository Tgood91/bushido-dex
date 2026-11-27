// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPriceOracle, IChainlinkFeed} from "./UniV3ChainlinkOracle.sol";

/// @title ChainlinkFeedOracle
/// @notice Prices a test token from a live Chainlink <ASSET>/USD feed on the same chain, so testnet tokens
///         (tAVAX, tETH, ...) trade at the real market price. Testnet Chainlink feeds track mainnet markets.
///         Returns USDC base units (6 dp) per 1 whole token (1e18 units); reverts on a stale or bad answer.
contract ChainlinkFeedOracle is IPriceOracle {
    IChainlinkFeed public immutable feed;
    uint8 public immutable feedDecimals;
    uint256 public immutable maxStaleness;

    error BadConfig();
    error BadFeedAnswer();
    error StaleFeed(uint256 updatedAt, uint256 maxStaleness);

    constructor(IChainlinkFeed _feed, uint256 _maxStaleness) {
        if (address(_feed) == address(0) || _maxStaleness == 0) revert BadConfig();
        feed = _feed;
        feedDecimals = _feed.decimals();
        maxStaleness = _maxStaleness;
    }

    function description() external view returns (string memory) {
        (bool ok, bytes memory data) = address(feed).staticcall(abi.encodeWithSignature("description()"));
        return ok ? abi.decode(data, (string)) : "";
    }

    /// @inheritdoc IPriceOracle
    function price() external view returns (uint256 usdcPerToken, uint256 updatedAt) {
        int256 answer;
        (, answer,, updatedAt,) = feed.latestRoundData();
        if (answer <= 0) revert BadFeedAnswer();
        if (block.timestamp > updatedAt + maxStaleness) revert StaleFeed(updatedAt, maxStaleness);
        uint256 a = uint256(answer);
        usdcPerToken = feedDecimals >= 6 ? a / 10 ** (feedDecimals - 6) : a * 10 ** (6 - feedDecimals);
    }
}
