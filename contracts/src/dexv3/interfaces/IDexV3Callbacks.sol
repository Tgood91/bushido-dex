// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Called on `msg.sender` by DexV3Pool.mint: pay at least amount0Owed/amount1Owed to the pool.
interface IDexV3MintCallback {
    function dexV3MintCallback(uint256 amount0Owed, uint256 amount1Owed, bytes calldata data) external;
}

/// @notice Called on `msg.sender` by DexV3Pool.swap: pay the positive delta to the pool.
interface IDexV3SwapCallback {
    function dexV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external;
}
