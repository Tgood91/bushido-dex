// Worked example: Tanaz's real pass, read live from chain (read-only RPC).
// Usage: npx tsx scripts/dojo-pass-example.ts [holder]
import { mkdirSync, writeFileSync } from 'node:fs';
import { getAddress } from 'viem';
import { getPassAttributes } from '../server/dojoPass/aggregator.js';
import { CHAIN_KEYS } from '../server/dojoPass/chains.js';
import { buildMetadata } from '../server/dojoPass/metadata.js';
import { renderPassSvg } from '../server/dojoPass/render.js';

const holder = getAddress(process.argv[2] ?? '0xba397faae1d5fe10c0356f2e585bef34577ab111');
const baseUrl = process.env.PUBLIC_BASE_URL ?? 'https://bushido-dapp.onrender.com';
const out = 'review/dojo-pass';
mkdirSync(out, { recursive: true });

for (const chain of CHAIN_KEYS) {
  const attrs = await getPassAttributes(chain, holder);
  writeFileSync(`${out}/${chain}.json`, JSON.stringify(buildMetadata(attrs, baseUrl), null, 2) + '\n');
  writeFileSync(`${out}/${chain}.svg`, renderPassSvg(attrs));
  console.log(`${chain}: rank=${attrs.rank} age=${attrs.passAgeDays}d trades=${attrs.recordedTrades} home=${attrs.homeChain}`);
}

// Evolution mock: ILLUSTRATIVE values only (not anyone's real state), to show
// how the same pass dresses up across the four rank stages.
const live = await getPassAttributes('monad', holder);
const stages = [
  { rank: 'Tsurano', standing: 40, trades: 3, streak: 3, levels: [1, 0, 1, 0, 0, 0, 0, 0], chain: 'base' },
  { rank: 'Samurai', standing: 66, trades: 40, streak: 9, levels: [2, 1, 2, 1, 2, 1, 0, 1], chain: 'base' },
  { rank: 'Bushido Master', standing: 81, trades: 120, streak: 34, levels: [3, 3, 2, 3, 3, 2, 2, 3], chain: 'monad' },
  { rank: 'Shogun', standing: 95, trades: 400, streak: 120, levels: [4, 4, 4, 4, 4, 4, 3, 4], chain: 'monad' },
] as const;
stages.forEach((s, i) => {
  const virtues = { ...live.virtues };
  Object.keys(virtues).forEach((v, j) => (virtues[v as keyof typeof virtues] = { level: s.levels[j], recorded: true }));
  const svg = renderPassSvg({
    ...live, rank: s.rank, standing: s.standing, recordedTrades: s.trades, checkInStreak: s.streak,
    totalCheckIns: s.streak, homeChain: s.chain, passAgeDays: [7, 60, 180, 365][i], virtues,
  });
  writeFileSync(`${out}/mock-${i + 1}-${s.rank.replace(' ', '-').toLowerCase()}.svg`, svg);
});
console.log(`evolution mock: ${stages.length} illustrative stages written`);
