// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

/// @notice Port of Uniswap v3-core LiquidityMath and SafeCast (GPL-2.0-or-later) to Solidity 0.8.
library LiquidityMath {
    error CastOverflow();

    /// @dev Checked arithmetic reverts on underflow/overflow (V3's 'LS'/'LA').
    function addDelta(uint128 x, int128 y) internal pure returns (uint128) {
        return y < 0 ? x - uint128(-y) : x + uint128(y);
    }

    function toUint160(uint256 x) internal pure returns (uint160) {
        if (x > type(uint160).max) revert CastOverflow();
        return uint160(x);
    }

    function toInt128(uint128 x) internal pure returns (int128) {
        if (x > uint128(type(int128).max)) revert CastOverflow();
        return int128(x);
    }

    function toInt256(uint256 x) internal pure returns (int256) {
        if (x > uint256(type(int256).max)) revert CastOverflow();
        return int256(x);
    }
}
