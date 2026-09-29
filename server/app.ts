import express, { Request, Response } from 'express';

const app = express();
app.use(express.json());

app.get('/api/health', (_req: Request, res: Response) => {
  res.json({
    status: 'ok',
    network: 'Base',
    chainId: 8453,
    mode: 'reality',
  });
});

// Proxy to live router quote APIs
app.post('/api/router/quotes', async (req: Request, res: Response) => {
  try {
    const { tokenIn, tokenOut, amountIn } = req.body;

    if (!tokenIn || !tokenOut || !amountIn) {
      return res.status(400).json({ error: 'Missing tokenIn, tokenOut, or amountIn' });
    }

    // 1inch API
    const oneInchQuote = await fetch(
      `https://api.1inch.io/v5.0/8453/quote?fromTokenAddress=${tokenIn}&toTokenAddress=${tokenOut}&amount=${amountIn}&slippage=0.5`
    ).then((r) => r.json()).catch(() => null);

    // 0x API
    const zeroExQuote = await fetch(
      `https://api.0x.org/swap/v1/quote?chainId=8453&sellToken=${tokenIn}&buyToken=${tokenOut}&sellAmount=${amountIn}&slippagePercentage=0.5`
    ).then((r) => r.json()).catch(() => null);

    const quotes: any[] = [];

    if (oneInchQuote && oneInchQuote.toAmount) {
      quotes.push({
        routerId: '1inch',
        routerName: '1inch Aggregation',
        expectedOutput: oneInchQuote.toAmount,
        minOutput: (BigInt(oneInchQuote.toAmount) * BigInt(995) / BigInt(1000)).toString(),
        priceImpactPct: parseFloat(oneInchQuote.estimatedGas || '0') * 0.0001,
        estimatedGasWei: oneInchQuote.estimatedGas || '0',
        gasCostEth: (parseFloat(oneInchQuote.estimatedGas || '0') * 1e-18).toFixed(6),
        virtueScore: 92,
        isBestRate: false,
        calldata: oneInchQuote.tx?.data,
        toAddress: oneInchQuote.tx?.to,
      });
    }

    if (zeroExQuote && zeroExQuote.buyAmount) {
      quotes.push({
        routerId: '0x',
        routerName: '0x Protocol',
        expectedOutput: zeroExQuote.buyAmount,
        minOutput: (BigInt(zeroExQuote.buyAmount) * BigInt(995) / BigInt(1000)).toString(),
        priceImpactPct: parseFloat(zeroExQuote.grossPrice) > 0 ? Math.abs((1 - parseFloat(zeroExQuote.price) / parseFloat(zeroExQuote.grossPrice)) * 100) : 0,
        estimatedGasWei: zeroExQuote.gasEstimate || '0',
        gasCostEth: (parseFloat(zeroExQuote.gasPrice || '0') * parseFloat(zeroExQuote.gasEstimate || '0') * 1e-18).toFixed(6),
        virtueScore: 88,
        isBestRate: false,
        calldata: zeroExQuote.data,
        toAddress: zeroExQuote.to,
      });
    }

    // Mark best rate
    if (quotes.length > 0) {
      const best = quotes.reduce((prev, current) =>
        BigInt(current.expectedOutput || '0') > BigInt(prev.expectedOutput || '0') ? current : prev
      );
      best.isBestRate = true;
    }

    res.json({ success: true, quotes });
  } catch (error) {
    console.error('Quote error:', error);
    res.status(500).json({ error: 'Failed to fetch quotes' });
  }
});

export default app;
