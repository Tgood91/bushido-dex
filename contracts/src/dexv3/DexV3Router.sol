// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {DexV3Factory} from "./DexV3Factory.sol";
import {DexV3Pool} from "./DexV3Pool.sol";
import {TickMath} from "./libraries/TickMath.sol";
import {LiquidityMath} from "./libraries/LiquidityMath.sol";
import {IDexV3MintCallback, IDexV3SwapCallback} from "./interfaces/IDexV3Callbacks.sol";

/// @title DexV3Router
/// @notice Swaps (exact input single/multi-hop, exact output single) and liquidity adds for DexV3Pools.
///         Pays pools inside their callbacks, pulling from the caller's approval. Callbacks only accept
///         calls from pools registered in the factory.
/// @dev    Positions minted through the router are owned by `recipient` directly in the pool, so the owner
///         burns and collects on the pool itself (no NFT position manager).
contract DexV3Router is IDexV3SwapCallback, IDexV3MintCallback {
    DexV3Factory public immutable factory;

    struct SwapCallbackData {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address payer;
    }

    struct MintCallbackData {
        address token0;
        address token1;
        uint24 fee;
        address payer;
    }

    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96; // 0 = no limit
    }

    struct ExactInputParams {
        address[] tokens; // tokens[0] -> tokens[1] -> ...
        uint24[] fees; // fees[i] is the pool between tokens[i] and tokens[i + 1]
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }

    struct ExactOutputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountOut;
        uint256 amountInMaximum;
        uint160 sqrtPriceLimitX96; // 0 = no limit
    }

    struct AddLiquidityParams {
        address tokenA;
        address tokenB;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint256 amountAMax;
        uint256 amountBMax;
        address recipient;
        uint256 deadline;
    }

    error Expired();
    error InvalidPath();
    error PoolMissing();
    error NotPool();
    error NothingOwed();
    error TooLittleReceived();
    error TooMuchRequested();
    error OutputNotFilled();
    error TransferFailed();

    modifier ensure(uint256 deadline) {
        if (block.timestamp > deadline) revert Expired();
        _;
    }

    constructor(DexV3Factory _factory) {
        factory = _factory;
    }

    // ================================================================ pools

    function createAndInitializePoolIfNecessary(address tokenA, address tokenB, uint24 fee, uint160 sqrtPriceX96)
        external
        returns (address pool)
    {
        pool = factory.getPool(tokenA, tokenB, fee);
        if (pool == address(0)) pool = factory.createPool(tokenA, tokenB, fee);
        (uint160 current,,) = DexV3Pool(pool).slot0();
        if (current == 0) DexV3Pool(pool).initialize(sqrtPriceX96);
    }

    // ============================================================ liquidity

    function addLiquidity(AddLiquidityParams calldata p)
        external
        ensure(p.deadline)
        returns (uint256 amountA, uint256 amountB)
    {
        (amountA, amountB) = _mint(p);
        if (amountA > p.amountAMax || amountB > p.amountBMax) revert TooMuchRequested();
    }

    function _mint(AddLiquidityParams calldata p) internal returns (uint256 amountA, uint256 amountB) {
        bool aIs0 = p.tokenA < p.tokenB;
        bytes memory data = aIs0
            ? abi.encode(MintCallbackData(p.tokenA, p.tokenB, p.fee, msg.sender))
            : abi.encode(MintCallbackData(p.tokenB, p.tokenA, p.fee, msg.sender));
        (uint256 amount0, uint256 amount1) =
            DexV3Pool(_pool(p.tokenA, p.tokenB, p.fee)).mint(p.recipient, p.tickLower, p.tickUpper, p.liquidity, data);
        (amountA, amountB) = aIs0 ? (amount0, amount1) : (amount1, amount0);
    }

    function dexV3MintCallback(uint256 amount0Owed, uint256 amount1Owed, bytes calldata data) external {
        MintCallbackData memory d = abi.decode(data, (MintCallbackData));
        _verifyPool(d.token0, d.token1, d.fee);
        if (amount0Owed > 0) _pay(d.token0, d.payer, msg.sender, amount0Owed);
        if (amount1Owed > 0) _pay(d.token1, d.payer, msg.sender, amount1Owed);
    }

    // ================================================================ swaps

    function exactInputSingle(ExactInputSingleParams calldata p)
        external
        ensure(p.deadline)
        returns (uint256 amountOut)
    {
        amountOut = _exactInput(
            p.amountIn, p.recipient, p.sqrtPriceLimitX96, SwapCallbackData(p.tokenIn, p.tokenOut, p.fee, msg.sender)
        );
        if (amountOut < p.amountOutMinimum) revert TooLittleReceived();
    }

    function exactInput(ExactInputParams calldata p) external ensure(p.deadline) returns (uint256 amountOut) {
        uint256 hops = p.fees.length;
        if (hops == 0 || p.tokens.length != hops + 1) revert InvalidPath();
        amountOut = p.amountIn;
        for (uint256 i; i < hops; ++i) {
            bool last = i == hops - 1;
            // intermediate hops land in the router, which then pays the next pool from its own balance
            amountOut = _exactInput(
                amountOut,
                last ? p.recipient : address(this),
                0,
                SwapCallbackData(p.tokens[i], p.tokens[i + 1], p.fees[i], i == 0 ? msg.sender : address(this))
            );
        }
        if (amountOut < p.amountOutMinimum) revert TooLittleReceived();
    }

    function exactOutputSingle(ExactOutputSingleParams calldata p)
        external
        ensure(p.deadline)
        returns (uint256 amountIn)
    {
        bool zeroForOne = p.tokenIn < p.tokenOut;
        (int256 a0, int256 a1) = DexV3Pool(_pool(p.tokenIn, p.tokenOut, p.fee)).swap(
            p.recipient,
            zeroForOne,
            -LiquidityMath.toInt256(p.amountOut),
            _limit(zeroForOne, p.sqrtPriceLimitX96),
            abi.encode(SwapCallbackData(p.tokenIn, p.tokenOut, p.fee, msg.sender))
        );
        uint256 received;
        (amountIn, received) = zeroForOne ? (uint256(a0), uint256(-a1)) : (uint256(a1), uint256(-a0));
        // without a price limit the full output must be delivered
        if (p.sqrtPriceLimitX96 == 0 && received != p.amountOut) revert OutputNotFilled();
        if (amountIn > p.amountInMaximum) revert TooMuchRequested();
    }

    function dexV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external {
        if (amount0Delta <= 0 && amount1Delta <= 0) revert NothingOwed();
        SwapCallbackData memory d = abi.decode(data, (SwapCallbackData));
        _verifyPool(d.tokenIn, d.tokenOut, d.fee);
        // the input token's delta is the positive one
        _pay(d.tokenIn, d.payer, msg.sender, amount0Delta > 0 ? uint256(amount0Delta) : uint256(amount1Delta));
    }

    // ============================================================= internal

    function _exactInput(uint256 amountIn, address recipient, uint160 limit, SwapCallbackData memory d)
        internal
        returns (uint256 amountOut)
    {
        bool zeroForOne = d.tokenIn < d.tokenOut;
        (int256 a0, int256 a1) = DexV3Pool(_pool(d.tokenIn, d.tokenOut, d.fee)).swap(
            recipient, zeroForOne, LiquidityMath.toInt256(amountIn), _limit(zeroForOne, limit), abi.encode(d)
        );
        amountOut = uint256(-(zeroForOne ? a1 : a0));
    }

    function _limit(bool zeroForOne, uint160 limit) internal pure returns (uint160) {
        if (limit != 0) return limit;
        return zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1;
    }

    function _pool(address a, address b, uint24 fee) internal view returns (address p) {
        p = factory.getPool(a, b, fee);
        if (p == address(0)) revert PoolMissing();
    }

    function _verifyPool(address a, address b, uint24 fee) internal view {
        address p = factory.getPool(a, b, fee);
        if (p == address(0) || msg.sender != p) revert NotPool();
    }

    function _pay(address token, address payer, address to, uint256 value) internal {
        (bool ok, bytes memory ret) = payer == address(this)
            ? token.call(abi.encodeWithSelector(0xa9059cbb, to, value))
            : token.call(abi.encodeWithSelector(0x23b872dd, payer, to, value));
        if (!ok || (ret.length != 0 && !abi.decode(ret, (bool)))) revert TransferFailed();
    }
}
