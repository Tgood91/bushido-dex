// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {DexFactory} from "../src/dex/DexFactory.sol";
import {DexRouter} from "../src/dex/DexRouter.sol";
import {DexPair} from "../src/dex/DexPair.sol";
import {DexSeed, ITestToken} from "./DexSeed.sol";
import {vm} from "../test/mocks/Vm.sol";

/// @notice Deploys the V2-style DEX (DexFactory + DexRouter) and seeds a <token>/tUSDC pair at the live
///         oracle price. Env: see DexSeed. Testnets only (ALLOW_FORK=1 for an anvil mainnet fork).
///
///   Base Sepolia (simulate, then add --account <name> --broadcast):
///     DEPLOYER=<addr> FEED=0x4aDC67696bA383F43DD60A9e78F2C97Fbbfc7cb1 USDC=<tUSDC> \
///       forge script script/DeployDexV2.s.sol:DeployDexV2 --rpc-url https://sepolia.base.org
///   Arbitrum Sepolia: FEED=0xd30e2101a97dcbAeBCBC04F14C3f624E67A35165, --rpc-url https://sepolia-rollup.arbitrum.io/rpc
contract DeployDexV2 is DexSeed {
    error PairOffPrice(uint256 pairPx, uint256 oraclePx);

    function run() external returns (DexFactory factory, DexRouter router, address pair, Market memory m) {
        m = _readEnv();

        vm.startBroadcast(m.deployer);
        _prepareMarket(m);
        factory = new DexFactory();
        router = new DexRouter(factory);
        ITestToken(m.token).approve(address(router), m.seedToken);
        ITestToken(m.usdc).approve(address(router), m.seedUsdc);
        router.addLiquidity(
            m.token, m.usdc, m.seedToken, m.seedUsdc, m.seedToken, m.seedUsdc, m.deployer, block.timestamp + 1 hours
        );
        vm.stopBroadcast();

        pair = factory.getPair(m.token, m.usdc);
        _checkPrice(DexPair(pair), m);
    }

    /// @dev The pair's spot price must match the oracle to within 0.01% (rounding of the tUSDC side).
    function _checkPrice(DexPair pair, Market memory m) internal view {
        (uint112 r0, uint112 r1,) = pair.getReserves();
        (uint256 rToken, uint256 rUsdc) = pair.token0() == m.token ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
        uint256 pairPx = (rUsdc * 1e18) / rToken;
        uint256 diff = pairPx > m.px ? pairPx - m.px : m.px - pairPx;
        if (diff * 10_000 > m.px) revert PairOffPrice(pairPx, m.px);
    }
}
