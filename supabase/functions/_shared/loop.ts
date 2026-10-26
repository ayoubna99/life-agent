// One request from the phone = one run of this loop.
//
//   phone sends the NEW input (a user message, or the results of device tools it was asked to run)
//   -> we load the stored conversation, ask Muse Spark, run any server tools ourselves,
//   -> and return either the agent's text, or the device tool calls the phone must run next.

import { callMuse, MuseError } from './muse.ts';
import type { ChatMessage, MuseConfig, ParsedCall } from './muse.ts';
import { isDate } from './plan.ts';
import { buildSystemPrompt, knownTool, MODES, toolPlace, toolsFor } from './prompt.ts';
import type { Mode } from './prompt.ts';
import type { Store } from './store.ts';
import { runServerTool } from './tools.ts';

export const LIMITS = {
  maxSteps: 6,
  maxUserChars: 4000,
  maxResultChars: 8000,
  maxResults: 6,
  maxStoredMessages: 150,
  maxReportItems: 20,
  maxReportChars: 120,
};

export class BadRequest extends Error {
  readonly reason: string;
  constructor(reason: string) {
    super(reason);
    this.reason = reason;
  }
}
export class QuotaExceeded extends Error {
  constructor() {
    super('quota_exceeded');
  }
}
export class NotFound extends Error {
  constructor() {
    super('conversation_not_found');
  }
}

export type ChatInput =
  | { type: 'user'; text: string }
  | { type: 'tool_results'; results: { tool_call_id: string; content: string }[] };

export interface ChatRequest {
  conversation_id?: string;
  mode: Mode;
  today: string;
  date: string;
  locale?: string;
  report?: { done: string[]; missed: string[] };
  input: ChatInput;
}

export type ChatResponse =
  | { type: 'text'; conversation_id: string; text: string; plan_saved: boolean }
  | { type: 'tool_calls'; conversation_id: string; calls: { id: string; name: string; args: Record<string, unknown> }[]; plan_saved: boolean };

export interface ChatDeps {
  cfg: MuseConfig;
  store: Store;
  userId: string;
  supabaseUrl: string;
  dailyLimit: number;
  fetchImpl?: typeof fetch;
  randomId?: () => string;
}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function strings(v: unknown, what: string): string[] {
  if (!Array.isArray(v) || v.length > LIMITS.maxReportItems) throw new BadRequest(`bad_${what}`);
  return v.map((s) => {
    if (typeof s !== 'string') throw new BadRequest(`bad_${what}`);
    return s.slice(0, LIMITS.maxReportChars);
  });
}

export function parseChatRequest(raw: unknown): ChatRequest {
  const b = raw as Record<string, unknown> | null;
  if (!b || typeof b !== 'object') throw new BadRequest('body_required');
  if (!MODES.includes(b.mode as Mode)) throw new BadRequest('bad_mode');
  if (!isDate(b.today) || !isDate(b.date)) throw new BadRequest('bad_date');
  if (b.conversation_id !== undefined && (typeof b.conversation_id !== 'string' || !UUID.test(b.conversation_id))) throw new BadRequest('bad_conversation_id');
  if (b.locale !== undefined && (typeof b.locale !== 'string' || !/^[a-z]{2,3}(-[A-Za-z]{2,4})?$/.test(b.locale))) throw new BadRequest('bad_locale');

  const i = b.input as Record<string, unknown> | undefined;
  let input: ChatInput;
  if (i?.type === 'user') {
    if (typeof i.text !== 'string' || i.text.trim() === '') throw new BadRequest('empty_message');
    if (i.text.length > LIMITS.maxUserChars) throw new BadRequest('message_too_long');
    input = { type: 'user', text: i.text };
  } else if (i?.type === 'tool_results') {
    const r = i.results;
    if (!Array.isArray(r) || r.length === 0 || r.length > LIMITS.maxResults) throw new BadRequest('bad_tool_results');
    input = {
      type: 'tool_results',
      results: r.map((x: Record<string, unknown>) => {
        if (typeof x?.tool_call_id !== 'string' || typeof x?.content !== 'string' || x.content.length > LIMITS.maxResultChars) throw new BadRequest('bad_tool_results');
        return { tool_call_id: x.tool_call_id, content: x.content };
      }),
    };
  } else {
    throw new BadRequest('bad_input');
  }

  let report: ChatRequest['report'];
  if (b.report !== undefined) {
    const rep = b.report as Record<string, unknown>;
    report = { done: strings(rep?.done, 'report'), missed: strings(rep?.missed, 'report') };
  }
  return { conversation_id: b.conversation_id as string | undefined, mode: b.mode as Mode, today: b.today, date: b.date, locale: b.locale as string | undefined, report, input };
}

