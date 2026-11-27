// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {FixedPointMathLib as FPM} from "solady/utils/FixedPointMathLib.sol";
import {LiquidityMath} from "./LiquidityMath.sol";

/// @notice Port of Uniswap v3-core SqrtPriceMath (GPL-2.0-or-later) to Solidity 0.8.
///         FullMath.mulDiv / mulDivRoundingUp -> solady fullMulDiv / fullMulDivUp; UnsafeMath.divRoundingUp -> divUp.
library SqrtPriceMath {
    error PriceOverflow();
    error ZeroPriceOrLiquidity();

    uint8 internal constant RESOLUTION = 96;
    uint256 internal constant Q96 = 0x1000000000000000000000000;

    /// @dev Rounds up: when adding token0 the price must not move down too far, when removing, too little.
    function getNextSqrtPriceFromAmount0RoundingUp(uint160 sqrtPX96, uint128 liquidity, uint256 amount, bool add)
        internal
        pure
        returns (uint160)
    {
        if (amount == 0) return sqrtPX96;
        uint256 numerator1 = uint256(liquidity) << RESOLUTION;

        if (add) {
            unchecked {
                uint256 product = amount * sqrtPX96;
                if (product / amount == sqrtPX96) {
                    uint256 denominator = numerator1 + product;
                    if (denominator >= numerator1) {
                        return uint160(FPM.fullMulDivUp(numerator1, sqrtPX96, denominator));
                    }
                }
            }
            return uint160(FPM.divUp(numerator1, (numerator1 / sqrtPX96) + amount));
        } else {
            uint256 denominator;
            unchecked {
                uint256 product = amount * sqrtPX96;
                if (product / amount != sqrtPX96 || numerator1 <= product) revert PriceOverflow();
                denominator = numerator1 - product;
            }
            return LiquidityMath.toUint160(FPM.fullMulDivUp(numerator1, sqrtPX96, denominator));
        }
    }

    /// @dev Rounds down: when adding token1 the price must not move up too far, when removing, too little.
    function getNextSqrtPriceFromAmount1RoundingDown(uint160 sqrtPX96, uint128 liquidity, uint256 amount, bool add)
        internal
        pure
        returns (uint160)
    {
        if (add) {
            uint256 quotient = amount <= type(uint160).max
                ? (amount << RESOLUTION) / liquidity
                : FPM.fullMulDiv(amount, Q96, liquidity);
            return LiquidityMath.toUint160(uint256(sqrtPX96) + quotient);
        } else {
            uint256 quotient = amount <= type(uint160).max
                ? FPM.divUp(amount << RESOLUTION, liquidity)
                : FPM.fullMulDivUp(amount, Q96, liquidity);
            if (sqrtPX96 <= quotient) revert PriceOverflow();
            unchecked {
                return uint160(sqrtPX96 - quotient);
            }
        }
    }

    function getNextSqrtPriceFromInput(uint160 sqrtPX96, uint128 liquidity, uint256 amountIn, bool zeroForOne)
        internal
        pure
        returns (uint160)
    {
        if (sqrtPX96 == 0 || liquidity == 0) revert ZeroPriceOrLiquidity();
        return zeroForOne
            ? getNextSqrtPriceFromAmount0RoundingUp(sqrtPX96, liquidity, amountIn, true)
            : getNextSqrtPriceFromAmount1RoundingDown(sqrtPX96, liquidity, amountIn, true);
    }

    function getNextSqrtPriceFromOutput(uint160 sqrtPX96, uint128 liquidity, uint256 amountOut, bool zeroForOne)
        internal
        pure
        returns (uint160)
    {
        if (sqrtPX96 == 0 || liquidity == 0) revert ZeroPriceOrLiquidity();
        return zeroForOne
            ? getNextSqrtPriceFromAmount1RoundingDown(sqrtPX96, liquidity, amountOut, false)
            : getNextSqrtPriceFromAmount0RoundingUp(sqrtPX96, liquidity, amountOut, false);
    }

    /// @notice amount0 = L * (sqrtB - sqrtA) / (sqrtA * sqrtB)
    function getAmount0Delta(uint160 sqrtRatioAX96, uint160 sqrtRatioBX96, uint128 liquidity, bool roundUp)
        internal
        pure
        returns (uint256)
    {
        if (sqrtRatioAX96 > sqrtRatioBX96) (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);
        if (sqrtRatioAX96 == 0) revert ZeroPriceOrLiquidity();
        uint256 numerator1 = uint256(liquidity) << RESOLUTION;
        uint256 numerator2 = sqrtRatioBX96 - sqrtRatioAX96;
        return roundUp
            ? FPM.divUp(FPM.fullMulDivUp(numerator1, numerator2, sqrtRatioBX96), sqrtRatioAX96)
            : FPM.fullMulDiv(numerator1, numerator2, sqrtRatioBX96) / sqrtRatioAX96;
    }

    /// @notice amount1 = L * (sqrtB - sqrtA)
    function getAmount1Delta(uint160 sqrtRatioAX96, uint160 sqrtRatioBX96, uint128 liquidity, bool roundUp)
        internal
        pure
        returns (uint256)
    {
        if (sqrtRatioAX96 > sqrtRatioBX96) (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);
        return roundUp
            ? FPM.fullMulDivUp(liquidity, sqrtRatioBX96 - sqrtRatioAX96, Q96)
            : FPM.fullMulDiv(liquidity, sqrtRatioBX96 - sqrtRatioAX96, Q96);
    }

    /// @dev Signed: positive (rounded up) when adding liquidity, negative (rounded down) when removing.
    function getAmount0Delta(uint160 sqrtRatioAX96, uint160 sqrtRatioBX96, int128 liquidity)
        internal
        pure
        returns (int256)
    {
        return liquidity < 0
            ? -LiquidityMath.toInt256(getAmount0Delta(sqrtRatioAX96, sqrtRatioBX96, uint128(-liquidity), false))
            : LiquidityMath.toInt256(getAmount0Delta(sqrtRatioAX96, sqrtRatioBX96, uint128(liquidity), true));
    }

    function getAmount1Delta(uint160 sqrtRatioAX96, uint160 sqrtRatioBX96, int128 liquidity)
        internal
        pure
        returns (int256)
    {
        return liquidity < 0
            ? -LiquidityMath.toInt256(getAmount1Delta(sqrtRatioAX96, sqrtRatioBX96, uint128(-liquidity), false))
            : LiquidityMath.toInt256(getAmount1Delta(sqrtRatioAX96, sqrtRatioBX96, uint128(liquidity), true));
    }
}
