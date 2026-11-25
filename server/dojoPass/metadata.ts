import { NOT_RECORDED, VIRTUES, type PassAttributes } from './aggregator.js';

type Attr =
  | { trait_type: string; value: string }
  | { trait_type: string; value: number; display_type: 'number'; max_value?: number };

const num = (trait_type: string, value: number, max_value?: number): Attr =>
  max_value === undefined ? { trait_type, value, display_type: 'number' } : { trait_type, value, display_type: 'number', max_value };

/** Numeric trait, or an honest string when the feed has no server-side source yet. */
const maybeNum = (trait_type: string, value: number | typeof NOT_RECORDED): Attr =>
  value === NOT_RECORDED ? { trait_type, value } : num(trait_type, value);

export function buildMetadata(a: PassAttributes, baseUrl: string) {
  const pending: string[] = [];
  if (a.disciplineVolumeUsd === NOT_RECORDED) pending.push('swap volume');
  if (a.checkInStreak === NOT_RECORDED) pending.push('check-ins');
  const unrecordedVirtues = VIRTUES.filter((v) => !a.virtues[v].recorded);
  if (unrecordedVirtues.length) pending.push(`virtues ${unrecordedVirtues.join(', ')}`);

  const attributes: Attr[] = [
    { trait_type: 'Rank', value: a.rank },
    num('Standing', a.standing, 100),
    num('Pass Age (days)', a.passAgeDays),
    num('Recorded Trades', a.recordedTrades),
    maybeNum('Discipline Volume (USD)', a.disciplineVolumeUsd),
    maybeNum('Check-in Streak (days)', a.checkInStreak),
    maybeNum('Total Check-ins', a.totalCheckIns),
    { trait_type: 'Home Chain', value: a.homeChain === 'base' ? 'Base' : 'Monad' },
    { trait_type: 'Practitioner', value: a.practitioner ? 'Yes' : 'No' },
    ...VIRTUES.map((v): Attr =>
      a.virtues[v].recorded ? num(`Virtue — ${v}`, a.virtues[v].level, 4) : { trait_type: `Virtue — ${v}`, value: NOT_RECORDED },
    ),
  ];

  const root = baseUrl.replace(/\/$/, '');
  return {
    name: `Dojo Pass · ${a.holder.slice(0, 6)}…${a.holder.slice(-4)}`,
    description:
      'A living record of practice. This pass evolves with its holder\'s trades, check-ins and virtues.' +
      (pending.length ? ` Not yet recorded on-chain: ${pending.join('; ')}.` : '') +
      ' The app view is live; marketplaces update when they re-fetch metadata.',
    image: `${root}/api/dojo-pass/${a.chain}/${a.holder}/image.svg`,
    external_url: `${root}/api/dojo-pass/${a.chain}/${a.holder}/metadata`,
    attributes,
  };
}
