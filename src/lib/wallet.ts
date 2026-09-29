import type { EIP1193Provider } from 'viem';

declare global {
  interface Window {
    ethereum?: EIP1193Provider & {
      isRabby?: boolean;
      on?: (event: string, handler: (...args: unknown[]) => void) => void;
      removeListener?: (event: string, handler: (...args: unknown[]) => void) => void;
    };
  }
}

export const BASE_CHAIN_ID = '0x2105';
export const BASE = {
  chainId: BASE_CHAIN_ID,
  chainName: 'Base',
  nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 },
  rpcUrls: ['https://mainnet.base.org'],
  blockExplorerUrls: ['https://basescan.org'],
};

export function getProvider() {
  return window.ethereum;
}

export async function connectRabby() {
  const provider = getProvider();
  if (!provider) throw new Error('Rabby was not detected. Install Rabby or another EIP-1193 wallet.');
  const accounts = await provider.request({ method: 'eth_requestAccounts' }) as string[];
  const chainId = await provider.request({ method: 'eth_chainId' }) as string;
  if (chainId !== BASE_CHAIN_ID) {
    try {
      await provider.request({
        method: 'wallet_switchEthereumChain',
        params: [{ chainId: BASE_CHAIN_ID }],
      });
    } catch (error) {
      const code = (error as { code?: number }).code;
      if (code === 4902) {
        await provider.request({
          method: 'wallet_addEthereumChain',
          params: [BASE],
        });
      } else throw error;
    }
  }
  return accounts[0];
}

export async function getBalance(address: string, token: string): Promise<string> {
  const provider = getProvider();
  if (!provider) throw new Error('Wallet not connected');
  
  if (token === 'ETH') {
    const balance = await provider.request({
      method: 'eth_getBalance',
      params: [address, 'latest'],
    }) as string;
    return (BigInt(balance) / BigInt(10 ** 18)).toString();
  }
  
  // ERC20 balanceOf call
  const tokenAddresses: Record<string, string> = {
    USDC: '0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913',
    AERO: '0x940181a94A35DC58f6Ea86F5d2c5DAD89d3cbF97',
    VIRTUAL: '0x0b3e328455c4059EEb9e3f84b5543F74E850ecF5',
  };
  
  const contractAddr = tokenAddresses[token];
  if (!contractAddr) return '0';
  
  try {
    const data = `0x70a08231000000000000000000000000${address.slice(2)}`;
    const result = await provider.request({
      method: 'eth_call',
      params: [{ to: contractAddr, data }, 'latest'],
    }) as string;
    return (BigInt(result) / BigInt(10 ** 18)).toString();
  } catch {
    return '0';
  }
}

export async function approveToken(
  tokenAddress: string,
  spenderAddress: string,
  amount: string,
): Promise<string> {
  const provider = getProvider();
  if (!provider) throw new Error('Wallet not connected');
  
  const amountWei = BigInt(amount) * BigInt(10 ** 18);
  const data = `0x095ea7b3000000000000000000000000${spenderAddress.slice(2)}${amountWei.toString(16).padStart(64, '0')}`;
  
  const tx = await provider.request({
    method: 'eth_sendTransaction',
    params: [{
      from: (await provider.request({ method: 'eth_accounts' })) as string[]).then(a => a[0]),
      to: tokenAddress,
      data,
    }],
  }) as string;
  
  return tx;
}

export async function executeSwap(
  routerAddress: string,
  swapCalldata: string,
  value?: string,
): Promise<string> {
  const provider = getProvider();
  if (!provider) throw new Error('Wallet not connected');
  
  const accounts = await provider.request({ method: 'eth_accounts' }) as string[];
  const tx = await provider.request({
    method: 'eth_sendTransaction',
    params: [{
      from: accounts[0],
      to: routerAddress,
      data: swapCalldata,
      value: value || '0',
    }],
  }) as string;
  
  return tx;
}
