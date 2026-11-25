import { createHash } from 'node:crypto';
import { Router, type Request, type Response } from 'express';
import { getAddress, isAddress } from 'viem';
import { NoPassError, getPassAttributes, type PassAttributes } from './aggregator.js';
import { CHAIN_KEYS, type ChainKey } from './chains.js';
import { buildMetadata } from './metadata.js';
import { renderPassSvg } from './render.js';

// Same attributes -> same SVG; keyed by attribute hash so a change regenerates.
const svgCache = new Map<string, string>();
const MAX_CACHE = 500;

function attrKey(a: PassAttributes): string {
  return createHash('sha256').update(JSON.stringify(a)).digest('hex');
}

function cachedSvg(a: PassAttributes): string {
  const key = attrKey(a);
  let svg = svgCache.get(key);
  if (!svg) {
    svg = renderPassSvg(a);
    if (svgCache.size >= MAX_CACHE) svgCache.delete(svgCache.keys().next().value!);
    svgCache.set(key, svg);
  }
  return svg;
}

function baseUrl(req: Request): string {
  return process.env.PUBLIC_BASE_URL || `${req.protocol}://${req.get('host')}`;
}

/**
 * Accepts a holder address, or a DojoPassDNA tokenId (decimal), which is
 * uint160(holder) by construction. Returns null if neither.
 */
export function holderFromParam(p: string): `0x${string}` | null {
  if (isAddress(p)) return getAddress(p);
  if (!/^\d{1,49}$/.test(p)) return null;
  const id = BigInt(p);
  if (id === 0n || id >= 1n << 160n) return null;
  return getAddress(`0x${id.toString(16).padStart(40, '0')}`);
}

async function load(req: Request, res: Response): Promise<PassAttributes | null> {
  const chain = String(req.params.chain);
  const address = String(req.params.address);
  if (!CHAIN_KEYS.includes(chain as ChainKey)) {
    res.status(400).json({ error: `chain must be one of ${CHAIN_KEYS.join(', ')}` });
    return null;
  }
  const holder = holderFromParam(address);
  if (!holder) {
    res.status(400).json({ error: 'invalid address or tokenId' });
    return null;
  }
  try {
    return await getPassAttributes(chain as ChainKey, holder);
  } catch (e) {
    if (e instanceof NoPassError) {
      res.status(404).json({ error: e.message });
      return null;
    }
    console.error('dojo-pass error:', e);
    res.status(502).json({ error: 'Failed to read pass state from chain' });
    return null;
  }
}

export const dojoPassRouter = Router();

// `/:chain/:id` is what DojoPassDNA.tokenURI produces (baseURI + decimal tokenId).
dojoPassRouter.get(['/api/dojo-pass/:chain/:address/metadata', '/api/dojo-pass/:chain/:address'], async (req, res) => {
  const a = await load(req, res);
  if (!a) return;
  res.set('Cache-Control', 'public, max-age=300').json(buildMetadata(a, baseUrl(req)));
});

dojoPassRouter.get('/api/dojo-pass/:chain/:address/image.svg', async (req, res) => {
  const a = await load(req, res);
  if (!a) return;
  res.set('Cache-Control', 'public, max-age=300').type('image/svg+xml').send(cachedSvg(a));
});
