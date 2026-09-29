export interface Quote {
  routerId: '1inch' | 'lifi' | '0x';
  routerName: string;
  expectedOutput: string;
  minOutput: string;
  priceImpactPct: number;
  estimatedGasWei: string;
  gasCostEth: number;
  virtueScore: number;
  isBestRate: boolean;
  calldata?: string;
  toAddress?: string;
}

const ROUTER_ADDRESSES: Record<string, string> = {
  '1inch': '0x111111125421cA6dc452d289314280a0f8842A65',
  'lifi': '0x1231DEB6f5749EF6cE6943a275A1D3E7486F4EaE',
  '0x': '0xDef1C0ded9bec7F1a1670819833240f027b25EfF',
};

const TOKEN_ADDRESSES: Record<string, string> = {
  USDC: '0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913',
  ETH: '0x0000000000000000000000000000000000000000', // native
  AERO: '0x940181a94A35DC58f6Ea86F5d2c5DAD89d3cbF97',
  VIRTUAL: '0x0b3e328455c4059EEb9e3f84b5543F74E850ecF5',
};

export async function getQuotes(
  tokenInSymbol: string,
  tokenOutSymbol: string,
  amountIn: string,
): Promise<Quote[]> {
  try {
    const res = await fetch('/api/router/quotes', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        tokenIn: TOKEN_ADDRESSES[tokenInSymbol],
        tokenOut: TOKEN_ADDRESSES[tokenOutSymbol],
        amountIn,
      }),
    });

    if (!res.ok) throw new Error(`API error: ${res.status}`);
    const data = await res.json() as { quotes: Quote[] };
    return data.quotes || [];
  } catch (error) {
    console.error('Quote fetch failed:', error);
    throw error;
  }
}

export function getRouterAddress(routerId: string): string {
  return ROUTER_ADDRESSES[routerId] || ROUTER_ADDRESSES['1inch'];
}

export function getTokenAddress(symbol: string): string {
  return TOKEN_ADDRESSES[symbol] || '';
}
