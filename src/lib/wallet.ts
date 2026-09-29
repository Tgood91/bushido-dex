import type { EIP1193Provider } from 'viem';

declare global { interface Window { ethereum?: EIP1193Provider & { isRabby?: boolean; on?: (event: string, handler: (...args: unknown[]) => void) => void; removeListener?: (event: string, handler: (...args: unknown[]) => void) => void }; } }

export const BASE_CHAIN_ID = '0x2105';
export const BASE = { chainId: BASE_CHAIN_ID, chainName: 'Base', nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 }, rpcUrls: ['https://mainnet.base.org'], blockExplorerUrls: ['https://basescan.org'] };

export function getProvider() { return window.ethereum; }
export async function connectRabby() {
  const provider = getProvider();
  if (!provider) throw new Error('Rabby was not detected. Install Rabby or another EIP-1193 wallet.');
  const accounts = await provider.request({ method: 'eth_requestAccounts' }) as string[];
  const chainId = await provider.request({ method: 'eth_chainId' }) as string;
  if (chainId !== BASE_CHAIN_ID) {
    try { await provider.request({ method: 'wallet_switchEthereumChain', params: [{ chainId: BASE_CHAIN_ID }] }); }
    catch (error) {
      const code = (error as { code?: number }).code;
      if (code === 4902) await provider.request({ method: 'wallet_addEthereumChain', params: [BASE] }); else throw error;
    }
  }
  return accounts[0];
}
