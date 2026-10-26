// Web search through Muse Spark's own built-in `web_search` tool (Responses API). The model decides whether to
// search and writes a grounded answer; every claim carries a url_citation annotation. We return the answer and
// the de-duplicated, safe sources, and tell the caller whether a search really happened.

import { isSafePublicUrl } from './links.ts';
import type { MuseConfig } from './muse.ts';
import { describeNetworkError } from './muse.ts';
import { WebError } from './web.ts';

export const SEARCH = { timeoutMs: 45_000, maxAnswerChars: 4000, maxSources: 8 } as const;

export interface SearchSource {
  title: string;
  url: string;
}

export interface SearchAnswer {
  answer: string;
  sources: SearchSource[];
  /** False when the model answered from memory: the answer then has no sources. */
  searched: boolean;
}

export interface SearchOptions {
  /** Overrides MUSE_MODEL for the search call (env SEARCH_MODEL). */
  model?: string;
  contextSize?: 'low' | 'medium' | 'high';
}

export async function searchWithMuse(
  query: string,
  cfg: MuseConfig,
  opts: SearchOptions = {},
  fetchImpl: typeof fetch = fetch,
): Promise<SearchAnswer> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), SEARCH.timeoutMs);
  let body: unknown;
  try {
    const res = await fetchImpl(`${cfg.baseUrl}/responses`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${cfg.apiKey}` },
      body: JSON.stringify({
        model: opts.model || cfg.model,
        input: `Search the web and answer briefly and factually, with sources. Question: ${query}`,
        tools: [{ type: 'web_search', search_context_size: opts.contextSize ?? 'medium' }],
      }),
      signal: controller.signal,
    });
    if (!res.ok) throw new WebError(`The search service answered with status ${res.status}.`);
    body = await res.json();
  } catch (e) {
    if (e instanceof WebError) throw e;
    if ((e as Error)?.name === 'AbortError') throw new WebError('The search took too long.');
    console.error('web_search failed:', describeNetworkError(e));
    throw new WebError('The search service could not be reached.');
  } finally {
    clearTimeout(timer);
  }
  return parseSearchResponse(body);
}

/** Reads the Responses output list by item.type, never by position. */
export function parseSearchResponse(body: unknown): SearchAnswer {
  const output = (body as { output?: unknown })?.output;
  if (!Array.isArray(output)) throw new WebError('The search service sent an answer in an unexpected format.');

  let searched = false;
  const texts: string[] = [];
  const sources: SearchSource[] = [];
  const seen = new Set<string>();
  for (const item of output as { type?: string; content?: unknown }[]) {
    if (item?.type === 'web_search_call') searched = true;
    if (item?.type !== 'message' || !Array.isArray(item.content)) continue;
    for (const block of item.content as { type?: string; text?: unknown; annotations?: unknown }[]) {
      if (block?.type !== 'output_text' || typeof block.text !== 'string') continue;
      texts.push(block.text);
      if (!Array.isArray(block.annotations)) continue;
      for (const a of block.annotations as { type?: string; url?: unknown; title?: unknown }[]) {
        if (a?.type !== 'url_citation' || typeof a.url !== 'string') continue;
        if (!isSafePublicUrl(a.url) || seen.has(a.url) || sources.length >= SEARCH.maxSources) continue;
        seen.add(a.url);
        const title = typeof a.title === 'string' ? a.title.replace(/\s+/g, ' ').trim().slice(0, 120) : '';
        sources.push({ title: title || a.url, url: a.url });
      }
    }
  }
  const answer = texts.join('\n').trim();
  if (answer === '') throw new WebError('The search returned no answer.');
  return { answer: answer.slice(0, SEARCH.maxAnswerChars), sources, searched: searched || sources.length > 0 };
}
