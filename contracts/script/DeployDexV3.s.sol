// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {FixedPointMathLib as FPM} from "solady/utils/FixedPointMathLib.sol";
import {DexV3Factory} from "../src/dexv3/DexV3Factory.sol";
import {DexV3Router} from "../src/dexv3/DexV3Router.sol";
import {DexV3Pool} from "../src/dexv3/DexV3Pool.sol";
import {TickMath} from "../src/dexv3/libraries/TickMath.sol";
import {DexSeed, ITestToken} from "./DexSeed.sol";
import {vm} from "../test/mocks/Vm.sol";

/// @notice Deploys the V3-style DEX (DexV3Factory + DexV3Router), creates a <token>/tUSDC pool initialized at the
///         live oracle price, and seeds it with two positions owned by DEPLOYER:
///           - full range, with half the seed
///           - concentrated, +/- RANGE_TICKS around the price (default 1000 ticks, about +/-10%), with the other half
///         Env: see DexSeed, plus FEE (default 2500 = 0.25%, the Bushido execution fee; also 100, 500, 3000, 10000)
///         and RANGE_TICKS. Testnets only (ALLOW_FORK=1 for an anvil mainnet fork).
///
///   Base Sepolia (simulate, then add --account <name> --broadcast):
///     DEPLOYER=<addr> FEED=0x4aDC67696bA383F43DD60A9e78F2C97Fbbfc7cb1 USDC=<tUSDC> \
///       forge script script/DeployDexV3.s.sol:DeployDexV3 --rpc-url https://sepolia.base.org
///   Arbitrum Sepolia: FEED=0xd30e2101a97dcbAeBCBC04F14C3f624E67A35165, --rpc-url https://sepolia-rollup.arbitrum.io/rpc
contract DeployDexV3 is DexSeed {
    uint256 internal constant Q96 = 0x1000000000000000000000000;

    error PoolOffPrice(int24 poolTick, int24 oracleTick);

    function run() external returns (DexV3Factory factory, DexV3Router router, address pool, Market memory m) {
        m = _readEnv();
        uint24 fee = uint24(vm.envOr("FEE", uint256(2500)));
        int24 range = int24(int256(vm.envOr("RANGE_TICKS", uint256(1000))));

        vm.startBroadcast(m.deployer);
        _prepareMarket(m);
        factory = new DexV3Factory();
        router = new DexV3Router(factory);
        uint160 sqrtP = _sqrtPriceX96(m);
        pool = router.createAndInitializePoolIfNecessary(m.token, m.usdc, fee, sqrtP);
        ITestToken(m.token).approve(address(router), m.seedToken);
        ITestToken(m.usdc).approve(address(router), m.seedUsdc);

        int24 sp = DexV3Pool(pool).tickSpacing();
        (, int24 tick,) = DexV3Pool(pool).slot0();
        _addRange(router, m, fee, sqrtP, (TickMath.MIN_TICK / sp) * sp, (TickMath.MAX_TICK / sp) * sp);
        _addRange(router, m, fee, sqrtP, _floor(tick - range, sp), _floor(tick + range, sp) + sp);
        vm.stopBroadcast();

        _checkPrice(DexV3Pool(pool), sqrtP);
    }

    /// @notice sqrt(token1 per token0, in base units) * 2^96 from the oracle's USDC-per-whole-token price.
    function _sqrtPriceX96(Market memory m) internal pure returns (uint160) {
        uint256 priceX192 = m.token < m.usdc
            ? FPM.fullMulDiv(m.px, 1 << 192, 1e18) // token0 = token: px / 1e18 USDC units per token wei
            : FPM.fullMulDiv(1e18, 1 << 192, m.px); // token0 = USDC: 1e18 / px token wei per USDC unit
        return uint160(FPM.sqrt(priceX192));
    }

    /// @dev Adds a position worth 49% of each seed (so V3's round-up never exceeds the approvals).
    function _addRange(DexV3Router router, Market memory m, uint24 fee, uint160 sqrtP, int24 lo, int24 hi) internal {
        (uint256 amt0, uint256 amt1) =
            m.token < m.usdc ? (m.seedToken * 49 / 100, m.seedUsdc * 49 / 100) : (m.seedUsdc * 49 / 100, m.seedToken * 49 / 100);
        uint128 liq = _liquidityFor(sqrtP, TickMath.getSqrtRatioAtTick(lo), TickMath.getSqrtRatioAtTick(hi), amt0, amt1);
        router.addLiquidity(
            DexV3Router.AddLiquidityParams({
                tokenA: m.token,
                tokenB: m.usdc,
                fee: fee,
                tickLower: lo,
                tickUpper: hi,
                liquidity: liq,
                amountAMax: m.seedToken / 2,
                amountBMax: m.seedUsdc / 2,
                recipient: m.deployer,
                deadline: block.timestamp + 1 hours
            })
        );
    }

    /// @notice Largest liquidity whose amounts fit in amt0/amt1, for sqrtA < sqrtP < sqrtB.
    function _liquidityFor(uint160 sqrtP, uint160 sqrtA, uint160 sqrtB, uint256 amt0, uint256 amt1)
        internal
        pure
        returns (uint128)
    {
        uint256 l0 = FPM.fullMulDiv(amt0, FPM.fullMulDiv(sqrtP, sqrtB, Q96), sqrtB - sqrtP);
        uint256 l1 = FPM.fullMulDiv(amt1, Q96, sqrtP - sqrtA);
        uint256 l = l0 < l1 ? l0 : l1;
        require(l <= type(uint128).max, "liquidity overflow");
        return uint128(l);
    }

    /// @dev The initialized pool must sit at the oracle price's tick (seeding never moves a V3 price).
    function _checkPrice(DexV3Pool pool, uint160 sqrtP) internal view {
        (uint160 poolSqrtP, int24 poolTick,) = pool.slot0();
        int24 oracleTick = TickMath.getTickAtSqrtRatio(sqrtP);
        if (poolSqrtP != sqrtP || poolTick != oracleTick) revert PoolOffPrice(poolTick, oracleTick);
    }

    function _floor(int24 t, int24 sp) internal pure returns (int24) {
        int24 c = t / sp;
        if (t < 0 && t % sp != 0) c--;
        return c * sp;
    }
}
