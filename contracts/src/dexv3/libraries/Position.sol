// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {FixedPointMathLib as FPM} from "solady/utils/FixedPointMathLib.sol";
import {LiquidityMath} from "./LiquidityMath.sol";

/// @notice Port of Uniswap v3-core Position (GPL-2.0-or-later) to Solidity 0.8.
library Position {
    error NoPosition();

    uint256 internal constant Q128 = 0x100000000000000000000000000000000;

    struct Info {
        uint128 liquidity;
        uint256 feeGrowthInside0LastX128;
        uint256 feeGrowthInside1LastX128;
        uint128 tokensOwed0; // principal from burns plus fees, collectable
        uint128 tokensOwed1;
    }

    /// @notice Credits fees earned since the last update and applies the liquidity change.
    function update(Info storage self, int128 liquidityDelta, uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128)
        internal
    {
        Info memory _self = self;

        uint128 liquidityNext;
        if (liquidityDelta == 0) {
            if (_self.liquidity == 0) revert NoPosition(); // disallow pokes for 0 liquidity positions
            liquidityNext = _self.liquidity;
        } else {
            liquidityNext = LiquidityMath.addDelta(_self.liquidity, liquidityDelta);
        }

        uint128 owed0;
        uint128 owed1;
        unchecked {
            owed0 = uint128(FPM.fullMulDiv(feeGrowthInside0X128 - _self.feeGrowthInside0LastX128, _self.liquidity, Q128));
            owed1 = uint128(FPM.fullMulDiv(feeGrowthInside1X128 - _self.feeGrowthInside1LastX128, _self.liquidity, Q128));
        }

        if (liquidityDelta != 0) self.liquidity = liquidityNext;
        self.feeGrowthInside0LastX128 = feeGrowthInside0X128;
        self.feeGrowthInside1LastX128 = feeGrowthInside1X128;
        if (owed0 > 0 || owed1 > 0) {
            unchecked {
                // overflow is acceptable, owners must collect before hitting type(uint128).max (as in V3)
                self.tokensOwed0 += owed0;
                self.tokensOwed1 += owed1;
            }
        }
    }
}
