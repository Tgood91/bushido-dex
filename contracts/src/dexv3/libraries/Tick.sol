// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {TickMath} from "./TickMath.sol";
import {LiquidityMath} from "./LiquidityMath.sol";

/// @notice Port of Uniswap v3-core Tick (GPL-2.0-or-later) to Solidity 0.8, without oracle fields.
///         Fee-growth values are modular by design, so their arithmetic is unchecked.
library Tick {
    error LiquidityOverflow();

    struct Info {
        uint128 liquidityGross; // total position liquidity referencing this tick
        int128 liquidityNet; // liquidity added (removed) when the tick is crossed left to right
        uint256 feeGrowthOutside0X128; // fee growth on the other side of this tick from the current tick
        uint256 feeGrowthOutside1X128;
        bool initialized;
    }

    function tickSpacingToMaxLiquidityPerTick(int24 tickSpacing) internal pure returns (uint128) {
        int24 minTick = (TickMath.MIN_TICK / tickSpacing) * tickSpacing;
        int24 maxTick = (TickMath.MAX_TICK / tickSpacing) * tickSpacing;
        uint24 numTicks = uint24((maxTick - minTick) / tickSpacing) + 1;
        return type(uint128).max / numTicks;
    }

    function getFeeGrowthInside(
        mapping(int24 => Info) storage self,
        int24 tickLower,
        int24 tickUpper,
        int24 tickCurrent,
        uint256 feeGrowthGlobal0X128,
        uint256 feeGrowthGlobal1X128
    ) internal view returns (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128) {
        Info storage lower = self[tickLower];
        Info storage upper = self[tickUpper];
        unchecked {
            uint256 below0;
            uint256 below1;
            if (tickCurrent >= tickLower) {
                below0 = lower.feeGrowthOutside0X128;
                below1 = lower.feeGrowthOutside1X128;
            } else {
                below0 = feeGrowthGlobal0X128 - lower.feeGrowthOutside0X128;
                below1 = feeGrowthGlobal1X128 - lower.feeGrowthOutside1X128;
            }
            uint256 above0;
            uint256 above1;
            if (tickCurrent < tickUpper) {
                above0 = upper.feeGrowthOutside0X128;
                above1 = upper.feeGrowthOutside1X128;
            } else {
                above0 = feeGrowthGlobal0X128 - upper.feeGrowthOutside0X128;
                above1 = feeGrowthGlobal1X128 - upper.feeGrowthOutside1X128;
            }
            feeGrowthInside0X128 = feeGrowthGlobal0X128 - below0 - above0;
            feeGrowthInside1X128 = feeGrowthGlobal1X128 - below1 - above1;
        }
    }

    /// @return flipped Whether the tick went from uninitialized to initialized or vice versa.
    function update(
        mapping(int24 => Info) storage self,
        int24 tick,
        int24 tickCurrent,
        int128 liquidityDelta,
        uint256 feeGrowthGlobal0X128,
        uint256 feeGrowthGlobal1X128,
        bool upper,
        uint128 maxLiquidity
    ) internal returns (bool flipped) {
        Info storage info = self[tick];
        uint128 grossBefore = info.liquidityGross;
        uint128 grossAfter = LiquidityMath.addDelta(grossBefore, liquidityDelta);
        if (grossAfter > maxLiquidity) revert LiquidityOverflow();

        flipped = (grossAfter == 0) != (grossBefore == 0);

        if (grossBefore == 0) {
            // by convention, all growth before a tick was initialized happened below the tick
            if (tick <= tickCurrent) {
                info.feeGrowthOutside0X128 = feeGrowthGlobal0X128;
                info.feeGrowthOutside1X128 = feeGrowthGlobal1X128;
            }
            info.initialized = true;
        }

        info.liquidityGross = grossAfter;
        // when the lower (upper) tick is crossed left to right, liquidity must be added (removed)
        info.liquidityNet = upper ? info.liquidityNet - liquidityDelta : info.liquidityNet + liquidityDelta;
    }

    function clear(mapping(int24 => Info) storage self, int24 tick) internal {
        delete self[tick];
    }

    function cross(
        mapping(int24 => Info) storage self,
        int24 tick,
        uint256 feeGrowthGlobal0X128,
        uint256 feeGrowthGlobal1X128
    ) internal returns (int128 liquidityNet) {
        Info storage info = self[tick];
        unchecked {
            info.feeGrowthOutside0X128 = feeGrowthGlobal0X128 - info.feeGrowthOutside0X128;
            info.feeGrowthOutside1X128 = feeGrowthGlobal1X128 - info.feeGrowthOutside1X128;
        }
        liquidityNet = info.liquidityNet;
    }
}
