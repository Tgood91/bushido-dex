// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {FixedPointMathLib as FPM} from "solady/utils/FixedPointMathLib.sol";
import {IPriceOracle, IChainlinkFeed} from "../../src/oracle/UniV3ChainlinkOracle.sol";
import {ChainlinkFeedOracle} from "../../src/oracle/ChainlinkFeedOracle.sol";
import {DexFactory} from "../../src/dex/DexFactory.sol";
import {DexRouter} from "../../src/dex/DexRouter.sol";
import {DexPair} from "../../src/dex/DexPair.sol";
import {DexV3Factory} from "../../src/dexv3/DexV3Factory.sol";
import {DexV3Router} from "../../src/dexv3/DexV3Router.sol";
import {DexV3Pool} from "../../src/dexv3/DexV3Pool.sol";
import {TickMath} from "../../src/dexv3/libraries/TickMath.sol";
import {SqrtPriceMath} from "../../src/dexv3/libraries/SqrtPriceMath.sol";
import {DexSeed} from "../../script/DexSeed.sol";
import {vm} from "../mocks/Vm.sol";

interface IERC20Real {
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address who) external view returns (uint256);
}

interface IWETH9 is IERC20Real {
    function deposit() external payable;
}

interface IUniswapV3PoolReal {
    function swap(address recipient, bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96, bytes calldata data)
        external
        returns (int256, int256);
    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool);
}

/// @dev Exposes the deploy scripts' market setup so its mainnet rules can be tested on a real fork.
contract DexSeedHarness is DexSeed {
    function prepare(Market memory m) external returns (Market memory) {
        _prepareMarket(m);
        return m;
    }
}

