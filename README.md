# Bushido DEX

A polished Base-chain DEX dashboard with Rabby-compatible EIP-1193 wallet connection, portfolio UX, router selection, and Bushido Virtue Score presentation.

## Run locally

```bash
npm install
npm run dev
```

## Deploy

Import this repository into Vercel. The included `vercel.json` builds the Vite app and routes `/api/*` to the serverless entrypoint.

## Important production boundary

The interface intentionally runs in **simulation mode**. It does not fabricate quotes, transaction hashes, approvals, or execution receipts. Before enabling swaps, configure audited router contracts, token addresses, live quote APIs, calldata validation, approval limits, slippage/deadline checks, and server-side monitoring. Never place private keys in this repository.

Rabby is detected through the standard injected EIP-1193 provider, so the connection flow also works with compatible browser wallets. The app requests Base (chain ID 8453) and offers a network switch when the wallet supports it.
