// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {DexV3Factory} from "../src/dexv3/DexV3Factory.sol";
import {DexV3Pool} from "../src/dexv3/DexV3Pool.sol";
import {DexV3Router} from "../src/dexv3/DexV3Router.sol";
import {TickMath} from "../src/dexv3/libraries/TickMath.sol";
import {SqrtPriceMath} from "../src/dexv3/libraries/SqrtPriceMath.sol";
import {TestToken} from "../src/testnet/TestToken.sol";
import {vm} from "./mocks/Vm.sol";

/// @dev External wrapper so reverts in the internal library can be expected.
contract TickMathHarness {
    function sqrtAt(int24 t) external pure returns (uint160) {
        return TickMath.getSqrtRatioAtTick(t);
    }

    function tickAt(uint160 p) external pure returns (int24) {
        return TickMath.getTickAtSqrtRatio(p);
    }
}

contract DexV3Test {
    address constant ALICE = address(0xA11CE); // full-range LP
    address constant CAROL = address(0xCA201); // concentrated LP
    address constant BOB = address(0xB0B); // trader
    uint256 constant Q96 = 0x1000000000000000000000000;

    uint24[5] FEES = [uint24(100), 500, 2500, 3000, 10000];

    struct Pos {
        address owner;
        int24 lower;
        int24 upper;
        uint128 liq;
    }

    Pos[] lps;

    TestToken tokenA;
    TestToken tokenB;
    TestToken tokenC;
    DexV3Factory factory;
    DexV3Router router;
    TickMathHarness tm;

    function setUp() public {
        vm.warp(1_800_000_000);
        tokenA = new TestToken("Token A", "TKA", 18);
        tokenB = new TestToken("Token B", "TKB", 18);
        tokenC = new TestToken("Token C", "TKC", 18);
        factory = new DexV3Factory();
        router = new DexV3Router(factory);
        tm = new TickMathHarness();
        _fundAndApprove(ALICE);
        _fundAndApprove(CAROL);
        _fundAndApprove(BOB);
    }

    // ============================================================== fuzz

    /// @notice V3's "k": inside a tick range the curve is x_v * y_v = L^2, so a swap must leave the in-range
    ///         liquidity equal to exactly the positions covering the current tick, and the pool's real token
    ///         balances must always back every position at the current price (what burn would pay).
    ///         Checked after each of 4 random exact-in / exact-out swaps over a full-range and a concentrated
    ///         position, then every LP exits and must get at least their principal back.
    function testFuzz_SwapNeverDecreasesK_V3(
        uint8 feeIdx,
        int24 tickSeed,
        uint96 narrowLiq,
        uint8 wLo,
        uint8 wHi,
        uint256 seed
    ) public {
        (DexV3Pool pool, int24 base) = _setupFuzzPool(feeIdx, tickSeed);
        _addNarrow(pool, base, wLo, wHi, narrowLiq);

        for (uint256 i; i < 4; ++i) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            _swapAndCheck(pool, seed);
        }
        _exitAllAndCheck(pool);
    }

    /// @notice Swapping X in and the whole output straight back never returns more than X.
    function testFuzz_RoundTripLosesFee_V3(uint8 feeIdx, uint96 amtRaw) public {
        uint24 fee = FEES[feeIdx % 5];
        int24 sp = factory.feeAmountTickSpacing(fee);
        DexV3Pool pool =
            DexV3Pool(router.createAndInitializePoolIfNecessary(address(tokenA), address(tokenB), fee, uint160(Q96)));
        _addPos(pool, ALICE, (TickMath.MIN_TICK / sp) * sp, (TickMath.MAX_TICK / sp) * sp, 1e24);

        uint256 amt = _bound(amtRaw, 1e6, 1e23);
        uint256 out1 = _exactIn(pool, true, amt);
        uint256 back = _exactIn(pool, false, out1);
        require(back < amt, "round trip profit");
    }

    function testFuzz_tickAtSqrtRatioIsFloor(uint160 p) public view {
        p = uint160(_bound(p, TickMath.MIN_SQRT_RATIO, TickMath.MAX_SQRT_RATIO - 1));
        int24 t = tm.tickAt(p);
        require(tm.sqrtAt(t) <= p, "tick too high");
        if (t < TickMath.MAX_TICK) require(tm.sqrtAt(t + 1) > p, "tick too low");
    }

    function testFuzz_sqrtRatioStrictlyIncreasingAndInvertible(int24 t) public view {
        t = int24(_boundInt(t, TickMath.MIN_TICK, TickMath.MAX_TICK - 1));
        uint160 p = tm.sqrtAt(t);
        require(p < tm.sqrtAt(t + 1), "not increasing");
        require(tm.tickAt(p) == t, "not invertible");
    }

    // ============================================================== units

    /// @dev Exact values are floor(sqrt(1.0001^t) * 2^96), computed offline with arbitrary-precision integers.
    function test_tickMathMatchesExactPrices() public view {
        _near(1, 79232123823359799118286999567);
        _near(-1, 79224201403219477170569942573);
        _near(10, 79267784519130042428790663798);
        _near(-10, 79188560314459151373725315959);
        _near(100, 79625275426524748796330556127);
        _near(-100, 78833030112140176575862854578);
        _near(4096, 97234110755111693312479820773);
        _near(-4096, 64556580881331167221767657719);
        _near(50000, 965075977353221155028623082915);
        _near(-50000, 6504256538020985011912221506);
        _near(200000, 1744244129640337381386292603617837);
        _near(-200000, 3598751819609688046946418);
        _near(887272, 1461446703485210103244672773810124308346321380902);
        _near(-887272, 4295128738);
    }

    function test_tickMathBounds() public {
        require(tm.sqrtAt(0) == Q96, "tick 0");
        require(tm.sqrtAt(TickMath.MIN_TICK) == TickMath.MIN_SQRT_RATIO, "min");
        require(tm.sqrtAt(TickMath.MAX_TICK) == TickMath.MAX_SQRT_RATIO, "max");
        require(tm.tickAt(TickMath.MIN_SQRT_RATIO) == TickMath.MIN_TICK, "min tick");
        require(tm.tickAt(TickMath.MAX_SQRT_RATIO - 1) == TickMath.MAX_TICK - 1, "max tick");
        vm.expectRevert(TickMath.TickOutOfRange.selector);
        tm.sqrtAt(TickMath.MAX_TICK + 1);
        vm.expectRevert(TickMath.TickOutOfRange.selector);
        tm.sqrtAt(TickMath.MIN_TICK - 1);
        vm.expectRevert(TickMath.PriceOutOfRange.selector);
        tm.tickAt(TickMath.MAX_SQRT_RATIO);
        vm.expectRevert(TickMath.PriceOutOfRange.selector);
        tm.tickAt(TickMath.MIN_SQRT_RATIO - 1);
    }

    function test_factoryFeeTiersAndDuplicates() public {
        vm.expectRevert(DexV3Factory.FeeNotEnabled.selector);
        factory.createPool(address(tokenA), address(tokenB), 1234);
        address p = factory.createPool(address(tokenB), address(tokenA), 2500);
        require(DexV3Pool(p).tickSpacing() == 50, "spacing");
        require(factory.getPool(address(tokenA), address(tokenB), 2500) == p, "a,b");
        require(factory.getPool(address(tokenB), address(tokenA), 2500) == p, "b,a");
        require(DexV3Pool(p).token0() < DexV3Pool(p).token1(), "sorted");
        vm.expectRevert(DexV3Factory.PoolExists.selector);
        factory.createPool(address(tokenA), address(tokenB), 2500);
        factory.createPool(address(tokenA), address(tokenB), 500); // other tier is a separate pool
        require(factory.allPoolsLength() == 2, "len");
    }

    function test_poolLockedUntilInitializedAndInitOnce() public {
        DexV3Pool pool = DexV3Pool(factory.createPool(address(tokenA), address(tokenB), 3000));
        DexV3Router.AddLiquidityParams memory p = _liqParams(3000, -600, 600, 1e18, ALICE);
        vm.prank(ALICE);
        vm.expectRevert(DexV3Pool.Locked.selector);
        router.addLiquidity(p);

        pool.initialize(uint160(Q96));
        vm.expectRevert(DexV3Pool.AlreadyInitialized.selector);
        pool.initialize(uint160(Q96));
    }

    function test_unspacedOrMisorderedTicksRevert() public {
        router.createAndInitializePoolIfNecessary(address(tokenA), address(tokenB), 2500, uint160(Q96));
        DexV3Router.AddLiquidityParams memory p = _liqParams(2500, -50, 25, 1e18, ALICE);
        vm.prank(ALICE);
        vm.expectRevert(DexV3Pool.TickNotSpaced.selector);
        router.addLiquidity(p);
        p = _liqParams(2500, 50, -50, 1e18, ALICE);
        vm.prank(ALICE);
        vm.expectRevert(DexV3Pool.TicksMisordered.selector);
        router.addLiquidity(p);
    }

    function test_callbacksRejectNonPools() public {
        bytes memory data = abi.encode(address(tokenA), address(tokenB), uint24(3000), ALICE);
        router.createAndInitializePoolIfNecessary(address(tokenA), address(tokenB), 3000, uint160(Q96));
        vm.prank(BOB);
        vm.expectRevert(DexV3Router.NotPool.selector);
        router.dexV3SwapCallback(1e18, 0, data); // would pull ALICE's approved tokens if unchecked
        vm.prank(BOB);
        vm.expectRevert(DexV3Router.NotPool.selector);
        router.dexV3MintCallback(1e18, 1e18, data);
    }

    function test_crossingTicksChangesLiquidityAndPaysRangeFees() public {
        DexV3Pool pool = DexV3Pool(
            router.createAndInitializePoolIfNecessary(address(tokenA), address(tokenB), 3000, uint160(Q96))
        );
        _addPos(pool, ALICE, -887220, 887220, 1e21);
        _addPos(pool, CAROL, 120, 600, 5e21); // entirely above the price: token0 only
        require(pool.liquidity() == 1e21, "start");

        // push the price up into Carol's range (token1 in)
        _swapToTick(pool, false, 300);
        (, int24 t,) = pool.slot0();
        require(t == 300, "at 300");
        require(pool.liquidity() == 6e21, "crossed into range");

        // and back down below it (token0 in)
        _swapToTick(pool, true, -60);
        (, t,) = pool.slot0();
        require(t == -60, "at -60");
        require(pool.liquidity() == 1e21, "crossed out of range");

        // Carol is all token0 again; she earned token1 fees on the way up and token0 fees on the way down
        (uint256 p0, uint256 p1) = _principalNow(pool, lps[1]);
        require(p1 == 0, "below range holds no token1");
        vm.startPrank(CAROL);
        pool.burn(120, 600, 5e21);
        (uint128 c0, uint128 c1) = pool.collect(CAROL, 120, 600, type(uint128).max, type(uint128).max);
        vm.stopPrank();
        require(c1 > 0, "no token1 fees");
        require(c0 > p0, "no token0 fees");
    }

    function test_feesAccrueToFullRangeLp() public {
        DexV3Pool pool = DexV3Pool(
            router.createAndInitializePoolIfNecessary(address(tokenA), address(tokenB), 2500, uint160(Q96))
        );
        _addPos(pool, ALICE, -887250, 887250, 1e24);
        for (uint256 i; i < 5; ++i) {
            _exactIn(pool, true, 1e21);
            _exactIn(pool, false, 1e21);
        }
        vm.startPrank(ALICE);
        pool.burn(-887250, 887250, 0); // poke: credit fees without removing liquidity
        (uint128 c0, uint128 c1) = pool.collect(ALICE, -887250, 887250, type(uint128).max, type(uint128).max);
        vm.stopPrank();
        // 0.25% of 5e21 per side, give or take rounding
        require(c0 > 12.49e18 && c0 < 12.51e18, "token0 fees");
        require(c1 > 12.49e18 && c1 < 12.51e18, "token1 fees");
    }

    function test_multiHopExactInput() public {
        router.createAndInitializePoolIfNecessary(address(tokenA), address(tokenB), 3000, uint160(Q96));
        router.createAndInitializePoolIfNecessary(address(tokenB), address(tokenC), 500, uint160(Q96));
        DexV3Router.AddLiquidityParams memory p = _liqParams(3000, -887220, 887220, 1e24, ALICE);
        vm.prank(ALICE);
        router.addLiquidity(p);
        p = DexV3Router.AddLiquidityParams(
            address(tokenB), address(tokenC), 500, -887270, 887270, 1e24, type(uint256).max, type(uint256).max, ALICE, block.timestamp
        );
        vm.prank(ALICE);
        router.addLiquidity(p);

        address[] memory tokens = new address[](3);
        (tokens[0], tokens[1], tokens[2]) = (address(tokenA), address(tokenB), address(tokenC));
        uint24[] memory fees = new uint24[](2);
        (fees[0], fees[1]) = (3000, 500);
        DexV3Router.ExactInputParams memory ep =
            DexV3Router.ExactInputParams(tokens, fees, BOB, block.timestamp, 1e18, 0);
        uint256 c0 = tokenC.balanceOf(BOB);
        uint256 a0 = tokenA.balanceOf(BOB);
        vm.prank(BOB);
        uint256 out = router.exactInput(ep);
        require(tokenC.balanceOf(BOB) - c0 == out, "out");
        require(a0 - tokenA.balanceOf(BOB) == 1e18, "in");
        // 0.3% + 0.05% fees at price 1 with deep liquidity
        require(out > 0.9964e18 && out < 0.9966e18, "price");
        require(tokenB.balanceOf(address(router)) == 0, "router kept intermediate");
    }

    function test_slippageAndDeadlineRevert() public {
        DexV3Pool pool = DexV3Pool(
            router.createAndInitializePoolIfNecessary(address(tokenA), address(tokenB), 3000, uint160(Q96))
        );
        _addPos(pool, ALICE, -887220, 887220, 1e24);
        (TestToken tIn, TestToken tOut) = (TestToken(pool.token0()), TestToken(pool.token1()));

        DexV3Router.ExactInputSingleParams memory ip =
            DexV3Router.ExactInputSingleParams(address(tIn), address(tOut), 3000, BOB, block.timestamp, 1e18, 1e18, 0);
        vm.prank(BOB);
        vm.expectRevert(DexV3Router.TooLittleReceived.selector);
        router.exactInputSingle(ip);

        ip.amountOutMinimum = 0;
        ip.deadline = block.timestamp - 1;
        vm.prank(BOB);
        vm.expectRevert(DexV3Router.Expired.selector);
        router.exactInputSingle(ip);

        DexV3Router.ExactOutputSingleParams memory op =
            DexV3Router.ExactOutputSingleParams(address(tIn), address(tOut), 3000, BOB, block.timestamp, 1e18, 1e18, 0);
        vm.prank(BOB);
        vm.expectRevert(DexV3Router.TooMuchRequested.selector);
        router.exactOutputSingle(op);
    }

    // ============================================================ helpers

    /// @dev Pool at a fuzzed tick in [-60000, 60000] with Alice's full-range position; returns the spaced tick.
    function _setupFuzzPool(uint8 feeIdx, int24 tickSeed) internal returns (DexV3Pool pool, int24 base) {
        uint24 fee = FEES[feeIdx % 5];
        int24 sp = factory.feeAmountTickSpacing(fee);
        int24 tick0 = int24(_boundInt(tickSeed, -60_000, 60_000));
        pool = DexV3Pool(
            router.createAndInitializePoolIfNecessary(
                address(tokenA), address(tokenB), fee, TickMath.getSqrtRatioAtTick(tick0)
            )
        );
        _addPos(pool, ALICE, (TickMath.MIN_TICK / sp) * sp, (TickMath.MAX_TICK / sp) * sp, 1e24);
        base = _floorTick(tick0, sp);
    }

    /// @dev Carol's concentrated position: 1..50 spacings either side of the price.
    function _addNarrow(DexV3Pool pool, int24 base, uint8 wLo, uint8 wHi, uint96 narrowLiq) internal {
        int24 sp = pool.tickSpacing();
        int24 lo = base - int24(uint24(wLo % 50) + 1) * sp;
        int24 hi = base + int24(uint24(wHi % 50) + 1) * sp;
        _addPos(pool, CAROL, lo, hi, uint128(_bound(narrowLiq, 1e18, 1e24)));
    }

    function _swapAndCheck(DexV3Pool pool, uint256 seed) internal {
        bool zeroForOne = seed & 1 == 0;
        (uint160 pBefore,,) = pool.slot0();
        uint256 fgBefore = zeroForOne ? pool.feeGrowthGlobal0X128() : pool.feeGrowthGlobal1X128();

        if (seed & 2 == 0) _exactIn(pool, zeroForOne, _bound(seed >> 8, 1e3, 1e23));
        else _exactOut(pool, zeroForOne, seed >> 8);

        (uint160 pAfter, int24 tick,) = pool.slot0();
        require(zeroForOne ? pAfter <= pBefore : pAfter >= pBefore, "price moved the wrong way");
        require(
            (zeroForOne ? pool.feeGrowthGlobal0X128() : pool.feeGrowthGlobal1X128()) >= fgBefore, "fee growth fell"
        );
        require(tick == TickMath.getTickAtSqrtRatio(pAfter) || pAfter == TickMath.getSqrtRatioAtTick(tick + 1), "tick");
        _checkLiquidityAndBacking(pool, tick);
    }

    function _exactIn(DexV3Pool pool, bool zeroForOne, uint256 amt) internal returns (uint256 out) {
        (TestToken tIn, TestToken tOut) = _io(pool, zeroForOne);
        DexV3Router.ExactInputSingleParams memory p =
            DexV3Router.ExactInputSingleParams(address(tIn), address(tOut), pool.fee(), BOB, block.timestamp, amt, 0, 0);
        uint256 inBefore = tIn.balanceOf(BOB);
        uint256 outBefore = tOut.balanceOf(BOB);
        vm.prank(BOB);
        out = router.exactInputSingle(p);
        require(tOut.balanceOf(BOB) - outBefore == out, "out != returned");
        require(inBefore - tIn.balanceOf(BOB) <= amt, "paid more than amountIn");
    }

    function _exactOut(DexV3Pool pool, bool zeroForOne, uint256 amtSeed) internal {
        (TestToken tIn, TestToken tOut) = _io(pool, zeroForOne);
        uint256 amt = _bound(amtSeed, 1e3, tOut.balanceOf(address(pool)) / 2);
        DexV3Router.ExactOutputSingleParams memory p = DexV3Router.ExactOutputSingleParams(
            address(tIn), address(tOut), pool.fee(), BOB, block.timestamp, amt, type(uint256).max, 0
        );
        uint256 inBefore = tIn.balanceOf(BOB);
        uint256 outBefore = tOut.balanceOf(BOB);
        vm.prank(BOB);
        uint256 paid = router.exactOutputSingle(p);
        require(tOut.balanceOf(BOB) - outBefore == amt, "exact output not delivered");
        require(inBefore - tIn.balanceOf(BOB) == paid, "paid != returned");
    }

    function _swapToTick(DexV3Pool pool, bool zeroForOne, int24 tick) internal {
        (TestToken tIn, TestToken tOut) = _io(pool, zeroForOne);
        DexV3Router.ExactInputSingleParams memory p = DexV3Router.ExactInputSingleParams(
            address(tIn), address(tOut), pool.fee(), BOB, block.timestamp, 1e30, 0, TickMath.getSqrtRatioAtTick(tick)
        );
        vm.prank(BOB);
        router.exactInputSingle(p);
    }

    /// @dev In-range liquidity == sum of positions covering the tick, and balances cover all principal.
    function _checkLiquidityAndBacking(DexV3Pool pool, int24 tick) internal view {
        uint128 active;
        uint256 owe0;
        uint256 owe1;
        for (uint256 i; i < lps.length; ++i) {
            Pos memory q = lps[i];
            if (q.lower <= tick && tick < q.upper) active += q.liq;
            (uint256 a0, uint256 a1) = _principalNow(pool, q);
            owe0 += a0;
            owe1 += a1;
        }
        require(pool.liquidity() == active, "in-range liquidity != positions");
        require(TestToken(pool.token0()).balanceOf(address(pool)) >= owe0, "token0 under-backed");
        require(TestToken(pool.token1()).balanceOf(address(pool)) >= owe1, "token1 under-backed");
    }

    function _exitAllAndCheck(DexV3Pool pool) internal {
        for (uint256 i; i < lps.length; ++i) {
            Pos memory q = lps[i];
            (uint256 a0, uint256 a1) = _principalNow(pool, q);
            vm.startPrank(q.owner);
            pool.burn(q.lower, q.upper, q.liq);
            (uint128 c0, uint128 c1) = pool.collect(q.owner, q.lower, q.upper, type(uint128).max, type(uint128).max);
            vm.stopPrank();
            require(c0 >= a0 && c1 >= a1, "LP got less than principal");
        }
        require(pool.liquidity() == 0, "liquidity left");
    }

    /// @dev What burn() would pay for the position at the current price (same branches, rounded down).
    function _principalNow(DexV3Pool pool, Pos memory q) internal view returns (uint256 a0, uint256 a1) {
        (uint160 sqrtP, int24 tick,) = pool.slot0();
        uint160 sa = TickMath.getSqrtRatioAtTick(q.lower);
        uint160 sb = TickMath.getSqrtRatioAtTick(q.upper);
        if (tick < q.lower) {
            a0 = SqrtPriceMath.getAmount0Delta(sa, sb, q.liq, false);
        } else if (tick < q.upper) {
            a0 = SqrtPriceMath.getAmount0Delta(sqrtP, sb, q.liq, false);
            a1 = SqrtPriceMath.getAmount1Delta(sa, sqrtP, q.liq, false);
        } else {
            a1 = SqrtPriceMath.getAmount1Delta(sa, sb, q.liq, false);
        }
    }

    function _addPos(DexV3Pool pool, address owner, int24 lo, int24 hi, uint128 liq) internal {
        DexV3Router.AddLiquidityParams memory p = _liqParams(pool.fee(), lo, hi, liq, owner);
        vm.prank(owner);
        router.addLiquidity(p);
        lps.push(Pos(owner, lo, hi, liq));
    }

    function _liqParams(uint24 fee, int24 lo, int24 hi, uint128 liq, address owner)
        internal
        view
        returns (DexV3Router.AddLiquidityParams memory)
    {
        return DexV3Router.AddLiquidityParams(
            address(tokenA), address(tokenB), fee, lo, hi, liq, type(uint256).max, type(uint256).max, owner, block.timestamp
        );
    }

    function _io(DexV3Pool pool, bool zeroForOne) internal view returns (TestToken, TestToken) {
        (address t0, address t1) = (pool.token0(), pool.token1());
        return zeroForOne ? (TestToken(t0), TestToken(t1)) : (TestToken(t1), TestToken(t0));
    }

    function _fundAndApprove(address who) internal {
        TestToken[3] memory ts = [tokenA, tokenB, tokenC];
        for (uint256 i; i < 3; ++i) {
            ts[i].mint(who, 1e36);
            vm.prank(who);
            ts[i].approve(address(router), type(uint256).max);
        }
    }

    function _near(int24 t, uint256 exact) internal view {
        uint256 got = tm.sqrtAt(t);
        uint256 diff = got > exact ? got - exact : exact - got;
        require(diff <= exact / 1e18 + 1, "sqrt price off");
    }

    function _floorTick(int24 t, int24 sp) internal pure returns (int24) {
        int24 c = t / sp;
        if (t < 0 && t % sp != 0) c--;
        return c * sp;
    }

    function _bound(uint256 x, uint256 lo, uint256 hi) internal pure returns (uint256) {
        return lo + (x % (hi - lo + 1));
    }

    function _boundInt(int256 x, int256 lo, int256 hi) internal pure returns (int256) {
        return lo + int256(uint256(x) % uint256(hi - lo + 1));
    }
}
