// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {FixedPointMathLib as FPM} from "solady/utils/FixedPointMathLib.sol";
import {TickMath} from "./libraries/TickMath.sol";
import {SqrtPriceMath} from "./libraries/SqrtPriceMath.sol";
import {SwapMath} from "./libraries/SwapMath.sol";
import {LiquidityMath} from "./libraries/LiquidityMath.sol";
import {TickBitmap} from "./libraries/TickBitmap.sol";
import {Tick} from "./libraries/Tick.sol";
import {Position} from "./libraries/Position.sol";
import {IDexV3MintCallback, IDexV3SwapCallback} from "./interfaces/IDexV3Callbacks.sol";

interface IERC20Balance {
    function balanceOf(address) external view returns (uint256);
}

/// @title DexV3Pool
/// @notice Concentrated-liquidity pool with a Uniswap-V3-style interface: LPs provide liquidity on
///         [tickLower, tickUpper) ranges, swaps walk the tick bitmap, and fees accrue per unit of
///         in-range liquidity via feeGrowthGlobal / feeGrowthOutside.
/// @dev    Differences from V3: no TWAP oracle, no protocol fee, no flash(). Payments use callbacks
///         (dexV3MintCallback / dexV3SwapCallback) and are checked by balance, as in V3.
contract DexV3Pool {
    using Tick for mapping(int24 => Tick.Info);
    using TickBitmap for mapping(int16 => uint256);
    using Position for Position.Info;

    uint256 internal constant Q128 = 0x100000000000000000000000000000000;

    address public immutable factory;
    address public immutable token0;
    address public immutable token1;
    uint24 public immutable fee; // hundredths of a bip: 2500 = 0.25%
    int24 public immutable tickSpacing;
    uint128 public immutable maxLiquidityPerTick;

    struct Slot0 {
        uint160 sqrtPriceX96;
        int24 tick;
        bool unlocked;
    }

    Slot0 public slot0;
    uint256 public feeGrowthGlobal0X128;
    uint256 public feeGrowthGlobal1X128;
    uint128 public liquidity; // in-range liquidity

    mapping(int24 => Tick.Info) public ticks;
    mapping(int16 => uint256) public tickBitmap;
    mapping(bytes32 => Position.Info) public positions;

    event Initialize(uint160 sqrtPriceX96, int24 tick);
    event Mint(
        address sender,
        address indexed owner,
        int24 indexed tickLower,
        int24 indexed tickUpper,
        uint128 amount,
        uint256 amount0,
        uint256 amount1
    );
    event Burn(
        address indexed owner,
        int24 indexed tickLower,
        int24 indexed tickUpper,
        uint128 amount,
        uint256 amount0,
        uint256 amount1
    );
    event Collect(
        address indexed owner,
        address recipient,
        int24 indexed tickLower,
        int24 indexed tickUpper,
        uint128 amount0,
        uint128 amount1
    );
    event Swap(
        address indexed sender,
        address indexed recipient,
        int256 amount0,
        int256 amount1,
        uint160 sqrtPriceX96,
        uint128 liquidity,
        int24 tick
    );

    error Locked();
    error AlreadyInitialized();
    error TicksMisordered();
    error TickLowerOutOfRange();
    error TickUpperOutOfRange();
    error TickNotSpaced();
    error ZeroLiquidity();
    error AmountSpecifiedZero();
    error BadPriceLimit();
    error Mint0NotPaid();
    error Mint1NotPaid();
    error SwapInputNotPaid();
    error TransferFailed();

    struct SwapState {
        int256 amountSpecifiedRemaining;
        int256 amountCalculated;
        uint160 sqrtPriceX96;
        int24 tick;
        uint256 feeGrowthGlobalX128; // of the input token
        uint128 liquidity;
    }

    struct StepComputations {
        uint160 sqrtPriceStartX96;
        int24 tickNext;
        bool initialized;
        uint160 sqrtPriceNextX96;
        uint256 amountIn;
        uint256 amountOut;
        uint256 feeAmount;
    }

    /// @dev Also blocks everything until initialize() (unlocked starts false).
    modifier lock() {
        if (!slot0.unlocked) revert Locked();
        slot0.unlocked = false;
        _;
        slot0.unlocked = true;
    }

    constructor(address _token0, address _token1, uint24 _fee, int24 _tickSpacing) {
        factory = msg.sender;
        token0 = _token0;
        token1 = _token1;
        fee = _fee;
        tickSpacing = _tickSpacing;
        maxLiquidityPerTick = Tick.tickSpacingToMaxLiquidityPerTick(_tickSpacing);
    }

    function positionKey(address owner, int24 tickLower, int24 tickUpper) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(owner, tickLower, tickUpper));
    }

    function initialize(uint160 sqrtPriceX96) external {
        if (slot0.sqrtPriceX96 != 0) revert AlreadyInitialized();
        int24 tick = TickMath.getTickAtSqrtRatio(sqrtPriceX96);
        slot0 = Slot0({sqrtPriceX96: sqrtPriceX96, tick: tick, unlocked: true});
        emit Initialize(sqrtPriceX96, tick);
    }

    // ============================================================ liquidity

    /// @notice Add `amount` liquidity to recipient's [tickLower, tickUpper) position; pay in the callback.
    function mint(address recipient, int24 tickLower, int24 tickUpper, uint128 amount, bytes calldata data)
        external
        lock
        returns (uint256 amount0, uint256 amount1)
    {
        if (amount == 0) revert ZeroLiquidity();
        (, int256 a0, int256 a1) = _modifyPosition(recipient, tickLower, tickUpper, LiquidityMath.toInt128(amount));
        amount0 = uint256(a0);
        amount1 = uint256(a1);

        uint256 b0 = amount0 > 0 ? _balance0() : 0;
        uint256 b1 = amount1 > 0 ? _balance1() : 0;
        IDexV3MintCallback(msg.sender).dexV3MintCallback(amount0, amount1, data);
        if (amount0 > 0 && b0 + amount0 > _balance0()) revert Mint0NotPaid();
        if (amount1 > 0 && b1 + amount1 > _balance1()) revert Mint1NotPaid();

        emit Mint(msg.sender, recipient, tickLower, tickUpper, amount, amount0, amount1);
    }

    /// @notice Remove liquidity from the caller's position; tokens become collectable via collect().
    ///         amount = 0 just credits accrued fees.
    function burn(int24 tickLower, int24 tickUpper, uint128 amount)
        external
        lock
        returns (uint256 amount0, uint256 amount1)
    {
        (Position.Info storage position, int256 a0, int256 a1) =
            _modifyPosition(msg.sender, tickLower, tickUpper, -LiquidityMath.toInt128(amount));
        amount0 = uint256(-a0);
        amount1 = uint256(-a1);
        if (amount0 > 0 || amount1 > 0) {
            position.tokensOwed0 += uint128(amount0);
            position.tokensOwed1 += uint128(amount1);
        }
        emit Burn(msg.sender, tickLower, tickUpper, amount, amount0, amount1);
    }

    function collect(
        address recipient,
        int24 tickLower,
        int24 tickUpper,
        uint128 amount0Requested,
        uint128 amount1Requested
    ) external lock returns (uint128 amount0, uint128 amount1) {
        Position.Info storage position = positions[positionKey(msg.sender, tickLower, tickUpper)];
        amount0 = amount0Requested > position.tokensOwed0 ? position.tokensOwed0 : amount0Requested;
        amount1 = amount1Requested > position.tokensOwed1 ? position.tokensOwed1 : amount1Requested;
        if (amount0 > 0) {
            position.tokensOwed0 -= amount0;
            _transfer(token0, recipient, amount0);
        }
        if (amount1 > 0) {
            position.tokensOwed1 -= amount1;
            _transfer(token1, recipient, amount1);
        }
        emit Collect(msg.sender, recipient, tickLower, tickUpper, amount0, amount1);
    }

    // ================================================================ swap

    /// @param amountSpecified > 0 exact input, < 0 exact output.
    /// @return amount0 Pool's token0 delta (positive = received), amount1 likewise.
    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) external returns (int256 amount0, int256 amount1) {
        if (amountSpecified == 0) revert AmountSpecifiedZero();
        Slot0 memory start = slot0;
        if (!start.unlocked) revert Locked();
        if (
            zeroForOne
                ? sqrtPriceLimitX96 >= start.sqrtPriceX96 || sqrtPriceLimitX96 <= TickMath.MIN_SQRT_RATIO
                : sqrtPriceLimitX96 <= start.sqrtPriceX96 || sqrtPriceLimitX96 >= TickMath.MAX_SQRT_RATIO
        ) revert BadPriceLimit();
        slot0.unlocked = false;

        SwapState memory state = SwapState({
            amountSpecifiedRemaining: amountSpecified,
            amountCalculated: 0,
            sqrtPriceX96: start.sqrtPriceX96,
            tick: start.tick,
            feeGrowthGlobalX128: zeroForOne ? feeGrowthGlobal0X128 : feeGrowthGlobal1X128,
            liquidity: liquidity
        });
        uint128 liquidityStart = state.liquidity;

        _swapLoop(state, zeroForOne, sqrtPriceLimitX96);

        slot0.sqrtPriceX96 = state.sqrtPriceX96;
        slot0.tick = state.tick;
        if (liquidityStart != state.liquidity) liquidity = state.liquidity;
        if (zeroForOne) feeGrowthGlobal0X128 = state.feeGrowthGlobalX128;
        else feeGrowthGlobal1X128 = state.feeGrowthGlobalX128;

        (amount0, amount1) = zeroForOne == (amountSpecified > 0)
            ? (amountSpecified - state.amountSpecifiedRemaining, state.amountCalculated)
            : (state.amountCalculated, amountSpecified - state.amountSpecifiedRemaining);

        _settleSwap(recipient, zeroForOne, amount0, amount1, data);
        emit Swap(msg.sender, recipient, amount0, amount1, state.sqrtPriceX96, state.liquidity, state.tick);
        slot0.unlocked = true;
    }

    function _swapLoop(SwapState memory state, bool zeroForOne, uint160 sqrtPriceLimitX96) internal {
        bool exactInput = state.amountSpecifiedRemaining > 0;

        while (state.amountSpecifiedRemaining != 0 && state.sqrtPriceX96 != sqrtPriceLimitX96) {
            StepComputations memory step;
            step.sqrtPriceStartX96 = state.sqrtPriceX96;

            (step.tickNext, step.initialized) =
                tickBitmap.nextInitializedTickWithinOneWord(state.tick, tickSpacing, zeroForOne);
            // the bitmap doesn't know about the tick bounds
            if (step.tickNext < TickMath.MIN_TICK) step.tickNext = TickMath.MIN_TICK;
            else if (step.tickNext > TickMath.MAX_TICK) step.tickNext = TickMath.MAX_TICK;
            step.sqrtPriceNextX96 = TickMath.getSqrtRatioAtTick(step.tickNext);

            (state.sqrtPriceX96, step.amountIn, step.amountOut, step.feeAmount) = SwapMath.computeSwapStep(
                state.sqrtPriceX96,
                (zeroForOne ? step.sqrtPriceNextX96 < sqrtPriceLimitX96 : step.sqrtPriceNextX96 > sqrtPriceLimitX96)
                    ? sqrtPriceLimitX96
                    : step.sqrtPriceNextX96,
                state.liquidity,
                state.amountSpecifiedRemaining,
                fee
            );

            if (exactInput) {
                state.amountSpecifiedRemaining -= int256(step.amountIn + step.feeAmount);
                state.amountCalculated -= int256(step.amountOut);
            } else {
                state.amountSpecifiedRemaining += int256(step.amountOut);
                state.amountCalculated += int256(step.amountIn + step.feeAmount);
            }

            if (state.liquidity > 0) {
                unchecked {
                    state.feeGrowthGlobalX128 += FPM.fullMulDiv(step.feeAmount, Q128, state.liquidity);
                }
            }

            if (state.sqrtPriceX96 == step.sqrtPriceNextX96) {
                // reached the next tick: cross it if initialized
                if (step.initialized) {
                    int128 liquidityNet = ticks.cross(
                        step.tickNext,
                        zeroForOne ? state.feeGrowthGlobalX128 : feeGrowthGlobal0X128,
                        zeroForOne ? feeGrowthGlobal1X128 : state.feeGrowthGlobalX128
                    );
                    // moving leftward, liquidityNet is interpreted the opposite way
                    if (zeroForOne) liquidityNet = -liquidityNet;
                    state.liquidity = LiquidityMath.addDelta(state.liquidity, liquidityNet);
                }
                state.tick = zeroForOne ? step.tickNext - 1 : step.tickNext;
            } else if (state.sqrtPriceX96 != step.sqrtPriceStartX96) {
                state.tick = TickMath.getTickAtSqrtRatio(state.sqrtPriceX96);
            }
        }
    }

    function _settleSwap(address recipient, bool zeroForOne, int256 amount0, int256 amount1, bytes calldata data)
        internal
    {
        if (zeroForOne) {
            if (amount1 < 0) _transfer(token1, recipient, uint256(-amount1));
            uint256 b0 = _balance0();
            IDexV3SwapCallback(msg.sender).dexV3SwapCallback(amount0, amount1, data);
            if (b0 + uint256(amount0) > _balance0()) revert SwapInputNotPaid();
        } else {
            if (amount0 < 0) _transfer(token0, recipient, uint256(-amount0));
            uint256 b1 = _balance1();
            IDexV3SwapCallback(msg.sender).dexV3SwapCallback(amount0, amount1, data);
            if (b1 + uint256(amount1) > _balance1()) revert SwapInputNotPaid();
        }
    }

    // ============================================================= internal

    function _checkTicks(int24 tickLower, int24 tickUpper) internal view {
        if (tickLower >= tickUpper) revert TicksMisordered();
        if (tickLower < TickMath.MIN_TICK) revert TickLowerOutOfRange();
        if (tickUpper > TickMath.MAX_TICK) revert TickUpperOutOfRange();
        if (tickLower % tickSpacing != 0 || tickUpper % tickSpacing != 0) revert TickNotSpaced();
    }

    function _modifyPosition(address owner, int24 tickLower, int24 tickUpper, int128 liquidityDelta)
        internal
        returns (Position.Info storage position, int256 amount0, int256 amount1)
    {
        _checkTicks(tickLower, tickUpper);
        int24 tick = slot0.tick;
        position = _updatePosition(owner, tickLower, tickUpper, liquidityDelta, tick);
        if (liquidityDelta != 0) (amount0, amount1) = _amountsForDelta(tickLower, tickUpper, liquidityDelta, tick);
    }

    function _amountsForDelta(int24 tickLower, int24 tickUpper, int128 liquidityDelta, int24 tick)
        internal
        returns (int256 amount0, int256 amount1)
    {
        uint160 sqrtLower = TickMath.getSqrtRatioAtTick(tickLower);
        uint160 sqrtUpper = TickMath.getSqrtRatioAtTick(tickUpper);
        if (tick < tickLower) {
            // entirely above the price: only token0
            amount0 = SqrtPriceMath.getAmount0Delta(sqrtLower, sqrtUpper, liquidityDelta);
        } else if (tick < tickUpper) {
            uint160 sqrtPrice = slot0.sqrtPriceX96;
            amount0 = SqrtPriceMath.getAmount0Delta(sqrtPrice, sqrtUpper, liquidityDelta);
            amount1 = SqrtPriceMath.getAmount1Delta(sqrtLower, sqrtPrice, liquidityDelta);
            liquidity = LiquidityMath.addDelta(liquidity, liquidityDelta);
        } else {
            // entirely below the price: only token1
            amount1 = SqrtPriceMath.getAmount1Delta(sqrtLower, sqrtUpper, liquidityDelta);
        }
    }

    function _updatePosition(address owner, int24 tickLower, int24 tickUpper, int128 liquidityDelta, int24 tick)
        internal
        returns (Position.Info storage position)
    {
        position = positions[positionKey(owner, tickLower, tickUpper)];
        uint256 fg0 = feeGrowthGlobal0X128;
        uint256 fg1 = feeGrowthGlobal1X128;

        bool flippedLower;
        bool flippedUpper;
        if (liquidityDelta != 0) {
            flippedLower = ticks.update(tickLower, tick, liquidityDelta, fg0, fg1, false, maxLiquidityPerTick);
            flippedUpper = ticks.update(tickUpper, tick, liquidityDelta, fg0, fg1, true, maxLiquidityPerTick);
            if (flippedLower) tickBitmap.flipTick(tickLower, tickSpacing);
            if (flippedUpper) tickBitmap.flipTick(tickUpper, tickSpacing);
        }

        (uint256 inside0, uint256 inside1) = ticks.getFeeGrowthInside(tickLower, tickUpper, tick, fg0, fg1);
        position.update(liquidityDelta, inside0, inside1);

        // clear ticks no longer referenced
        if (liquidityDelta < 0) {
            if (flippedLower) ticks.clear(tickLower);
            if (flippedUpper) ticks.clear(tickUpper);
        }
    }

    function _balance0() internal view returns (uint256) {
        return IERC20Balance(token0).balanceOf(address(this));
    }

    function _balance1() internal view returns (uint256) {
        return IERC20Balance(token1).balanceOf(address(this));
    }

    function _transfer(address token, address to, uint256 value) internal {
        (bool ok, bytes memory ret) = token.call(abi.encodeWithSelector(0xa9059cbb, to, value));
        if (!ok || (ret.length != 0 && !abi.decode(ret, (bool)))) revert TransferFailed();
    }
}
