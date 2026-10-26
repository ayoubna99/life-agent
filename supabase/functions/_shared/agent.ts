// One agent turn. The phone owns the conversation and the tools; this is stateless on day 1:
// the app sends the history, we add the system prompt, ask the model, and hand back text or tool calls.

import { callMuse, MuseError } from './muse.ts';
import type { AgentStep, ChatMessage, MuseConfig, ToolCall } from './muse.ts';
import { SYSTEM_PROMPT, TOOL_NAMES, TOOLS } from './prompt.ts';

export const LIMITS = {
  maxMessages: 60,
  maxContentChars: 4000,
  maxToolCallsPerMessage: 6,
};

export class BadRequest extends Error {
  readonly reason: string;

  constructor(reason: string) {
    super(reason);
    this.reason = reason;
  }
}

/** Only what the phone may send. A client can never inject its own system prompt. */
export function validateHistory(input: unknown): ChatMessage[] {
  const raw = (input as { messages?: unknown })?.messages;
  if (!Array.isArray(raw) || raw.length === 0) throw new BadRequest('messages_required');
  if (raw.length > LIMITS.maxMessages) throw new BadRequest('too_many_messages');

  const out: ChatMessage[] = [];
  const pendingToolIds = new Set<string>();
  for (const m of raw) {
    const role = (m as ChatMessage)?.role;
    if (role !== 'user' && role !== 'assistant' && role !== 'tool') throw new BadRequest('bad_role');
    const content = (m as ChatMessage).content;
    if (content !== null && typeof content !== 'string') throw new BadRequest('bad_content');
    if ((content ?? '').length > LIMITS.maxContentChars) throw new BadRequest('content_too_long');

    if (role === 'user') {
      if (content === null || content.trim() === '') throw new BadRequest('empty_message');
      out.push({ role, content });
    } else if (role === 'assistant') {
      const calls = (m as ChatMessage).tool_calls;
      if (calls !== undefined) {
        if (!Array.isArray(calls) || calls.length === 0 || calls.length > LIMITS.maxToolCallsPerMessage) {
          throw new BadRequest('bad_tool_calls');
        }
        for (const c of calls as ToolCall[]) {
          if (typeof c?.id !== 'string' || !TOOL_NAMES.has(c?.function?.name) || typeof c.function.arguments !== 'string') {
            throw new BadRequest('bad_tool_calls');
          }
          pendingToolIds.add(c.id);
        }
        out.push({ role, content, tool_calls: calls as ToolCall[] });
      } else {
        out.push({ role, content });
      }
    } else {
      const id = (m as ChatMessage).tool_call_id;
      if (typeof id !== 'string' || !pendingToolIds.has(id)) throw new BadRequest('tool_result_without_call');
      pendingToolIds.delete(id);
      out.push({ role, content: content ?? '', tool_call_id: id });
    }
  }
  if (out[out.length - 1].role === 'assistant' && !out[out.length - 1].tool_calls) {
    throw new BadRequest('last_message_must_be_user_or_tool');
  }
  return out;
}

export type TurnResult =
  | { type: 'text'; text: string }
  | { type: 'tool_calls'; calls: { id: string; name: string; args: Record<string, unknown> }[]; assistant: ChatMessage };

export async function runTurn(
  input: unknown,
  cfg: MuseConfig,
  fetchImpl: typeof fetch = fetch,
): Promise<TurnResult> {
  const history = validateHistory(input);
  const step: AgentStep = await callMuse(cfg, [{ role: 'system', content: SYSTEM_PROMPT }, ...history], TOOLS, fetchImpl);
  if (step.kind === 'text') return { type: 'text', text: step.text };

  // The model may only ask for the tools we defined.
  for (const c of step.calls) if (!TOOL_NAMES.has(c.name)) throw new MuseError('bad_output');
  return { type: 'tool_calls', calls: step.calls, assistant: step.assistant };
}
