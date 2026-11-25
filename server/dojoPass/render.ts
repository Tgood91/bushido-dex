import { NOT_RECORDED, VIRTUES, type PassAttributes, type Rank, type Virtue } from './aggregator.js';

/**
 * Deterministic layered SVG for a living Dojo Pass. Same attributes give a
 * byte-identical image: no randomness, no clock, no ids that depend on order.
 *
 * Layers (bottom to top): Home Chain background, Rank frame, 8 virtue armour
 * pieces (4 tiers each), streak flame (7 / 30 / 90+ days).
 */

const W = 600;
const H = 840;

const CHAIN_THEME = {
  base: { name: 'Base', top: '#0052FF', bottom: '#001A52', accent: '#7FA8FF' },
  monad: { name: 'Monad', top: '#6E54FF', bottom: '#1A0F4D', accent: '#B9AAFF' },
} as const;

const FRAME: Record<Rank, { outer: string; inner: string; label: string; width: number }> = {
  Tsurano: { outer: '#8B5A2B', inner: '#B07A45', label: 'plain wood', width: 14 },
  Samurai: { outer: '#4A4F57', inner: '#7C838C', label: 'iron', width: 16 },
  'Bushido Master': { outer: '#9AA6B2', inner: '#E3E9EF', label: 'steel', width: 18 },
  Shogun: { outer: '#0B0B0B', inner: '#D4AF37', label: 'black and gold', width: 20 },
};

const PIECE: Record<Virtue, { kanji: string; piece: string; color: string; glyph: string }> = {
  Gi: { kanji: '義', piece: 'Gi uniform', color: '#E9E4D8', glyph: 'M14 10 L46 10 L52 50 L8 50 Z M30 10 L22 30 M30 10 L38 30' },
  Yu: { kanji: '勇', piece: 'Crest', color: '#E04A3A', glyph: 'M30 8 A22 22 0 1 1 29.9 8 Z M30 20 A4 4 0 1 1 29.9 20 Z M20 36 A4 4 0 1 1 19.9 36 Z M40 36 A4 4 0 1 1 39.9 36 Z' },
  Jin: { kanji: '仁', piece: 'Sash', color: '#3FA66B', glyph: 'M8 18 L18 10 L52 42 L42 50 Z' },
  Rei: { kanji: '礼', piece: 'Bow-wreath', color: '#D9A441', glyph: 'M8 34 Q30 0 52 34 M12 40 Q30 14 48 40' },
  Makoto: { kanji: '誠', piece: 'Mirror', color: '#9EC9E8', glyph: 'M30 6 A22 22 0 1 1 29.9 6 Z M20 18 L26 14' },
  Meiyo: { kanji: '名誉', piece: 'Banner', color: '#C0392B', glyph: 'M14 6 L14 54 M14 8 L48 8 L40 20 L48 32 L14 32' },
  Chugi: { kanji: '忠義', piece: 'Knot cord', color: '#8E6BBF', glyph: 'M10 30 Q20 10 30 30 Q40 50 50 30 Q40 10 30 30 Q20 50 10 30 Z' },
  Jisei: { kanji: '自制', piece: 'Sheath', color: '#2C2C2C', glyph: 'M10 46 L44 12 Q50 8 52 14 L18 52 Q12 54 10 46 Z' },
};

function esc(s: string): string {
  return s.replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]!);
}

function shortAddr(a: string): string {
  return `${a.slice(0, 6)}…${a.slice(-4)}`;
}

function virtueSlot(v: Virtue, level: number, recorded: boolean, x: number, y: number): string {
  const p = PIECE[v];
  const empty = level === 0;
  // Tier 1-4: piece fill opacity grows, stroke thickens, tier 4 gets a gold rim.
  const fillOpacity = empty ? 0 : [0, 0.35, 0.6, 0.85, 1][level];
  const stroke = empty ? 'rgba(255,255,255,0.35)' : level === 4 ? '#D4AF37' : p.color;
  const strokeWidth = empty ? 1.5 : 1.5 + level * 0.5;
  const dash = empty ? ' stroke-dasharray="4 4"' : '';
  const pips = [1, 2, 3, 4]
    .map((i) => `<circle cx="${x + 18 + i * 12}" cy="${y + 112}" r="4" fill="${i <= level ? '#D4AF37' : 'none'}" stroke="rgba(255,255,255,0.5)" stroke-width="1"/>`)
    .join('');
  return [
    `<g data-virtue="${v}" data-tier="${level}" data-recorded="${recorded}">`,
    `<rect x="${x}" y="${y}" width="96" height="124" rx="10" fill="rgba(0,0,0,0.28)" stroke="rgba(255,255,255,0.12)"/>`,
    `<g transform="translate(${x + 18} ${y + 10})"><path d="${p.glyph}" fill="${p.color}" fill-opacity="${fillOpacity}" stroke="${stroke}" stroke-width="${strokeWidth}" stroke-linejoin="round"${dash}/></g>`,
    `<text x="${x + 48}" y="${y + 84}" text-anchor="middle" font-size="15" fill="#fff">${p.kanji} ${v}</text>`,
    `<text x="${x + 48}" y="${y + 99}" text-anchor="middle" font-size="10" fill="rgba(255,255,255,0.6)">${recorded ? esc(p.piece) : 'not yet recorded'}</text>`,
    pips,
    `</g>`,
  ].join('');
}