/// @notice Both DEXes on a fork of REAL Base mainnet with no mocks: real WETH, real USDC (bought through the real
///         Uniswap v3 WETH/USDC 0.05% pool), the real Chainlink ETH/USD feed. Runs only when BASE_RPC_URL is set:
///         BASE_RPC_URL=https://mainnet.base.org forge test --match-path 'test/fork/*'
contract DexForkTest {
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant UNI_POOL_005 = 0xd0b53D9277642d899DF5C87A3966A349A798F224; // Uniswap v3 WETH/USDC 0.05%
    address constant CL_ETH_USD = 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70; // Chainlink ETH/USD
    uint256 constant Q96 = 0x1000000000000000000000000;

    struct Pos {
        int24 lower;
        int24 upper;
        uint128 liq;
    }

    Pos[] positions;
    uint256 px; // live Chainlink USDC per WETH (6 dp)

    event Price(string source, uint256 usdcPerWeth);

    /// @dev Forks Base, wraps real ETH into WETH and buys real USDC on Uniswap. False when no RPC is configured.
    function _setup() internal returns (bool) {
        string memory url = vm.envOr("BASE_RPC_URL", string(""));
        if (bytes(url).length == 0) return false;
        vm.createSelectFork(url);
        require(block.chainid == 8453, "not Base");

        (px,) = new ChainlinkFeedOracle(IChainlinkFeed(CL_ETH_USD), 3600).price();
        emit Price("chainlink ETH/USD", px);

        vm.deal(address(this), 400 ether);
        IWETH9(WETH).deposit{value: 400 ether}();
        IUniswapV3PoolReal(UNI_POOL_005).swap(address(this), true, int256(150 ether), TickMath.MIN_SQRT_RATIO + 1, "");
        require(IERC20Real(USDC).balanceOf(address(this)) > 150 * px * 95 / 100, "bought too little USDC");
        return true;
    }

    /// @dev Pays the real Uniswap pool for the USDC bought in _setup.
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external {
        require(msg.sender == UNI_POOL_005, "not the Uniswap pool");
        if (amount0Delta > 0) IERC20Real(WETH).transfer(msg.sender, uint256(amount0Delta));
        if (amount1Delta > 0) IERC20Real(USDC).transfer(msg.sender, uint256(amount1Delta));
    }

    // ================================================================= V2

    /// @notice A V2 pair of real WETH/USDC seeded at the live Chainlink price: k strictly grows on every swap,
    ///         each output equals the router quote, and reserves always equal real balances.
    function testFork_V2RealWethUsdcSwapNeverDecreasesK() public {
        if (!_setup()) return;
        DexFactory factory = new DexFactory();
        DexRouter router = new DexRouter(factory);
        IERC20Real(WETH).approve(address(router), type(uint256).max);
        IERC20Real(USDC).approve(address(router), type(uint256).max);

        uint256 seedW = 50 ether;
        uint256 seedU = (seedW * px) / 1e18;
        router.addLiquidity(WETH, USDC, seedW, seedU, seedW, seedU, address(this), block.timestamp);
        DexPair pair = DexPair(factory.getPair(WETH, USDC));
        require(pair.token0() == WETH, "WETH sorts first on Base");

        // a tiny trade fills at the live price minus the 0.25% fee
        uint256 out = _v2Swap(router, pair, true, 0.01 ether);
        uint256 fair = (0.01 ether * px / 1e18) * 9975 / 10_000;
        require(out <= fair && out * 1000 >= fair * 999, "tiny trade off the live price");

        _v2Swap(router, pair, true, 2 ether);
        _v2Swap(router, pair, false, 50e6);
        _v2Swap(router, pair, true, 10 ether);
        _v2Swap(router, pair, false, 40_000e6);
        _v2Swap(router, pair, false, 1e6);
    }

    function _v2Swap(DexRouter router, DexPair pair, bool wethIn, uint256 amountIn) internal returns (uint256 out) {
        (uint112 r0, uint112 r1,) = pair.getReserves();
        uint256 kBefore = uint256(r0) * r1;
        address[] memory path = new address[](2);
        (path[0], path[1]) = wethIn ? (WETH, USDC) : (USDC, WETH);
        uint256 quoted = router.getAmountsOut(amountIn, path)[1];
        uint256 before = IERC20Real(path[1]).balanceOf(address(this));

        router.swapExactTokensForTokens(amountIn, quoted, path, address(this), block.timestamp);

        out = IERC20Real(path[1]).balanceOf(address(this)) - before;
        (r0, r1,) = pair.getReserves();
        require(uint256(r0) * r1 > kBefore, "k did not grow");
        require(out == quoted, "out != quote");
        require(IERC20Real(WETH).balanceOf(address(pair)) == r0, "WETH reserve drift");
        require(IERC20Real(USDC).balanceOf(address(pair)) == r1, "USDC reserve drift");
    }

    // ================================================================= V3

    /// @notice A V3 pool of real WETH/USDC initialized at the live Chainlink price (checked against Uniswap's own
    ///         WETH/USDC pool), with a full-range and a +/-~10% position. After every swap the in-range liquidity is
    ///         exactly the positions covering the tick and real balances back every position; then both exit with
    ///         at least their principal.
    function testFork_V3RealWethUsdcSwapNeverDecreasesK() public {
        if (!_setup()) return;
        DexV3Factory factory = new DexV3Factory();
        DexV3Router router = new DexV3Router(factory);
        IERC20Real(WETH).approve(address(router), type(uint256).max);
        IERC20Real(USDC).approve(address(router), type(uint256).max);

        uint160 sqrtP = uint160(FPM.sqrt(FPM.fullMulDiv(px, 1 << 192, 1e18)));
        (uint160 uniSqrtP,,,,,,) = IUniswapV3PoolReal(UNI_POOL_005).slot0();
        uint256 gap = sqrtP > uniSqrtP ? sqrtP - uniSqrtP : uniSqrtP - sqrtP;
        require(gap * 100 <= uniSqrtP, "Chainlink and Uniswap disagree by more than ~2%");

        DexV3Pool pool = DexV3Pool(router.createAndInitializePoolIfNecessary(WETH, USDC, 2500, sqrtP));
        require(pool.token0() == WETH, "WETH sorts first on Base");
        (, int24 tick,) = pool.slot0();
        int24 sp = pool.tickSpacing();
        _addPos(router, sqrtP, (TickMath.MIN_TICK / sp) * sp, (TickMath.MAX_TICK / sp) * sp);
        _addPos(router, sqrtP, _floor(tick - 1000, sp), _floor(tick + 1000, sp) + sp);

        _v3Swap(router, pool, true, 0.01 ether);
        _v3Swap(router, pool, true, 10 ether);
        _v3Swap(router, pool, false, 50e6);
        _v3Swap(router, pool, false, 60_000e6);
        _v3Swap(router, pool, true, 3 ether);

        _exitAll(pool);
    }

    function _addPos(DexV3Router router, uint160 sqrtP, int24 lo, int24 hi) internal {
        uint128 liq = _liquidityFor(sqrtP, lo, hi, 20 ether, (20 ether * px) / 1e18);
        router.addLiquidity(
            DexV3Router.AddLiquidityParams(
                WETH, USDC, 2500, lo, hi, liq, type(uint256).max, type(uint256).max, address(this), block.timestamp
            )
        );
        positions.push(Pos(lo, hi, liq));
    }

    function _v3Swap(DexV3Router router, DexV3Pool pool, bool wethIn, uint256 amountIn) internal {
        (uint160 before,,) = pool.slot0();
        (address tIn, address tOut) = wethIn ? (WETH, USDC) : (USDC, WETH);
        uint256 outBefore = IERC20Real(tOut).balanceOf(address(this));
        uint256 out = router.exactInputSingle(
            DexV3Router.ExactInputSingleParams(tIn, tOut, 2500, address(this), block.timestamp, amountIn, 0, 0)
        );
        require(IERC20Real(tOut).balanceOf(address(this)) - outBefore == out, "out != returned");
        (uint160 afterP, int24 tick,) = pool.slot0();
        require(wethIn ? afterP <= before : afterP >= before, "price moved the wrong way");
        _checkLiquidityAndBacking(pool, tick);
    }

    function _checkLiquidityAndBacking(DexV3Pool pool, int24 tick) internal view {
        uint128 active;
        uint256 owe0;
        uint256 owe1;
        for (uint256 i; i < positions.length; ++i) {
            Pos memory q = positions[i];
            if (q.lower <= tick && tick < q.upper) active += q.liq;
            (uint256 a0, uint256 a1) = _principalNow(pool, q);
            owe0 += a0;
            owe1 += a1;
        }
        require(pool.liquidity() == active, "in-range liquidity != positions");
        require(IERC20Real(WETH).balanceOf(address(pool)) >= owe0, "WETH under-backed");
        require(IERC20Real(USDC).balanceOf(address(pool)) >= owe1, "USDC under-backed");
    }

    function _exitAll(DexV3Pool pool) internal {
        for (uint256 i; i < positions.length; ++i) {
            Pos memory q = positions[i];
            (uint256 a0, uint256 a1) = _principalNow(pool, q);
            pool.burn(q.lower, q.upper, q.liq);
            (uint128 c0, uint128 c1) = pool.collect(address(this), q.lower, q.upper, type(uint128).max, type(uint128).max);
            require(c0 >= a0 && c1 >= a1, "LP got less than principal");
        }
        require(pool.liquidity() == 0, "liquidity left");
    }

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

    function _liquidityFor(uint160 sqrtP, int24 lo, int24 hi, uint256 amt0, uint256 amt1) internal pure returns (uint128) {
        uint160 sA = TickMath.getSqrtRatioAtTick(lo);
        uint160 sB = TickMath.getSqrtRatioAtTick(hi);
        uint256 l0 = FPM.fullMulDiv(amt0, FPM.fullMulDiv(sqrtP, sB, Q96), sB - sqrtP);
        uint256 l1 = FPM.fullMulDiv(amt1, Q96, sqrtP - sA);
        return uint128(l0 < l1 ? l0 : l1);
    }

    function _floor(int24 t, int24 sp) internal pure returns (int24) {
        int24 c = t / sp;
        if (t < 0 && t % sp != 0) c--;
        return c * sp;
    }

    // ================================================== deploy scripts on mainnet

    /// @notice On Base mainnet the deploy scripts never deploy mock tokens in place of real ones.
    function testFork_seedRefusesMockTokensOnMainnet() public {
        if (!_setup()) return;
        DexSeedHarness h = new DexSeedHarness();
        DexSeed.Market memory m;
        m.deployer = address(this);
        m.oracle = IPriceOracle(address(new ChainlinkFeedOracle(IChainlinkFeed(CL_ETH_USD), 3600)));
        m.seedToken = 1 ether;
        vm.expectRevert(abi.encodeWithSelector(DexSeed.MocksNotAllowed.selector, uint256(8453)));
        h.prepare(m);
    }

    /// @notice On Base mainnet the deploy scripts never mint: a deployer short of real WETH is refused.
    function testFork_seedNeverMintsRealTokens() public {
        if (!_setup()) return;
        DexSeedHarness h = new DexSeedHarness();
        DexSeed.Market memory m;
        m.deployer = address(uint160(uint256(keccak256("bushido empty deployer"))));
        m.token = WETH;
        m.usdc = USDC;
        m.oracle = IPriceOracle(address(new ChainlinkFeedOracle(IChainlinkFeed(CL_ETH_USD), 3600)));
        m.seedToken = 1 ether;
        vm.expectRevert(abi.encodeWithSelector(DexSeed.InsufficientBalance.selector, WETH, uint256(0), uint256(1 ether)));
        h.prepare(m);
    }

    /// @notice With real WETH/USDC already held, the setup uses them as they are at the live price.
    function testFork_seedUsesRealTokensWhenFunded() public {
        if (!_setup()) return;
        DexSeedHarness h = new DexSeedHarness();
        DexSeed.Market memory m;
        m.deployer = address(this);
        m.token = WETH;
        m.usdc = USDC;
        m.oracle = IPriceOracle(address(new ChainlinkFeedOracle(IChainlinkFeed(CL_ETH_USD), 3600)));
        m.seedToken = 1 ether;
        m = h.prepare(m);
        require(m.token == WETH && m.usdc == USDC, "swapped in other tokens");
        require(m.px == px && m.seedUsdc == px, "not the live price");
    }
}
