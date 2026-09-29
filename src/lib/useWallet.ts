import { useCallback, useEffect, useState } from 'react';
import { connectRabby, getProvider, BASE_CHAIN_ID } from './wallet';
export function useWallet() {
  const [address, setAddress] = useState<string>(); const [chainId, setChainId] = useState<string>(); const [error, setError] = useState('');
  const refresh = useCallback(async () => { const p=getProvider(); if (!p) return; const accounts=await p.request({method:'eth_accounts'}) as string[]; setAddress(accounts[0]); setChainId(await p.request({method:'eth_chainId'}) as string); }, []);
  const connect = useCallback(async () => { try { setError(''); setAddress(await connectRabby()); await refresh(); } catch (e) { setError(e instanceof Error ? e.message : 'Wallet connection failed'); } }, [refresh]);
  useEffect(() => { refresh(); const p=getProvider(); if (!p?.on) return; const accounts=()=>refresh(); const chain=()=>refresh(); p.on('accountsChanged',accounts); p.on('chainChanged',chain); return () => { p.removeListener?.('accountsChanged',accounts); p.removeListener?.('chainChanged',chain); }; }, [refresh]);
  return { address, chainId, isBase: chainId === BASE_CHAIN_ID, error, connect, disconnect:()=>setAddress(undefined) };
}
