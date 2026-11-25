import { createPublicClient, defineChain, http, type Address, type PublicClient } from 'viem';
import { base } from 'viem/chains';

// Monad mainnet (chain 143). Same RPC as Android DojoPassReader.kt.
export const monad = defineChain({
  id: 143,
  name: 'Monad',
  nativeCurrency: { name: 'MON', symbol: 'MON', decimals: 18 },
  rpcUrls: { default: { http: ['https://rpc.monad.xyz'] } },
});

export type ChainKey = 'base' | 'monad';
export const CHAIN_KEYS: readonly ChainKey[] = ['base', 'monad'];

export const DOJO_PASS: Record<ChainKey, Address> = {
  base: '0x6B6A971a0aaab34E70659E0723AD0dCe129f7D9c',
  monad: '0x2647faf3aaA708D0B9a110744790E1f637FCca53',
};

// "Bushido Honor" (HONOR), ERC-721Enumerable on Monad. recordTrade feed.
export const HONOR: Address = '0x46D5F4924F833Cd4054A36eAEfa3bEca6cD92A7e';

// Minimal ABIs. Selectors were verified against deployed bytecode on 2026-11-24.
// The Dojo Pass is an address-keyed registry, NOT an ERC-721 (no tokenURI).
export const dojoPassAbi = [
  { type: 'function', name: 'hasDojoPass', stateMutability: 'view', inputs: [{ name: 'a', type: 'address' }], outputs: [{ type: 'bool' }] },
  { type: 'function', name: 'passPurchasedAt', stateMutability: 'view', inputs: [{ name: 'a', type: 'address' }], outputs: [{ type: 'uint256' }] },
  { type: 'function', name: 'isPractitioner', stateMutability: 'view', inputs: [{ name: 'a', type: 'address' }], outputs: [{ type: 'bool' }] },
] as const;

export const honorAbi = [
  { type: 'function', name: 'tradeCount', stateMutability: 'view', inputs: [{ name: 'a', type: 'address' }], outputs: [{ type: 'uint256' }] },
  { type: 'function', name: 'honorScores', stateMutability: 'view', inputs: [{ name: 'a', type: 'address' }], outputs: [{ type: 'uint256' }] },
  // Returns 5 static words: Gi, Yu, Jin, Rei, Makoto (each 0-10, per the contract's revert string).
  {
    type: 'function', name: 'getVirtueScores', stateMutability: 'view', inputs: [{ name: 'a', type: 'address' }],
    outputs: [{ type: 'uint256' }, { type: 'uint256' }, { type: 'uint256' }, { type: 'uint256' }, { type: 'uint256' }],
  },
] as const;

const clients: Partial<Record<ChainKey, PublicClient>> = {};
export function clientFor(chain: ChainKey): PublicClient {
  if (!clients[chain]) {
    clients[chain] = createPublicClient({ chain: chain === 'base' ? base : monad, transport: http() }) as PublicClient;
  }
  return clients[chain]!;
}
