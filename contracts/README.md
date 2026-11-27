# Bushido DEX: Monad and OP Stack

V2- and V3-style AMMs for **Monad** and **OP Stack** chains (Base, OP Mainnet, Unichain). Every pool is seeded at the
live Chainlink price, never a hard-coded number. Copied from `Tgood91/Bushido-future` (`roadmap/contracts`, PRs #8 and #9).

## Audit status

| | |
|---|---|
| Status | **Not audited** |
| Auditor | [AUDITOR] |
| Report | [REPORT LINK] |
| Audited commit | [COMMIT] |

Until an audit is linked here, treat these contracts as testnet software. The deploy scripts refuse mainnet chain ids
unless `ALLOW_FORK=1`. On a non-testnet chain they never deploy or mint mock tokens: `TOKEN` and `USDC` must be the real
tokens and `DEPLOYER` must already hold the seed.

## Chains

| Chain | Stack | Chain ID | Chainlink ETH/USD | `MAX_STALENESS` |
|---|---|---|---|---|
| Monad testnet | Monad L1 | 10143 | `0x5c8c8482f064049248F86D9F4aFa4B1f2F5b6d31` | 90000 |
| Base Sepolia | OP Stack | 84532 | `0x4aDC67696bA383F43DD60A9e78F2C97Fbbfc7cb1` | 3600 |
| OP Sepolia | OP Stack | 11155420 | `0x61Ec26aA57019C486B10502285c5A3D4A4750AD7` | 3600 |
| Unichain Sepolia | OP Stack | 1301 | `0xd9c93081210dFc33326B2af4C2c11848095E6a9a` | 90000 |
| Base (mainnet) | OP Stack | 8453 | `0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70` | 3600 |

Feeds come from `Bushido-future/roadmap/testnet/chains.json`. Monad and Unichain feeds update less often, hence the
longer staleness window. Base mainnet is covered by the fork tests only; it is not a deploy target until audited.

## Contracts

| Path | What |
|---|---|
| `src/dex/` | V2 style: `DexPair` (constant product, 0.25% fee to LPs), `DexFactory`, `DexRouter` |
| `src/dexv3/` | V3 style: `DexV3Pool` (concentrated liquidity), `DexV3Factory` (fee tiers 0.01/0.05/0.25/0.3/1%), `DexV3Router` |
| `src/oracle/` | `ChainlinkFeedOracle`, `UniV3ChainlinkOracle`: the live price pools are seeded at |
| `script/` | `DeployDexV2`, `DeployDexV3`, shared `DexSeed` |
| `test/` | unit and fuzz tests; `test/fork/` runs both DEXes on a Base mainnet fork with no mocks |

**License:** `src/dexv3/` and the files built on it are GPL-2.0-or-later (math ported from Uniswap v3-core); the rest is MIT.

## Test

```bash
cd contracts
npm ci
forge test
forge test --match-test testFuzz_SwapNeverDecreasesK --fuzz-runs 777
BASE_RPC_URL=https://mainnet.base.org forge test --match-path 'test/fork/*'
```

## Deploy (testnets)

Simulate first, then add `--account <name> --broadcast`. Never put a private key in env.

```bash
# Monad testnet
DEPLOYER=<addr> USDC=<tUSDC> FEED=0x5c8c8482f064049248F86D9F4aFa4B1f2F5b6d31 MAX_STALENESS=90000 \
  forge script script/DeployDexV3.s.sol:DeployDexV3 --rpc-url https://testnet-rpc.monad.xyz

# Base Sepolia (OP Stack); OP Sepolia: https://sepolia.optimism.io, Unichain Sepolia: https://sepolia.unichain.org
DEPLOYER=<addr> USDC=<tUSDC> FEED=0x4aDC67696bA383F43DD60A9e78F2C97Fbbfc7cb1 \
  forge script script/DeployDexV3.s.sol:DeployDexV3 --rpc-url https://sepolia.base.org
```

`DeployDexV2` takes the same env. Other options: `SEED_TOKENS` (default 100), `FEE` (V3, default 2500),
`RANGE_TICKS` (V3, default 1000), `TOKEN`, `ORACLE`.
