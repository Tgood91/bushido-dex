// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {DexFactory} from "./DexFactory.sol";
import {DexPair} from "./DexPair.sol";

/// @title DexRouter
/// @notice Adds/removes liquidity and routes exact-input swaps (multi-hop) through DexPairs.
contract DexRouter {
    DexFactory public immutable factory;
    uint256 private constant FEE_BPS = 25;
    uint256 private constant BPS = 10_000;

    error Expired();
    error InvalidPath();
    error PairMissing();
    error InsufficientAAmount();
    error InsufficientBAmount();
    error InsufficientAmount();
    error InsufficientLiquidity();
    error InsufficientInputAmount();
    error InsufficientOutputAmount();
    error TransferFailed();

    modifier ensure(uint256 deadline) {
        if (block.timestamp > deadline) revert Expired();
        _;
    }

    constructor(DexFactory _factory) {
        factory = _factory;
    }

    // ------------------------------------------------------------- liquidity
    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external ensure(deadline) returns (uint256 amountA, uint256 amountB, uint256 liquidity) {
        address pair;
        (pair, amountA, amountB) = _calcLiquidity(tokenA, tokenB, amountADesired, amountBDesired, amountAMin, amountBMin);
        _safeTransferFrom(tokenA, msg.sender, pair, amountA);
        _safeTransferFrom(tokenB, msg.sender, pair, amountB);
        liquidity = DexPair(pair).mint(to);
    }

    /// @dev Creates the pair if needed and sizes the deposit to the pool's current ratio.
    function _calcLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin
    ) internal returns (address pair, uint256 amountA, uint256 amountB) {
        pair = factory.getPair(tokenA, tokenB);
        if (pair == address(0)) pair = factory.createPair(tokenA, tokenB);

        (uint256 rA, uint256 rB) = _reserves(pair, tokenA);
        if (rA == 0 && rB == 0) return (pair, amountADesired, amountBDesired);

        uint256 bOptimal = quote(amountADesired, rA, rB);
        if (bOptimal <= amountBDesired) {
            if (bOptimal < amountBMin) revert InsufficientBAmount();
            return (pair, amountADesired, bOptimal);
        }
        uint256 aOptimal = quote(amountBDesired, rB, rA);
        if (aOptimal < amountAMin) revert InsufficientAAmount();
        return (pair, aOptimal, amountBDesired);
    }

    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external ensure(deadline) returns (uint256 amountA, uint256 amountB) {
        address pair = factory.getPair(tokenA, tokenB);
        if (pair == address(0)) revert PairMissing();
        _safeTransferFrom(pair, msg.sender, pair, liquidity);
        (uint256 a0, uint256 a1) = DexPair(pair).burn(to);
        (amountA, amountB) = tokenA < tokenB ? (a0, a1) : (a1, a0);
        if (amountA < amountAMin) revert InsufficientAAmount();
        if (amountB < amountBMin) revert InsufficientBAmount();
    }

    // ------------------------------------------------------------------- swap
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external ensure(deadline) returns (uint256[] memory amounts) {
        amounts = getAmountsOut(amountIn, path);
        if (amounts[amounts.length - 1] < amountOutMin) revert InsufficientOutputAmount();
        _safeTransferFrom(path[0], msg.sender, _pair(path[0], path[1]), amounts[0]);
        for (uint256 i; i < path.length - 1; ++i) {
            (address input, address output) = (path[i], path[i + 1]);
            uint256 out = amounts[i + 1];
            (uint256 o0, uint256 o1) = input < output ? (uint256(0), out) : (out, uint256(0));
            address recipient = i < path.length - 2 ? _pair(output, path[i + 2]) : to;
            DexPair(_pair(input, output)).swap(o0, o1, recipient);
        }
    }

    // ------------------------------------------------------------------ views
    function quote(uint256 amountA, uint256 reserveA, uint256 reserveB) public pure returns (uint256) {
        if (amountA == 0) revert InsufficientAmount();
        if (reserveA == 0 || reserveB == 0) revert InsufficientLiquidity();
        return (amountA * reserveB) / reserveA;
    }

    function getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut) public pure returns (uint256) {
        if (amountIn == 0) revert InsufficientInputAmount();
        if (reserveIn == 0 || reserveOut == 0) revert InsufficientLiquidity();
        uint256 inWithFee = amountIn * (BPS - FEE_BPS);
        return (inWithFee * reserveOut) / (reserveIn * BPS + inWithFee);
    }

    function getAmountsOut(uint256 amountIn, address[] calldata path) public view returns (uint256[] memory amounts) {
        if (path.length < 2) revert InvalidPath();
        amounts = new uint256[](path.length);
        amounts[0] = amountIn;
        for (uint256 i; i < path.length - 1; ++i) {
            (uint256 rIn, uint256 rOut) = _reserves(_pair(path[i], path[i + 1]), path[i]);
            amounts[i + 1] = getAmountOut(amounts[i], rIn, rOut);
        }
    }

    // --------------------------------------------------------------- internal
    function _pair(address a, address b) internal view returns (address p) {
        p = factory.getPair(a, b);
        if (p == address(0)) revert PairMissing();
    }

    function _reserves(address pair, address tokenA) internal view returns (uint256 rA, uint256 rB) {
        (uint112 r0, uint112 r1,) = DexPair(pair).getReserves();
        (rA, rB) = tokenA == DexPair(pair).token0() ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
    }

    function _safeTransferFrom(address token, address from, address to, uint256 v) internal {
        (bool ok, bytes memory data) = token.call(abi.encodeWithSelector(0x23b872dd, from, to, v));
        if (!ok || (data.length != 0 && !abi.decode(data, (bool)))) revert TransferFailed();
    }
}
