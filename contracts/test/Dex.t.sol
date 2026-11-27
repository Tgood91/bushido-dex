// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {DexFactory} from "../src/dex/DexFactory.sol";
import {DexPair} from "../src/dex/DexPair.sol";
import {DexRouter} from "../src/dex/DexRouter.sol";
import {TestToken} from "../src/testnet/TestToken.sol";
import {vm} from "./mocks/Vm.sol";

contract DexTest {
    address constant ALICE = address(0xA11CE);
    address constant BOB = address(0xB0B);

    TestToken tokenA;
    TestToken tokenB;
    TestToken tokenC;
    DexFactory factory;
    DexRouter router;

    function setUp() public {
        vm.warp(1_800_000_000);
        tokenA = new TestToken("Token A", "TKA", 18);
        tokenB = new TestToken("Token B", "TKB", 18);
        tokenC = new TestToken("Token C", "TKC", 18);
        factory = new DexFactory();
        router = new DexRouter(factory);
        _fundAndApprove(ALICE);
        _fundAndApprove(BOB);
    }

    // ================================================================ fuzz

    /// @notice After any swap, k must not decrease. With the fee kept in the pool, raw k strictly increases.
    function testFuzz_SwapNeverDecreasesK(uint96 amountInRaw, uint96 resA, uint96 resB, uint256 seed) public {
        uint256 rA = _bound(resA, 1_000 ether, 10_000_000 ether);
        uint256 rB = _bound(resB, 1_000 ether, 10_000_000 ether);
        _addLiquidity(ALICE, address(tokenA), address(tokenB), rA, rB);
        DexPair pair = DexPair(factory.getPair(address(tokenA), address(tokenB)));

        for (uint256 i; i < 3; ++i) {
            seed = uint256(keccak256(abi.encode(seed, amountInRaw, i)));
            bool aToB = seed & 1 == 0; // direction fuzzed on its own, not tied to the amount
            _swapAndCheckK(pair, aToB, _bound(uint96(seed >> 8), 1 ether / 1000, 50_000 ether));
        }
    }

    function _swapAndCheckK(DexPair pair, bool aToB, uint256 amountIn) internal {
        uint256 kBefore = _k(pair);
        address[] memory path = aToB ? _path(address(tokenA), address(tokenB)) : _path(address(tokenB), address(tokenA));
        uint256 expectedOut = router.getAmountsOut(amountIn, path)[1];
        uint256 bobOutBefore = TestToken(path[1]).balanceOf(BOB);

        vm.prank(BOB);
        router.swapExactTokensForTokens(amountIn, 0, path, BOB, block.timestamp + 1 hours);

        uint256 kAfter = _k(pair);
        require(kAfter >= kBefore, "k decreased");
        require(kAfter > kBefore, "fee did not grow k");
        require(TestToken(path[1]).balanceOf(BOB) - bobOutBefore == expectedOut, "out != quote");
        // reserves track balances exactly after every swap
        (uint112 r0, uint112 r1,) = pair.getReserves();
        require(TestToken(pair.token0()).balanceOf(address(pair)) == r0, "reserve0 drift");
        require(TestToken(pair.token1()).balanceOf(address(pair)) == r1, "reserve1 drift");
    }

    /// @notice Asking the pair for even 1 wei more than the router quote must fail the k check.
    function testFuzz_OverdrawRevertsK(uint96 amountInRaw) public {
        uint256 amountIn = _bound(amountInRaw, 1 ether / 1000, 50_000 ether);
        _addLiquidity(ALICE, address(tokenA), address(tokenB), 100_000 ether, 200_000 ether);
        DexPair pair = DexPair(factory.getPair(address(tokenA), address(tokenB)));
        uint256 out = router.getAmountsOut(amountIn, _path(address(tokenA), address(tokenB)))[1];
        (uint256 o0, uint256 o1) = pair.token0() == address(tokenA) ? (uint256(0), out + 1) : (out + 1, uint256(0));

        vm.prank(BOB);
        tokenA.transfer(address(pair), amountIn);
        vm.expectRevert(DexPair.K.selector);
        pair.swap(o0, o1, BOB);
    }

    // ================================================================ units

    function test_firstMintLocksMinimumLiquidity() public {
        (,, uint256 liq) = _addLiquidity(ALICE, address(tokenA), address(tokenB), 100 ether, 400 ether);
        DexPair pair = DexPair(factory.getPair(address(tokenA), address(tokenB)));
        require(liq == 200 ether - 1000, "liquidity");
        require(pair.balanceOf(address(0xdead)) == 1000, "locked");
        require(pair.totalSupply() == 200 ether, "supply");
    }

    function test_factoryPairIsSymmetricAndUnique() public {
        address p = factory.createPair(address(tokenB), address(tokenA));
        require(factory.getPair(address(tokenA), address(tokenB)) == p, "a,b");
        require(factory.getPair(address(tokenB), address(tokenA)) == p, "b,a");
        require(factory.allPairsLength() == 1, "len");
        vm.expectRevert(DexFactory.PairExists.selector);
        factory.createPair(address(tokenA), address(tokenB));
        vm.expectRevert(DexFactory.IdenticalAddresses.selector);
        factory.createPair(address(tokenA), address(tokenA));
    }

    function test_initializeOnlyFactory() public {
        DexPair pair = DexPair(factory.createPair(address(tokenA), address(tokenB)));
        vm.expectRevert(DexPair.Forbidden.selector);
        pair.initialize(address(tokenA), address(tokenC));
    }

    function test_feesAccrueToLps() public {
        (,, uint256 liq) = _addLiquidity(ALICE, address(tokenA), address(tokenB), 100_000 ether, 100_000 ether);
        for (uint256 i; i < 10; ++i) {
            vm.startPrank(BOB);
            router.swapExactTokensForTokens(5_000 ether, 0, _path(address(tokenA), address(tokenB)), BOB, block.timestamp);
            router.swapExactTokensForTokens(5_000 ether, 0, _path(address(tokenB), address(tokenA)), BOB, block.timestamp);
            vm.stopPrank();
        }
        address pair = factory.getPair(address(tokenA), address(tokenB));
        uint256 a0 = tokenA.balanceOf(ALICE);
        uint256 b0 = tokenB.balanceOf(ALICE);
        vm.startPrank(ALICE);
        DexPair(pair).approve(address(router), liq);
        router.removeLiquidity(address(tokenA), address(tokenB), liq, 0, 0, ALICE, block.timestamp);
        vm.stopPrank();
        uint256 gotA = tokenA.balanceOf(ALICE) - a0;
        uint256 gotB = tokenB.balanceOf(ALICE) - b0;
        // sqrt(k) per LP share grew: what Alice withdraws has a bigger product than her shares squared
        require(gotA * gotB > liq * liq, "no fee growth");
    }

    function test_addLiquidityUsesPoolRatio() public {
        _addLiquidity(ALICE, address(tokenA), address(tokenB), 100 ether, 200 ether);
        (uint256 a, uint256 b,) = _addLiquidity(BOB, address(tokenA), address(tokenB), 10 ether, 50 ether);
        require(a == 10 ether && b == 20 ether, "ratio");
    }

    function test_multiHopGrowsKOnBothPairs() public {
        _addLiquidity(ALICE, address(tokenA), address(tokenB), 100_000 ether, 100_000 ether);
        _addLiquidity(ALICE, address(tokenB), address(tokenC), 100_000 ether, 100_000 ether);
        DexPair ab = DexPair(factory.getPair(address(tokenA), address(tokenB)));
        DexPair bc = DexPair(factory.getPair(address(tokenB), address(tokenC)));
        uint256 kab = _k(ab);
        uint256 kbc = _k(bc);

        address[] memory path = new address[](3);
        (path[0], path[1], path[2]) = (address(tokenA), address(tokenB), address(tokenC));
        uint256 expected = router.getAmountsOut(1_000 ether, path)[2];
        uint256 c0 = tokenC.balanceOf(BOB);
        vm.prank(BOB);
        router.swapExactTokensForTokens(1_000 ether, expected, path, BOB, block.timestamp);
        require(tokenC.balanceOf(BOB) - c0 == expected, "out");
        require(_k(ab) > kab && _k(bc) > kbc, "k");
    }

    function test_slippageAndDeadlineRevert() public {
        _addLiquidity(ALICE, address(tokenA), address(tokenB), 1_000 ether, 1_000 ether);
        address[] memory path = _path(address(tokenA), address(tokenB));
        uint256 out = router.getAmountsOut(1 ether, path)[1];
        vm.startPrank(BOB);
        vm.expectRevert(DexRouter.InsufficientOutputAmount.selector);
        router.swapExactTokensForTokens(1 ether, out + 1, path, BOB, block.timestamp);
        vm.expectRevert(DexRouter.Expired.selector);
        router.swapExactTokensForTokens(1 ether, 0, path, BOB, block.timestamp - 1);
        vm.stopPrank();
    }

    function test_skimAndSync() public {
        _addLiquidity(ALICE, address(tokenA), address(tokenB), 1_000 ether, 1_000 ether);
        DexPair pair = DexPair(factory.getPair(address(tokenA), address(tokenB)));
        tokenA.mint(address(pair), 5 ether);
        uint256 before = tokenA.balanceOf(BOB);
        pair.skim(BOB);
        require(tokenA.balanceOf(BOB) - before == 5 ether, "skim");

        tokenB.mint(address(pair), 7 ether);
        pair.sync();
        (uint112 r0, uint112 r1,) = pair.getReserves();
        uint256 rB = pair.token0() == address(tokenB) ? r0 : r1;
        require(rB == 1_007 ether, "sync");
    }

    function test_swapNeedsInput() public {
        _addLiquidity(ALICE, address(tokenA), address(tokenB), 1_000 ether, 1_000 ether);
        DexPair pair = DexPair(factory.getPair(address(tokenA), address(tokenB)));
        vm.expectRevert(DexPair.InsufficientInputAmount.selector);
        pair.swap(1 ether, 0, BOB);
    }

    // ============================================================== helpers

    function _fundAndApprove(address who) internal {
        TestToken[3] memory ts = [tokenA, tokenB, tokenC];
        for (uint256 i; i < 3; ++i) {
            ts[i].mint(who, 100_000_000 ether);
            vm.prank(who);
            ts[i].approve(address(router), type(uint256).max);
        }
    }

    function _addLiquidity(address who, address a, address b, uint256 amtA, uint256 amtB)
        internal
        returns (uint256, uint256, uint256)
    {
        vm.prank(who);
        return router.addLiquidity(a, b, amtA, amtB, 0, 0, who, block.timestamp);
    }

    function _path(address a, address b) internal pure returns (address[] memory p) {
        p = new address[](2);
        (p[0], p[1]) = (a, b);
    }

    function _k(DexPair p) internal view returns (uint256) {
        (uint112 r0, uint112 r1,) = p.getReserves();
        return uint256(r0) * r1;
    }

    function _bound(uint256 x, uint256 lo, uint256 hi) internal pure returns (uint256) {
        return lo + (x % (hi - lo + 1));
    }
}