function flame(streak: PassAttributes['checkInStreak']): string {
  if (streak === NOT_RECORDED || streak < 7) return '';
  const s = streak >= 90 ? 1.6 : streak >= 30 ? 1.25 : 1;
  return [
    `<g data-layer="flame" data-streak="${streak}" transform="translate(${W / 2} 250) scale(${s})">`,
    `<path d="M0 -60 C24 -30 30 -6 18 14 C10 28 -10 28 -18 14 C-30 -6 -20 -26 -6 -36 C-6 -20 4 -14 8 -22 C12 -34 6 -46 0 -60 Z" fill="#FF7A1A"/>`,
    `<path d="M0 -24 C10 -10 10 4 4 12 C0 16 -6 14 -8 8 C-12 -2 -6 -12 0 -24 Z" fill="#FFD23F"/>`,
    `</g>`,
  ].join('');
}

export function renderPassSvg(a: PassAttributes): string {
  const theme = CHAIN_THEME[a.homeChain];
  const frame = FRAME[a.rank];
  const fw = frame.width;

  const slots = VIRTUES.map((v, i) => {
    const col = i % 4;
    const row = Math.floor(i / 4);
    return virtueSlot(v, a.virtues[v].level, a.virtues[v].recorded, 52 + col * 128, 440 + row * 140);
  }).join('');

  const stat = (label: string, value: string | number, x: number) =>
    `<text x="${x}" y="366" text-anchor="middle" font-size="22" font-weight="700" fill="#fff">${esc(String(value))}</text>` +
    `<text x="${x}" y="386" text-anchor="middle" font-size="11" fill="rgba(255,255,255,0.65)">${esc(label)}</text>`;

  return [
    `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${W} ${H}" width="${W}" height="${H}" font-family="Helvetica, Arial, sans-serif">`,
    `<defs><linearGradient id="dojo-bg-${a.homeChain}" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="${theme.top}"/><stop offset="1" stop-color="${theme.bottom}"/></linearGradient></defs>`,
    // 1. Background: Home Chain colour scheme
    `<rect data-layer="background" data-chain="${a.homeChain}" width="${W}" height="${H}" fill="url(#dojo-bg-${a.homeChain})"/>`,
    // 2. Frame: rank tier
    `<g data-layer="frame" data-rank="${esc(a.rank)}">`,
    `<rect x="${fw / 2}" y="${fw / 2}" width="${W - fw}" height="${H - fw}" rx="18" fill="none" stroke="${frame.outer}" stroke-width="${fw}"/>`,
    `<rect x="${fw + 4}" y="${fw + 4}" width="${W - 2 * fw - 8}" height="${H - 2 * fw - 8}" rx="12" fill="none" stroke="${frame.inner}" stroke-width="3"/>`,
    `</g>`,
    // Header
    `<text x="${W / 2}" y="78" text-anchor="middle" font-size="16" letter-spacing="6" fill="rgba(255,255,255,0.75)">DOJO PASS</text>`,
    `<text x="${W / 2}" y="126" text-anchor="middle" font-size="40" font-weight="700" fill="#fff">${esc(a.rank)}</text>`,
    `<text x="${W / 2}" y="152" text-anchor="middle" font-size="13" fill="${theme.accent}">${esc(shortAddr(a.holder))} · Home: ${theme.name}${a.practitioner ? ' · Practitioner' : ''}</text>`,
    // Practitioner silhouette (the armour pieces below dress it as virtues level)
    `<g data-layer="figure" fill="rgba(255,255,255,0.14)"><circle cx="${W / 2}" cy="214" r="26"/><path d="M${W / 2 - 46} 300 Q${W / 2} 236 ${W / 2 + 46} 300 Z"/></g>`,
    // 4. Streak flame
    flame(a.checkInStreak),
    // Stats row
    stat('pass age (days)', a.passAgeDays, 120),
    stat('recorded trades', a.recordedTrades, 240),
    stat('standing', a.standing, 360),
    stat('streak', a.checkInStreak === NOT_RECORDED ? '—' : a.checkInStreak, 480),
    `<line x1="52" y1="412" x2="${W - 52}" y2="412" stroke="rgba(255,255,255,0.18)"/>`,
    // 3. Armour pieces, one per virtue
    `<g data-layer="armour">${slots}</g>`,
    `<text x="${W / 2}" y="${H - 34}" text-anchor="middle" font-size="11" fill="rgba(255,255,255,0.55)">A living record of practice · frame: ${esc(frame.label)}</text>`,
    `</svg>`,
  ].join('');
}
