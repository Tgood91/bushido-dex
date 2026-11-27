// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPriceOracle, IChainlinkFeed} from "../src/oracle/UniV3ChainlinkOracle.sol";
import {ChainlinkFeedOracle} from "../src/oracle/ChainlinkFeedOracle.sol";
import {TestToken} from "../src/testnet/TestToken.sol";
import {MockUSDC} from "../test/mocks/MockUSDC.sol";
import {vm} from "../test/mocks/Vm.sol";

interface ITestToken {
    function mint(address to, uint256 amount) external;
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address who) external view returns (uint256);
    function decimals() external view returns (uint8);
}

/// @notice Shared setup for the DEX deploy scripts: a test token / tUSDC market seeded at the LIVE price.
///         The price always comes from an onchain oracle (never a hard-coded number):
///           ORACLE  an existing IPriceOracle (ChainlinkFeedOracle on testnets, UniV3ChainlinkOracle on forks), or
///           FEED    the chain's Chainlink <ASSET>/USD feed (testnet/chains.json); a ChainlinkFeedOracle is deployed
///                   with MAX_STALENESS (default 3600 s; use the chain's market.maxStaleness).
///         Other env:
///           DEPLOYER      signer address (use --account / --ledger, or --unlocked on anvil; never a raw key in env)
///           TOKEN, USDC   existing test tokens (18 and 6 decimals); unset = deploy TestToken / MockUSDC
///           TOKEN_NAME, TOKEN_SYMBOL   for a new test token (default "Bushido Test ETH" / "tETH")
///           SEED_TOKENS   whole test tokens to seed (default 100); the tUSDC side is sized from the price
///           ALLOW_FORK=1  also run on a mainnet chain id (anvil forks keep the forked chain id)
///         On a testnet, seeding mints the shortfall to DEPLOYER, so TOKEN/USDC must be mintable test tokens.
///         On any other chain there are NO mocks: TOKEN and USDC must be the real tokens (e.g. Base WETH
///         0x4200000000000000000000000000000000000006, USDC 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913), nothing is
///         deployed or minted in their place, and DEPLOYER must already hold the whole seed.
abstract contract DexSeed {
    struct Market {
        address deployer;
        address token; // 18 dp test asset (tETH, tAVAX, ...)
        address usdc; // 6 dp tUSDC
        IPriceOracle oracle;
        uint256 px; // USDC base units per 1 whole token
        uint256 seedToken;
        uint256 seedUsdc;
    }

    error NotATestnet(uint256 chainId);
    error NoPriceSource();
    error BadDecimals(address token);
    error ZeroPrice();
    error MocksNotAllowed(uint256 chainId);
    error NotAContract(address token);
    error InsufficientBalance(address token, uint256 balance, uint256 needed);

    /// @dev Reads env and refuses mainnets. Call before startBroadcast.
    function _readEnv() internal returns (Market memory m) {
        _requireTestnet();
        m.deployer = vm.envAddress("DEPLOYER");
        m.token = vm.envOr("TOKEN", address(0));
        m.usdc = vm.envOr("USDC", address(0));
        m.oracle = IPriceOracle(vm.envOr("ORACLE", address(0)));
        m.seedToken = vm.envOr("SEED_TOKENS", uint256(100)) * 1e18;
    }

    /// @dev Deploys whatever is missing (oracle, tokens), reads the live price and funds the deployer.
    ///      Call inside startBroadcast.
    function _prepareMarket(Market memory m) internal {
        if (address(m.oracle) == address(0)) {
            address feed = vm.envOr("FEED", address(0));
            if (feed == address(0)) revert NoPriceSource();
            m.oracle = new ChainlinkFeedOracle(IChainlinkFeed(feed), vm.envOr("MAX_STALENESS", uint256(3600)));
        }
        (m.px,) = m.oracle.price(); // reverts if the feed is stale or bad
        if (m.px == 0) revert ZeroPrice();

        bool testnet = _isTestnet();
        if (m.token == address(0) || m.usdc == address(0)) {
            // mock tokens exist only on testnets: never stand them in for real assets
            if (!testnet) revert MocksNotAllowed(block.chainid);
            if (m.token == address(0)) {
                m.token = address(
                    new TestToken(
                        vm.envOr("TOKEN_NAME", string("Bushido Test ETH")), vm.envOr("TOKEN_SYMBOL", string("tETH")), 18
                    )
                );
            }
            if (m.usdc == address(0)) m.usdc = address(new MockUSDC());
        }
        if (m.token.code.length == 0) revert NotAContract(m.token);
        if (m.usdc.code.length == 0) revert NotAContract(m.usdc);
        if (ITestToken(m.token).decimals() != 18) revert BadDecimals(m.token);
        if (ITestToken(m.usdc).decimals() != 6) revert BadDecimals(m.usdc);

        m.seedUsdc = (m.seedToken * m.px) / 1e18;
        _fund(m.token, m.deployer, m.seedToken, testnet);
        _fund(m.usdc, m.deployer, m.seedUsdc, testnet);
    }

    /// @dev Testnets mint the shortfall; anywhere else the deployer must already hold it (real tokens can't be minted).
    function _fund(address token, address to, uint256 amount, bool testnet) internal {
        uint256 bal = ITestToken(token).balanceOf(to);
        if (bal >= amount) return;
        if (!testnet) revert InsufficientBalance(token, bal, amount);
        ITestToken(token).mint(to, amount - bal);
    }

    /// @dev Testnets from testnet/chains.json plus local anvil.
    function _isTestnet() internal view returns (bool) {
        uint256 id = block.chainid;
        return id == 84532 || id == 11155111 || id == 421614 || id == 11155420 || id == 1301 || id == 59141
            || id == 80002 || id == 97 || id == 43113 || id == 10143 || id == 31337;
    }

    /// @dev Mainnet chain ids (and anvil forks of them) need ALLOW_FORK=1.
    function _requireTestnet() internal {
        if (_isTestnet()) return;
        if (vm.envOr("ALLOW_FORK", uint256(0)) == 1) return;
        revert NotATestnet(block.chainid);
    }
}
