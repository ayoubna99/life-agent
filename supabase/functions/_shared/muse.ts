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
}

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
  | { kind: 'text'; text: string }
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
  return { baseUrl, apiKey, model };
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
    if (text !== '') return { kind: 'text', text };
  }
  throw new MuseError('bad_output');
}
