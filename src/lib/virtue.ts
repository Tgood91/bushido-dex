export interface VirtueScoreBreakdown {
  name: string;
  value: number;
  label: string;
  metric: string;
  color: string;
}

export const VIRTUES: VirtueScoreBreakdown[] = [
  { name: 'Gi', value: 94, label: 'Righteousness', metric: 'Execution fidelity', color: '#d4af37' },
  { name: 'Yu', value: 78, label: 'Courage', metric: 'Position conviction', color: '#e06b5e' },
  { name: 'Jin', value: 85, label: 'Benevolence', metric: 'Liquidity depth', color: '#3d9dde' },
  { name: 'Rei', value: 88, label: 'Respect', metric: 'Slippage control', color: '#a77be7' },
  { name: 'Makoto', value: 95, label: 'Sincerity', metric: 'Chain clarity', color: '#45d7a7' },
];

export function calculateBVS(quote: { priceImpactPct: number; virtueScore: number }): number {
  const impactPenalty = Math.max(0, 20 - quote.priceImpactPct * 10);
  const baseScore = quote.virtueScore || 85;
  return Math.round(baseScore + impactPenalty);
}
