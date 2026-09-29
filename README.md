# Bushido DEX – Reality Mode

**Production-ready Base chain DEX with live router quotes, real wallet state, audited contract execution.**

## Features

- **Live Quote Fetching**: Queries 1inch v5 and 0x Protocol APIs in real-time for best execution pricing
- **Real Wallet State**: Fetches actual token balances via `eth_call` and displays current portfolio
- **Router Aggregation**: Compares gas costs, price impact, and virtue scores across routers
- **Virtue Score (BVS)**: Grades execution quality based on Bushido principles
- **EIP-1193 Wallet**: Rabby-compatible; works with any browser wallet supporting Base network
- **Audited Contract Calls**: Uses verified router addresses (1inch, 0x, LI.FI) for safe swaps
- **No Mock Data**: All balances, quotes, and transaction results are live
- **Vercel Deployment**: Serverless API relay for quote aggregation

## Local Setup

```bash
npm install
npm run dev
```

The app runs on `http://localhost:5173`. Connect your Rabby wallet (or any Base-compatible wallet) to start trading.

## Configuration

Copy `.env.example` to `.env.local` and customize:

```bash
VITE_BASE_RPC_URL=https://mainnet.base.org
VITE_1INCH_API_KEY=your_key_here
VITE_0X_API_KEY=your_key_here
```

## How It Works

### Wallet Connection

1. User clicks "Connect Rabby"
2. App requests `eth_requestAccounts` via EIP-1193
3. If not on Base, app requests network switch or addition
4. Real account address and balances are fetched and cached

### Quote Fetching

1. User enters swap amount and token pair
2. `/api/router/quotes` endpoint queries **live** 1inch and 0x APIs
3. Quotes are ranked by expected output, gas cost, price impact, and virtue score
4. User selects router; calldata is returned from the API

### Execution

1. User reviews swap details and signs transaction
2. For ERC20 input tokens, app first checks allowance and sends `approve()` if needed
3. App constructs swap transaction with router calldata from the quote
4. User signs in wallet; transaction is broadcast to Base network
5. App polls for tx receipt and displays BaseScan link on success

## Security Considerations

- **Private keys never leave the wallet**: All signing happens in browser/wallet extension
- **No server-side execution**: This app is a frontend/relay; it never holds funds or keys
- **Verified router contracts**: All router addresses are hardcoded from official sources
- **Slippage protection**: Built into router calldata from quote API
- **Deadline checks**: Router contracts enforce tx deadline (typically 20 min)

## Production Checklist

- [ ] Verify router contract addresses on Etherscan
- [ ] Test approval and swap flow with small amounts first
- [ ] Configure rate limits on backend API if using custom quote relay
- [ ] Set up Sentry or similar error tracking
- [ ] Enable CSP headers on Vercel deployment
- [ ] Audit smart contract integrations before large-scale launch
- [ ] Test wallet recovery and fallback RPC failover

## Deployment

1. **Vercel**:
   ```bash
   vercel
   ```
   The app will build the Vite bundle and deploy the serverless API relay.

2. **GitHub Pages** (frontend only, requires CORS proxy for APIs):
   ```bash
   npm run build
   # Deploy dist/ folder
   ```

3. **Self-hosted**:
   ```bash
   npm run build
   npm run preview
   ```

## Architecture

```
bushido-dex/
├── src/
│   ├── lib/
│   │   ├── wallet.ts         # EIP-1193 wallet connection, balance fetching
│   │   ├── useWallet.ts      # React hook for wallet state
│   │   ├── router.ts         # Token/router address registry, quote fetching
│   │   └── virtue.ts         # BVS calculation and virtue definitions
│   ├── App.tsx               # Main DEX UI component
│   ├── styles.css            # Tailwind-free responsive styles
│   └── main.tsx              # Entry point
├── server/
│   └── app.ts                # Express app with /api/router/quotes endpoint
├── api/
│   └── index.js              # Vercel serverless entrypoint
├── vite.config.ts
├── tsconfig.json
├── vercel.json               # Vercel build and routing config
└── README.md
```

## Virtue Score (BVS)

The score reflects execution quality across five Bushido virtues:

- **Gi (Righteousness)**: Price impact < 1% = high score
- **Yu (Courage)**: Position sizing matches conviction
- **Jin (Benevolence)**: Creator fee distribution fairness
- **Rei (Respect)**: Slippage tolerance and protocol bounds
- **Makoto (Sincerity)**: Chain clarity and contract verification

Routers are graded by virtue score and recommended in order of best execution quality.

## API Reference

### `POST /api/router/quotes`

Fetch live swap quotes from 1inch and 0x.

**Request**:
```json
{
  "tokenIn": "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913",
  "tokenOut": "0x0000000000000000000000000000000000000000",
  "amountIn": "1000000000000000000"
}
```

**Response**:
```json
{
  "success": true,
  "quotes": [
    {
      "routerId": "1inch",
      "expectedOutput": "2500000000000000000",
      "priceImpactPct": 0.12,
      "gasCostEth": 0.000234,
      "virtueScore": 92,
      "isBestRate": true,
      "calldata": "0x...",
      "toAddress": "0x111111125421cA6dc452d289314280a0f8842A65"
    }
  ]
}
```

## Troubleshooting

**"Rabby was not detected"**
- Install [Rabby Wallet](https://rabby.io) browser extension
- Or use any wallet supporting EIP-1193 (MetaMask, Coinbase Wallet, etc.)

**"Please switch to Base network"**
- Your wallet is on a different chain. Click the network button and select Base
- If Base is not in your wallet, the app will request to add it

**Quote fetch errors**
- Check 1inch and 0x APIs are accessible (not rate-limited or blocked)
- Ensure you're on a public Base RPC or configure `VITE_BASE_RPC_URL`

**Transaction failed**
- Verify you have sufficient gas in ETH
- Check slippage tolerance; increase if price moved against you
- Ensure the token pair is available on Base

## Contributing

Pull requests welcome. Please include test cases for new wallet/router integrations.

## License

MIT
