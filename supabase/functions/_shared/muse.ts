// The one place that talks to Muse Spark. Everything else sees only AgentStep.
//
// ASSUMPTION (day 1): the API is OpenAI-compatible (POST {base}/chat/completions, Bearer key, `tools`,
// `tool_calls` in the answer). If the real format differs, only this file changes.

import type { ToolDef } from './prompt.ts';
import { cleanReply } from './reply.ts';

export interface MuseConfig {
  baseUrl: string;
  apiKey: string;
  model: string;
  timeoutMs?: number;
  maxTokens?: number;
  /** "spark" (Muse Spark) or "open" (Muse Spark Open, Meta's open-weights model, served by Baseten). */
  label?: ModelLabel;
  /** Extra request fields for this provider (for example reasoning_effort). */
  extra?: Record<string, unknown>;
}

export type ModelLabel = 'spark' | 'open';

/** The open-weights model always reasons before answering: it needs room for that, or the answer comes back empty. */
export const OPEN_DEFAULTS = {
  baseUrl: 'https://inference.baseten.co/v1',
  model: 'meta-models/muse-spark-open-1026',
  minTokens: 6000, // it used ~900 reasoning tokens just to say hi; a nudge prompt makes it think more
  timeoutMs: 45_000,
};

export interface ToolCall {
  id: string;
  type: 'function';
  function: { name: string; arguments: string };
}

export interface ChatMessage {
  role: 'system' | 'user' | 'assistant' | 'tool';
  content: string | null;
  tool_calls?: ToolCall[];
  tool_call_id?: string;
}

export interface ParsedCall {
  id: string;
  name: string;
  args: Record<string, unknown>;
}

export type AgentStep =
  | { kind: 'text'; text: string; reasoning?: string }
  | { kind: 'tool_calls'; calls: ParsedCall[]; assistant: ChatMessage };

/** What went wrong, without ever carrying the key, the prompt or the user's words. */
export type MuseErrorCode = 'not_configured' | 'timeout' | 'upstream_status' | 'bad_output' | 'network';

export class MuseError extends Error {
  readonly code: MuseErrorCode;
  readonly status?: number;
  /** A short reason for the logs: error type and a cleaned message. Never a URL, a key or user text. */
  readonly detail?: string;

  constructor(code: MuseErrorCode, status?: number, detail?: string) {
    super(`muse_${code}${status ? `_${status}` : ''}${detail ? ` (${detail})` : ''}`);
    this.code = code;
    this.status = status;
    this.detail = detail;
  }
}

/** Error type plus its message with every URL removed, so the logs say WHY without leaking where. */
export function describeNetworkError(e: unknown): string {
  const name = (e as Error)?.name ?? 'Error';
  const message = String((e as Error)?.message ?? '')
    .replace(/https?:\/\/\S+/gi, '<url>')
    .replace(/\s+/g, ' ')
    .trim()
    .slice(0, 120);
  return message ? `${name}: ${message}` : name;
}

export function configFromEnv(get: (name: string) => string | undefined): MuseConfig {
  const baseUrl = get('MUSE_BASE_URL')?.trim().replace(/\/+$/, '');
  const apiKey = get('MUSE_API_KEY')?.trim();
  const model = get('MUSE_MODEL')?.trim();
  if (!baseUrl || !apiKey || !model) throw new MuseError('not_configured');
  return { baseUrl, apiKey, model, label: 'spark' };
}

/** Muse Spark Open on Baseten (OpenAI compatible), or null when OPEN_API_KEY is not set. */
export function openConfigFromEnv(get: (name: string) => string | undefined): MuseConfig | null {
  const apiKey = get('OPEN_API_KEY')?.trim();
  if (!apiKey) return null;
  // "low" by default: tested on Baseten, the same answer with ~30 reasoning tokens instead of ~900 ("off" sends none)
  const setting = get('OPEN_REASONING_EFFORT')?.trim();
  const effort = setting === 'off' ? undefined : setting || 'low';
  return {
    baseUrl: (get('OPEN_BASE_URL')?.trim() || OPEN_DEFAULTS.baseUrl).replace(/\/+$/, ''),
    apiKey,
    model: get('OPEN_MODEL')?.trim() || OPEN_DEFAULTS.model,
    label: 'open',
    ...(effort ? { extra: { reasoning_effort: effort } } : {}),
  };
}

/** The jobs that can run on either model. */
export type Job = 'chat' | 'nudge' | 'evening' | 'nightshift';

/**
 * Which model does a job, first choice then the other one as a fallback. MODEL_ROUTE lists the jobs for the open model
 * (default "nudge,evening": the short, frequent writing). Without OPEN_API_KEY everything runs on Muse Spark.
 */
export function modelsFor(job: Job, get: (name: string) => string | undefined): MuseConfig[] {
  const open = openConfigFromEnv(get);
  let spark: MuseConfig | null = null;
  try {
    spark = configFromEnv(get);
  } catch {
    spark = null;
  }
  if (!open) {
    if (!spark) throw new MuseError('not_configured');
    return [spark];
  }
  const route = (get('MODEL_ROUTE') ?? 'nudge,evening').split(',').map((s) => s.trim().toLowerCase());
  // the night shift is the open model's own job (1M-token context, visible reasoning): always first
  const first = job === 'nightshift' || route.includes(job) ? open : spark ?? open;
  const second = first === open ? spark : open;
  return second ? [first, second] : [first];
}

