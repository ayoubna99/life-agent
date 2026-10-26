// Reading a web page and searching the web for the agent. Everything here treats the internet as untrusted:
// only plain public https hosts, a size cap, a time cap, redirects checked at every hop, and the result is
// returned as quoted data for the model, never as instructions.

import { isSafePublicUrl } from './links.ts';
import { extractPdfText, isPdf } from './pdf.ts';
import type { PdfLoader } from './pdf.ts';

export const WEB = {
  maxBytes: 1_500_000,
  maxChars: 200_000,
  maxRedirects: 3,
  timeoutMs: 8000,
  sliceChars: 12_000,
};

export class WebError extends Error {}

const ENTITIES: Record<string, string> = { amp: '&', lt: '<', gt: '>', quot: '"', apos: "'", nbsp: ' ', ndash: '-', mdash: '-', hellip: '...', rsquo: "'", lsquo: "'", ldquo: '"', rdquo: '"' };

export function htmlToText(html: string): { title: string; text: string } {
  const title = (/<title[^>]*>([\s\S]*?)<\/title>/i.exec(html)?.[1] ?? '').replace(/\s+/g, ' ').trim();
  let s = html
    .replace(/<!--[\s\S]*?-->/g, ' ')
    .replace(/<(head|title|script|style|noscript|svg|nav|header|footer|form|iframe|template)[\s\S]*?<\/\1>/gi, ' ')
    .replace(/<(br|\/p|\/div|\/tr|\/h[1-6]|\/section|\/article|\/pre|\/blockquote)\s*\/?>/gi, '\n')
    .replace(/<li[^>]*>/gi, '\n- ')
    .replace(/<[^>]+>/g, ' ');
  s = s
    .replace(/&#(\d+);/g, (_m, n) => String.fromCodePoint(Math.min(Number(n), 0x10ffff)))
    .replace(/&#x([0-9a-f]+);/gi, (_m, h) => String.fromCodePoint(Math.min(parseInt(h, 16), 0x10ffff)))
    .replace(/&([a-z]+);/gi, (m, name) => ENTITIES[name.toLowerCase()] ?? m);
  const text = s
    .split('\n')
    .map((l) => l.replace(/[ \t ]+/g, ' ').trim())
    .filter((l, i, all) => l !== '' || (all[i - 1] ?? '') !== '')
    .join('\n')
    .trim();
  return { title: title.replace(/&([a-z]+);/gi, (m, n) => ENTITIES[n.toLowerCase()] ?? m), text };
}

async function readCapped(res: Response, max: number): Promise<Uint8Array> {
  const reader = res.body?.getReader();
  if (!reader) return new Uint8Array(await res.arrayBuffer()).slice(0, max);
  const chunks: Uint8Array[] = [];
  let total = 0;
  for (;;) {
    const { value, done } = await reader.read();
    if (done) break;
    chunks.push(value);
    total += value.length;
    if (total >= max) {
      await reader.cancel();
      break;
    }
  }
  const out = new Uint8Array(Math.min(total, max));
  let at = 0;
  for (const c of chunks) {
    const room = out.length - at;
    if (room <= 0) break;
    out.set(c.subarray(0, room), at);
    at += Math.min(c.length, room);
  }
  return out;
}

export interface Page {
  url: string;
  title: string;
  text: string;
  truncated: boolean;
}

export async function fetchPage(rawUrl: string, fetchImpl: typeof fetch, loadPdf?: PdfLoader): Promise<Page> {
  let current = isSafePublicUrl(rawUrl);
  if (!current) throw new WebError('Only public https addresses can be read.');
  let res: Response | undefined;
  for (let hop = 0; hop <= WEB.maxRedirects; hop++) {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), WEB.timeoutMs);
    try {
      res = await fetchImpl(current.toString(), {
        redirect: 'manual',
        signal: controller.signal,
        headers: { 'User-Agent': 'LifeAgent/1.0 (+reader)', Accept: 'text/html,text/plain,application/pdf;q=0.9,*/*;q=0.1' },
      });
    } catch {
      throw new WebError('The page could not be reached.');
    } finally {
      clearTimeout(timer);
    }
    if (res.status >= 300 && res.status < 400 && res.headers.get('location')) {
      const next = isSafePublicUrl(new URL(res.headers.get('location')!, current).toString());
      if (!next) throw new WebError('The page redirects somewhere that cannot be read.');
      current = next;
      res = undefined;
      continue;
    }
    break;
  }
  if (!res) throw new WebError('Too many redirects.');
  if (!res.ok) throw new WebError(`The page answered with status ${res.status}.`);

  const type = (res.headers.get('content-type') ?? '').toLowerCase();
  const bytes = await readCapped(res, WEB.maxBytes);
  let title = '';
  let text: string;
  if (type.includes('application/pdf') || isPdf(bytes)) {
    try {
      text = (await extractPdfText(bytes, loadPdf)).text;
    } catch {
      throw new WebError('That PDF could not be read.');
    }
  } else if (type.includes('html') || type === '') {
    ({ title, text } = htmlToText(new TextDecoder('utf-8', { fatal: false }).decode(bytes)));
  } else if (type.startsWith('text/') || type.includes('json') || type.includes('xml')) {
    text = new TextDecoder('utf-8', { fatal: false }).decode(bytes).trim();
  } else {
    throw new WebError(`This kind of file (${type.split(';')[0]}) cannot be read.`);
  }
  if (text === '') throw new WebError('There is no readable text on that page.');
  const truncated = text.length > WEB.maxChars;
  return { url: current.toString(), title, text: truncated ? text.slice(0, WEB.maxChars) : text, truncated };
}
