import { useCallback, useEffect, useState } from 'react';
import { connectRabby, getProvider, BASE_CHAIN_ID, getBalance } from './wallet';

export function useWallet() {
  const [address, setAddress] = useState<string>();
  const [chainId, setChainId] = useState<string>();
  const [error, setError] = useState('');
  const [balances, setBalances] = useState<Record<string, string>>({});

  const refresh = useCallback(async () => {
    const p = getProvider();
    if (!p) return;
    const accounts = await p.request({ method: 'eth_accounts' }) as string[];
    const chain = await p.request({ method: 'eth_chainId' }) as string;
    setAddress(accounts[0]);
    setChainId(chain);
    
    if (accounts[0]) {
      const ethBal = await getBalance(accounts[0], 'ETH');
      const usdcBal = await getBalance(accounts[0], 'USDC');
      const aeroBal = await getBalance(accounts[0], 'AERO');
      const virtBal = await getBalance(accounts[0], 'VIRTUAL');
      setBalances({ ETH: ethBal, USDC: usdcBal, AERO: aeroBal, VIRTUAL: virtBal });
    }
  }, []);

  const connect = useCallback(async () => {
    try {
      setError('');
      const addr = await connectRabby();
      setAddress(addr);
      await refresh();
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Wallet connection failed');
    }
  }, [refresh]);

  useEffect(() => {
    refresh();
    const p = getProvider();
    if (!p?.on) return;
    const accounts = () => refresh();
    const chain = () => refresh();
    p.on('accountsChanged', accounts);
    p.on('chainChanged', chain);
    return () => {
      p.removeListener?.('accountsChanged', accounts);
      p.removeListener?.('chainChanged', chain);
    };
  }, [refresh]);

  return {
    address,
    chainId,
    isBase: chainId === BASE_CHAIN_ID,
    error,
    connect,
    disconnect: () => setAddress(undefined),
    balances,
    refreshBalances: refresh,
  };
}
