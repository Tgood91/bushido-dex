import type { Address } from 'viem';
import { CHAIN_KEYS, DOJO_PASS, HONOR, clientFor, dojoPassAbi, honorAbi, type ChainKey } from './chains.js';

export const VIRTUES = ['Gi', 'Yu', 'Jin', 'Rei', 'Makoto', 'Meiyo', 'Chugi', 'Jisei'] as const;
export type Virtue = (typeof VIRTUES)[number];
/** Virtues HONOR records on-chain today (getVirtueScores order). The rest have no feed yet. */
export const RECORDED_VIRTUES: readonly Virtue[] = ['Gi', 'Yu', 'Jin', 'Rei', 'Makoto'];

export type Rank = 'Tsurano' | 'Samurai' | 'Bushido Master' | 'Shogun';

/** A value that has no server-side source yet. Rendered honestly, never as a fake 0. */
export const NOT_RECORDED = 'Not yet recorded' as const;
type Maybe<T> = T | typeof NOT_RECORDED;

export interface PassAttributes {
  chain: ChainKey;
  holder: Address;
  practitioner: boolean;
  passPurchasedAt: number; // unix seconds
  passAgeDays: number;
  recordedTrades: number;
  disciplineVolumeUsd: Maybe<number>;
  checkInStreak: Maybe<number>;
  totalCheckIns: Maybe<number>;
  homeChain: ChainKey;
  standing: number; // 0-100
  rank: Rank;
  virtues: Record<Virtue, { level: number; recorded: boolean }>;
}

export class NoPassError extends Error {
  constructor(chain: ChainKey, holder: string) {
    super(`No Dojo Pass for ${holder} on ${chain}`);
  }
}

/** Canon bands, same thresholds as Android CheckInStore.kt and web App.tsx. */
export function rankFromStanding(standing: number): Rank {
  if (standing >= 90) return 'Shogun';
  if (standing >= 75) return 'Bushido Master';
  if (standing >= 60) return 'Samurai';
  return 'Tsurano';
}

/** HONOR virtue score 0-10 -> armour tier 0-4. */
export function virtueLevel(score: number): number {
  return Math.max(0, Math.min(4, Math.ceil(score / 2.5)));
}

/** Everything the aggregator needs from chain. Injected so tests can stub RPC. */
export interface PassReader {
  pass(chain: ChainKey, holder: Address): Promise<{ has: boolean; purchasedAt: number; practitioner: boolean }>;
  honor(holder: Address): Promise<{ tradeCount: number; honorScore: number; virtueScores: number[] }>;
}

export const rpcReader: PassReader = {
  async pass(chain, holder) {
    const c = clientFor(chain);
    const address = DOJO_PASS[chain];
    const [has, purchasedAt, practitioner] = await Promise.all([
      c.readContract({ address, abi: dojoPassAbi, functionName: 'hasDojoPass', args: [holder] }),
      c.readContract({ address, abi: dojoPassAbi, functionName: 'passPurchasedAt', args: [holder] }),
      c.readContract({ address, abi: dojoPassAbi, functionName: 'isPractitioner', args: [holder] }),
    ]);
    return { has, purchasedAt: Number(purchasedAt), practitioner };
  },
  async honor(holder) {
    const c = clientFor('monad');
    const [tradeCount, honorScore, scores] = await Promise.all([
      c.readContract({ address: HONOR, abi: honorAbi, functionName: 'tradeCount', args: [holder] }),
      c.readContract({ address: HONOR, abi: honorAbi, functionName: 'honorScores', args: [holder] }),
      c.readContract({ address: HONOR, abi: honorAbi, functionName: 'getVirtueScores', args: [holder] }),
    ]);
    return { tradeCount: Number(tradeCount), honorScore: Number(honorScore), virtueScores: scores.map(Number) };
  },
};

export async function getPassAttributes(
  chain: ChainKey,
  holder: Address,
  reader: PassReader = rpcReader,
  now: number = Math.floor(Date.now() / 1000),
): Promise<PassAttributes> {
  const [passes, honor] = await Promise.all([
    Promise.all(CHAIN_KEYS.map(async (k) => [k, await reader.pass(k, holder)] as const)),
    reader.honor(holder),
  ]);
  const byChain = Object.fromEntries(passes) as Record<ChainKey, Awaited<ReturnType<PassReader['pass']>>>;
  const self = byChain[chain];
  if (!self.has) throw new NoPassError(chain, holder);

  const virtues = {} as PassAttributes['virtues'];
  for (const v of VIRTUES) {
    const i = RECORDED_VIRTUES.indexOf(v);
    virtues[v] = i >= 0 ? { level: virtueLevel(honor.virtueScores[i] ?? 0), recorded: true } : { level: 0, recorded: false };
  }

  const standing = Math.max(0, Math.min(100, honor.honorScore));
  return {
    chain,
    holder,
    practitioner: self.practitioner,
    passPurchasedAt: self.purchasedAt,
    passAgeDays: Math.max(0, Math.floor((now - self.purchasedAt) / 86400)),
    recordedTrades: honor.tradeCount,
    disciplineVolumeUsd: NOT_RECORDED,
    checkInStreak: NOT_RECORDED,
    totalCheckIns: NOT_RECORDED,
    homeChain: homeChain(byChain, honor.tradeCount),
    standing,
    rank: rankFromStanding(standing),
    virtues,
  };
}

/**
 * Chain with the most Bushido activity. HONOR (trades) lives on Monad, so any
 * recorded trade makes Monad home. Otherwise: the earliest pass held.
 */
function homeChain(byChain: Record<ChainKey, { has: boolean; purchasedAt: number }>, monadTrades: number): ChainKey {
  if (monadTrades > 0) return 'monad';
  const held = CHAIN_KEYS.filter((k) => byChain[k].has).sort((a, b) => byChain[a].purchasedAt - byChain[b].purchasedAt);
  return held[0] ?? 'monad';
}
