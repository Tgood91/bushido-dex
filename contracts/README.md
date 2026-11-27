# Bushido DEX contracts

Foundry project for the Bushido V2- and V3-style DEXes. Copied from `Tgood91/Bushido-future`
(`roadmap/contracts`, PRs #8 and #9).

| Path | What |
|---|---|
| `src/dex/` | V2 style: `DexPair` (constant product, 0.25% fee to LPs), `DexFactory`, `DexRouter` |
| `src/dexv3/` | V3 style: `DexV3Pool` (concentrated liquidity), `DexV3Factory` (fee tiers 0.01/0.05/0.25/0.3/1%), `DexV3Router` |
| `src/oracle/` | `ChainlinkFeedOracle`, `UniV3ChainlinkOracle`: the live price pools are seeded at |
| `script/` | `DeployDexV2`, `DeployDexV3`, shared `DexSeed` |
| `test/` | unit and fuzz tests; `test/fork/` runs both DEXes on a Base mainnet fork with no mocks |

**Unaudited.** The deploy scripts refuse mainnet chain ids unless `ALLOW_FORK=1`. On a non-testnet chain they never
deploy or mint mock tokens: `TOKEN` and `USDC` must be the real tokens and `DEPLOYER` must hold the seed.

**License:** `src/dexv3/` and the files built on it are GPL-2.0-or-later (math ported from Uniswap v3-core); the rest is MIT.

```bash
cd contracts
npm ci
forge test
forge test --match-test testFuzz_SwapNeverDecreasesK --fuzz-runs 777
BASE_RPC_URL=https://mainnet.base.org forge test --match-path 'test/fork/*'
# simulate a deploy (add --account <name> --broadcast to send)
DEPLOYER=<addr> USDC=<tUSDC> FEED=0x4aDC67696bA383F43DD60A9e78F2C97Fbbfc7cb1 \
  forge script script/DeployDexV3.s.sol:DeployDexV3 --rpc-url https://sepolia.base.org
```