/** Tool calls in the stored history that have no answer yet. */
function pendingCalls(history: ChatMessage[]): { id: string; name: string }[] {
  let last = -1;
  for (let i = history.length - 1; i >= 0; i--) {
    if (history[i].role === 'assistant' && history[i].tool_calls?.length) {
      last = i;
      break;
    }
  }
  if (last < 0) return [];
  const answered = new Set(history.slice(last + 1).filter((m) => m.role === 'tool').map((m) => m.tool_call_id));
  return history[last].tool_calls!.filter((c) => !answered.has(c.id)).map((c) => ({ id: c.id, name: c.function.name }));
}

export async function runChat(req: ChatRequest, deps: ChatDeps): Promise<ChatResponse> {
  const fetchImpl = deps.fetchImpl ?? fetch;
  const randomId = deps.randomId ?? (() => crypto.randomUUID());
  const { store } = deps;

  if ((await store.bumpQuota()) > deps.dailyLimit) throw new QuotaExceeded();

  let conversationId = req.conversation_id;
  let history: ChatMessage[] = [];
  if (conversationId) {
    const c = await store.getConversation(conversationId);
    if (!c) throw new NotFound();
    if (c.kind !== req.mode) throw new BadRequest('mode_mismatch');
    history = await store.loadMessages(conversationId);
    if (history.length > LIMITS.maxStoredMessages) throw new BadRequest('conversation_too_long');
  } else {
    if (req.input.type !== 'user') throw new BadRequest('conversation_required');
    conversationId = await store.createConversation(req.mode);
  }

  // A crash in the middle of an earlier request can leave a server tool without its answer: close it.
  const toStore: ChatMessage[] = [];
  for (const p of pendingCalls(history)) {
    if (knownTool(p.name) === 'server' && req.input.type === 'user') {
      toStore.push({ role: 'tool', tool_call_id: p.id, content: JSON.stringify({ error: 'interrupted' }) });
    }
  }
  if (toStore.length) {
    await store.appendMessages(conversationId, toStore);
    history.push(...toStore);
    toStore.length = 0;
  }

  const pending = pendingCalls(history);
  if (req.input.type === 'user') {
    if (pending.length) throw new BadRequest('tool_results_required');
    toStore.push({ role: 'user', content: req.input.text });
  } else {
    const want = new Set(pending.map((p) => p.id));
    const got = req.input.results.map((r) => r.tool_call_id);
    if (want.size === 0 || got.length !== want.size || new Set(got).size !== got.length || got.some((id) => !want.has(id))) {
      throw new BadRequest('tool_results_mismatch');
    }
    // Answer in the order the model asked.
    const byId = new Map(req.input.results.map((r) => [r.tool_call_id, r.content]));
    for (const p of pending) toStore.push({ role: 'tool', tool_call_id: p.id, content: byId.get(p.id)! });
  }
  await store.appendMessages(conversationId, toStore);
  history.push(...toStore);

  const system = buildSystemPrompt({
    mode: req.mode,
    today: req.today,
    planDate: req.date,
    reviewDate: req.mode === 'review' ? req.today : undefined,
    locale: req.locale,
    report: req.report,
  });
  const tools = toolsFor(req.mode);
  let planSaved = false;

  for (let step = 0; step < LIMITS.maxSteps; step++) {
    const answer = await callMuse(deps.cfg, [{ role: 'system', content: system }, ...history], tools, fetchImpl);

    if (answer.kind === 'text') {
      const msg: ChatMessage = { role: 'assistant', content: answer.text };
      await store.appendMessages(conversationId, [msg]);
      return { type: 'text', conversation_id: conversationId, text: answer.text, plan_saved: planSaved };
    }

    // The model may only ask for tools this mode has.
    for (const c of answer.calls) if (!toolPlace(req.mode, c.name)) throw new MuseError('bad_output');
    await store.appendMessages(conversationId, [answer.assistant]);
    history.push(answer.assistant);

    const device: ParsedCall[] = [];
    const answers: ChatMessage[] = [];
    for (const call of answer.calls) {
      if (toolPlace(req.mode, call.name) === 'device') {
        device.push(call);
        continue;
      }
      const out = await runServerTool(call.name, call.args, {
        store,
        mode: req.mode,
        today: req.today,
        planDate: req.date,
        supabaseUrl: deps.supabaseUrl,
        fetchImpl,
        randomId,
      });
      if (out.planSaved) planSaved = true;
      answers.push({ role: 'tool', tool_call_id: call.id, content: out.content });
    }
    // Server answers are stored now. The device ones are stored when the phone reports back.
    if (answers.length) {
      await store.appendMessages(conversationId, answers);
      history.push(...answers);
    }
    if (device.length) {
      return { type: 'tool_calls', conversation_id: conversationId, calls: device.map((c) => ({ id: c.id, name: c.name, args: c.args })), plan_saved: planSaved };
    }
  }
  throw new MuseError('bad_output');
}

