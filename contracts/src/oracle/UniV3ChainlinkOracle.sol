// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

interface IPriceOracle {
    /// @return usdcPerWeth Price of 1 WETH (1e18 wei) in USDC base units (6 decimals).
    /// @return updatedAt   Timestamp the price is valid for.
    function price() external view returns (uint256 usdcPerWeth, uint256 updatedAt);
}

interface IUniswapV3PoolOracle {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s);
}

interface IChainlinkFeed {
    function decimals() external view returns (uint8);
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

/// @title UniV3ChainlinkOracle
/// @notice WETH/USDC price from a Uniswap v3 TWAP, cross-checked against a Chainlink ETH/USD feed.
///         `price()` reverts if Chainlink is stale or the two sources disagree by more than `maxDeviationBps`.
/// @dev    Tick -> price uses 1.0001^tick = exp(tick * ln 1.0001) via Solady's expWad. With WETH (18 dp) as
///         token0 and USDC (6 dp) as token1, the raw pool price is USDC units per wei, so expWad's 1e18-scaled
///         result is exactly USDC base units per 1 WETH.
contract UniV3ChainlinkOracle is IPriceOracle {
    /// @dev ln(1.0001) scaled by 1e18.
    int256 internal constant LN_1_0001_WAD = 99_995_000_333_308;

    IUniswapV3PoolOracle public immutable pool;
    bool public immutable wethIsToken0;
    IChainlinkFeed public immutable feed;
    uint8 public immutable feedDecimals;
    uint32 public immutable twapWindow;
    uint256 public immutable maxStaleness;
    uint16 public immutable maxDeviationBps;

    error PoolTokenMismatch();
    error BadConfig();
    error BadFeedAnswer();
    error StaleFeed(uint256 updatedAt, uint256 maxStaleness);
    error PriceDeviation(uint256 uniswap, uint256 chainlink, uint256 deviationBps);

    constructor(
        IUniswapV3PoolOracle _pool,
        address weth,
        address usdc,
        IChainlinkFeed _feed,
        uint32 _twapWindow,
        uint256 _maxStaleness,
        uint16 _maxDeviationBps
    ) {
        if (_twapWindow == 0 || _maxStaleness == 0 || _maxDeviationBps == 0 || _maxDeviationBps > 10_000) revert BadConfig();
        address t0 = _pool.token0();
        address t1 = _pool.token1();
        if (t0 == weth && t1 == usdc) wethIsToken0 = true;
        else if (t0 == usdc && t1 == weth) wethIsToken0 = false;
        else revert PoolTokenMismatch();

        pool = _pool;
        feed = _feed;
        feedDecimals = _feed.decimals();
        twapWindow = _twapWindow;
        maxStaleness = _maxStaleness;
        maxDeviationBps = _maxDeviationBps;
    }

    /// @notice Arithmetic-mean tick over `twapWindow`, rounded toward negative infinity (as Uniswap's OracleLibrary).
    function twapTick() public view returns (int24 tick) {
        uint32[] memory ago = new uint32[](2);
        ago[0] = twapWindow;
        ago[1] = 0;
        (int56[] memory cum,) = pool.observe(ago);
        int56 delta = cum[1] - cum[0];
        int56 window = int56(uint56(twapWindow));
        tick = int24(delta / window);
        if (delta < 0 && (delta % window != 0)) tick--;
    }

    /// @notice Uniswap TWAP price of 1 WETH in USDC base units.
    function uniswapPrice() public view returns (uint256) {
        int256 x = int256(twapTick()) * LN_1_0001_WAD;
        uint256 raw = uint256(FixedPointMathLib.expWad(wethIsToken0 ? x : -x)); // USDC units per wei, 1e18-scaled
        return raw;
    }

    /// @notice Chainlink ETH/USD price in USDC base units (USD treated as USDC 1:1).
    function chainlinkPrice() public view returns (uint256 usdcPerWeth, uint256 updatedAt) {
        int256 answer;
        (, answer,, updatedAt,) = feed.latestRoundData();
        if (answer <= 0) revert BadFeedAnswer();
        uint256 a = uint256(answer);
        usdcPerWeth = feedDecimals >= 6 ? a / 10 ** (feedDecimals - 6) : a * 10 ** (6 - feedDecimals);
    }

    /// @inheritdoc IPriceOracle
    function price() external view returns (uint256 usdcPerWeth, uint256 updatedAt) {
        (uint256 cl, uint256 clUpdated) = chainlinkPrice();
        if (block.timestamp > clUpdated + maxStaleness) revert StaleFeed(clUpdated, maxStaleness);
        uint256 uni = uniswapPrice();
        uint256 diff = uni > cl ? uni - cl : cl - uni;
        uint256 devBps = (diff * 10_000) / cl;
        if (devBps > maxDeviationBps) revert PriceDeviation(uni, cl, devBps);
        return (uni, block.timestamp);
    }
}
