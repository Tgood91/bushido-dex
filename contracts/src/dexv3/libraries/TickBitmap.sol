// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {LibBit} from "solady/utils/LibBit.sol";

/// @notice Port of Uniswap v3-core TickBitmap (GPL-2.0-or-later) to Solidity 0.8.
///         One bit per spaced tick: word = compressed >> 8, bit = compressed mod 256.
library TickBitmap {
    error TickNotSpaced();

    function position(int24 tick) private pure returns (int16 wordPos, uint8 bitPos) {
        wordPos = int16(tick >> 8);
        bitPos = uint8(uint24(tick % 256)); // two's complement low byte == tick mod 256 for negatives too
    }

    function flipTick(mapping(int16 => uint256) storage self, int24 tick, int24 tickSpacing) internal {
        if (tick % tickSpacing != 0) revert TickNotSpaced();
        (int16 wordPos, uint8 bitPos) = position(tick / tickSpacing);
        self[wordPos] ^= uint256(1) << bitPos;
    }

    /// @notice Next initialized tick in the same 256-bit word, to the left (lte) or right of `tick`.
    /// @return next The next initialized tick, or the word boundary if none is initialized.
    function nextInitializedTickWithinOneWord(
        mapping(int16 => uint256) storage self,
        int24 tick,
        int24 tickSpacing,
        bool lte
    ) internal view returns (int24 next, bool initialized) {
        unchecked {
            int24 compressed = tick / tickSpacing;
            if (tick < 0 && tick % tickSpacing != 0) compressed--; // round towards negative infinity

            if (lte) {
                (int16 wordPos, uint8 bitPos) = position(compressed);
                // all the 1s at or to the right of the current bitPos
                uint256 mask = (uint256(1) << bitPos) - 1 + (uint256(1) << bitPos);
                uint256 masked = self[wordPos] & mask;
                initialized = masked != 0;
                next = initialized
                    ? (compressed - int24(int256(uint256(bitPos) - LibBit.fls(masked)))) * tickSpacing
                    : (compressed - int24(uint24(bitPos))) * tickSpacing;
            } else {
                // start from the word of the next tick, since the current tick state doesn't matter
                (int16 wordPos, uint8 bitPos) = position(compressed + 1);
                // all the 1s at or to the left of the bitPos
                uint256 mask = ~((uint256(1) << bitPos) - 1);
                uint256 masked = self[wordPos] & mask;
                initialized = masked != 0;
                next = initialized
                    ? (compressed + 1 + int24(int256(LibBit.ffs(masked) - uint256(bitPos)))) * tickSpacing
                    : (compressed + 1 + int24(uint24(type(uint8).max - bitPos))) * tickSpacing;
            }
        }
    }
}