/** The same model asked to think harder or less (the open model only; the other one ignores it). */
export function withEffort(cfg: MuseConfig, effort: 'low' | 'medium' | 'high'): MuseConfig {
  if (cfg.label !== 'open' || !cfg.extra || !('reasoning_effort' in cfg.extra)) return cfg;
  return { ...cfg, extra: { ...cfg.extra, reasoning_effort: effort } };
}

/** Sizes a request for the model it goes to: the open model gets room to reason and more time. */
export function sized(cfg: MuseConfig, want: { maxTokens?: number; timeoutMs?: number; openTimeoutMs?: number }): MuseConfig {
  const { openTimeoutMs, ...rest } = want;
  if (cfg.label !== 'open') return { ...cfg, ...rest };
  return {
    ...cfg,
    maxTokens: Math.max(want.maxTokens ?? 0, OPEN_DEFAULTS.minTokens),
    // a nudge has to land while the person is still in the app: the caller can give the open model less time
    timeoutMs: openTimeoutMs ?? Math.max(want.timeoutMs ?? 0, OPEN_DEFAULTS.timeoutMs),
  };
}

/**
 * Asks the first model; if it fails (down, too slow, an empty or broken answer), asks the next one. Returns the step
 * and which model answered. The last error is thrown when every model failed.
 */
export async function callFirst(
  cfgs: MuseConfig[],
  messages: ChatMessage[],
  tools: ToolDef[],
  fetchImpl: typeof fetch = fetch,
): Promise<{ step: AgentStep; model: ModelLabel }> {
  let last: unknown = new MuseError('not_configured');
  for (const cfg of cfgs) {
    try {
      return { step: await callMuse(cfg, messages, tools, fetchImpl), model: cfg.label ?? 'spark' };
    } catch (e) {
      if (!(e instanceof MuseError) || e.code === 'not_configured') throw e;
      console.error(`model ${cfg.label ?? 'spark'} failed: ${e.message}`);
      last = e;
    }
  }
  throw last;
}

export async function callMuse(
  cfg: MuseConfig,
  messages: ChatMessage[],
  tools: ToolDef[],
  fetchImpl: typeof fetch = fetch,
): Promise<AgentStep> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), cfg.timeoutMs ?? 25_000);
  let res: Response;
  try {
    res = await fetchImpl(`${cfg.baseUrl}/chat/completions`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${cfg.apiKey}` },
      body: JSON.stringify({
        model: cfg.model,
        messages,
        ...(tools.length ? { tools } : {}),
        ...(cfg.maxTokens ? { max_tokens: cfg.maxTokens } : {}),
        temperature: 0.4,
        ...(cfg.extra ?? {}),
      }),
      signal: controller.signal,
    });
  } catch (e) {
    if ((e as Error)?.name === 'AbortError') throw new MuseError('timeout');
    throw new MuseError('network', undefined, describeNetworkError(e));
  } finally {
    clearTimeout(timer);
  }
  if (!res.ok) throw new MuseError('upstream_status', res.status);

  let body: unknown;
  try {
    body = await res.json();
  } catch {
    throw new MuseError('bad_output');
  }
  return parseStep(body);
}

export function parseStep(body: unknown): AgentStep {
  const message = (body as { choices?: { message?: Record<string, unknown> }[] })?.choices?.[0]?.message;
  if (!message || typeof message !== 'object') throw new MuseError('bad_output');

  const rawCalls = message.tool_calls;
  if (Array.isArray(rawCalls) && rawCalls.length > 0) {
    const calls: ParsedCall[] = [];
    for (const c of rawCalls as ToolCall[]) {
      const name = c?.function?.name;
      if (typeof c?.id !== 'string' || typeof name !== 'string') throw new MuseError('bad_output');
      let args: unknown;
      try {
        args = JSON.parse(c.function.arguments || '{}');
      } catch {
        throw new MuseError('bad_output');
      }
      if (typeof args !== 'object' || args === null || Array.isArray(args)) throw new MuseError('bad_output');
      calls.push({ id: c.id, name, args: args as Record<string, unknown> });
    }
    const assistant: ChatMessage = {
      role: 'assistant',
      content: typeof message.content === 'string' && message.content.trim() !== '' ? cleanReply(message.content) : null,
      tool_calls: rawCalls as ToolCall[],
    };
    return { kind: 'tool_calls', calls, assistant };
  }

  if (typeof message.content === 'string' && message.content.trim() !== '') {
    const text = cleanReply(message.content);
    // The open model shows its reasoning (a separate field, or <think> tags): kept apart, never shown as the answer.
    const field = typeof message.reasoning_content === 'string' ? message.reasoning_content : typeof message.reasoning === 'string' ? message.reasoning : '';
    const tagged = /<think>([\s\S]*?)<\/think>/i.exec(message.content)?.[1] ?? '';
    const reasoning = (field || tagged).trim();
    if (text !== '') return reasoning ? { kind: 'text', text, reasoning } : { kind: 'text', text };
  }
  throw new MuseError('bad_output');
}
