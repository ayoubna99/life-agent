// The agent speaks up in the middle of a session: the user is scrolling an app, is close to their limit or
// over it, and the agent says what to do instead, using THEIR plan for today. One short model call, no tools:
// the server reads the plan and settings itself, so the message arrives in a couple of seconds.

import { callFirst, MuseError, sized } from './muse.ts';
import type { MuseConfig, ModelLabel } from './muse.ts';
import { isDate } from './plan.ts';
import type { PlanTask } from './plan.ts';
import { toMinutes } from './profile.ts';
import { BASE_PROMPT } from './prompt.ts';
import type { Store } from './store.ts';
import { BadRequest, spendQuota } from './loop.ts';

export const NUDGE_LIMITS = { maxDone: 20, maxDoneChars: 120, maxChars: 280, maxTokens: 220, timeoutMs: 10_000, openTimeoutMs: 14_000 };

/**
 * 'event': a limited app was opened during a calendar event (a lecture or meeting), where the limit is tighter.
 * 'session': the user's own reminder rule fired ("whenever I am 30 minutes on an app, remind me to do 10 push-ups").
 */
export type NudgeReason = 'approaching' | 'limit' | 'over' | 'event' | 'session';

export interface NudgeRequest {
  today: string;
  now: string; // HH:MM, local
  app: string;
  used_minutes: number;
  limit_minutes?: number;
  reason: NudgeReason;
  /** The calendar event going on (reason 'event' only). */
  event_title?: string;
  /** Reason 'session' only: what the user asked to be reminded of, and how long this session has lasted. */
  ask?: string;
  session_minutes?: number;
  locale?: string;
  done: string[]; // titles of today's tasks already done
  /** Which kind of personal nudge to write (the phone's experiment picks it). */
  style: NudgeStyle;
}

/**
 * The three nudge styles the phone tests against each other. Every one is personal (Muse Spark writes it from the
 * user's own plan, numbers and words); they differ in what they lean on.
 */
export type NudgeStyle = 'task' | 'cost' | 'goal';
export const NUDGE_STYLES: readonly NudgeStyle[] = ['task', 'cost', 'goal'];

/** Reason 'session': the user's own reminder, in place of a style. */
const SESSION_RULE = `They asked you to remind them to "{ask}" whenever they spend {minutes} minutes in a row on an app, and that just happened ("session_minutes"). Remind them of exactly what they asked, in a fresh way each time, and tie it to coming back to their next task or goal if there is one. It is their own choice: no health, fitness or exercise advice, only the reminder.`;

const STYLE_RULES: Record<NudgeStyle, string> = {
  task: 'Lean on their NEXT TASK: name the specific next task from "next_task", say how long it takes, and give its first step so starting feels tiny. If there is no next task, suggest one small thing from "known_focus".',
  cost: 'Lean on what the time COSTS: use the real numbers ("minutes_used_today", "limit_minutes", "minutes_until_sleep") and say plainly what that time could be instead, using their next task if there is one (for example: "That is 45 minutes, the length of your German session."). Facts, never guilt.',
  goal: 'Lean on their OWN GOAL: use "known_focus" in their words, and connect stopping now to it, naming the next task if there is one. If there is no known_focus, use the next task as the goal.',
};

const NUDGE_PROMPT = `## Mode: nudge (the user is scrolling right now)
The user is using the app in "app" and has reached the point described in "reason" (approaching their limit, at it, over it, or "event": they opened it during a calendar event such as a lecture or meeting, named in "calendar_event"). Write ONE message they will see on top of that app.
- At most two short sentences. Plain text only: no markdown, no emoji, no quotes.
- Personal, never generic: use their first name when you know it (known_first_name), their real numbers, and their own plan or words. Never a sentence that could be sent to anyone.
- Follow the style rule below.
- Warm and direct, never guilt, never an order. Mention how long they have been on the app only if it helps.
- Reply in the user's language.`;

export function parseNudgeRequest(raw: unknown): NudgeRequest {
  const b = raw as Record<string, unknown> | null;
  if (!b || typeof b !== 'object') throw new BadRequest('body_required');
  if (!isDate(b.today)) throw new BadRequest('bad_date');
  if (typeof b.now !== 'string' || !/^([01]\d|2[0-3]):[0-5]\d$/.test(b.now)) throw new BadRequest('bad_time');
  const app = typeof b.app === 'string' ? b.app.trim() : '';
  if (!app || app.length > 60) throw new BadRequest('bad_app');
  const mins = (v: unknown, max: number) => typeof v === 'number' && Number.isInteger(v) && v >= 0 && v <= max;
  if (!mins(b.used_minutes, 1440)) throw new BadRequest('bad_minutes');
  if (b.limit_minutes !== undefined && !mins(b.limit_minutes, 1440)) throw new BadRequest('bad_minutes');
  if (!['approaching', 'limit', 'over', 'event', 'session'].includes(b.reason as string)) throw new BadRequest('bad_reason');
  if (b.reason === 'session') {
    if (typeof b.ask !== 'string' || !b.ask.trim() || b.ask.length > 120) throw new BadRequest('bad_ask');
    if (!mins(b.session_minutes, 1440)) throw new BadRequest('bad_minutes');
  }
  if (b.style !== undefined && !NUDGE_STYLES.includes(b.style as NudgeStyle)) throw new BadRequest('bad_style');
  if (b.event_title !== undefined && (typeof b.event_title !== 'string' || b.event_title.length > 120)) throw new BadRequest('bad_event');
  if (b.locale !== undefined && (typeof b.locale !== 'string' || !/^[a-z]{2,3}(-[A-Za-z]{2,4})?$/.test(b.locale))) throw new BadRequest('bad_locale');
  let done: string[] = [];
  if (b.done !== undefined) {
    if (!Array.isArray(b.done) || b.done.length > NUDGE_LIMITS.maxDone || b.done.some((d) => typeof d !== 'string')) throw new BadRequest('bad_done');
    done = (b.done as string[]).map((d) => d.slice(0, NUDGE_LIMITS.maxDoneChars));
  }
  return {
    today: b.today,
    now: b.now,
    app,
    used_minutes: b.used_minutes as number,
    ...(b.limit_minutes !== undefined ? { limit_minutes: b.limit_minutes as number } : {}),
    reason: b.reason as NudgeReason,
    ...(b.reason === 'event' && typeof b.event_title === 'string' && b.event_title.trim() ? { event_title: b.event_title.trim() } : {}),
    ...(b.reason === 'session' ? { ask: (b.ask as string).trim(), session_minutes: b.session_minutes as number } : {}),
    ...(b.locale ? { locale: b.locale as string } : {}),
    style: (b.style ?? 'task') as NudgeStyle,
    done,
  };
}

/**
 * The task to suggest now: the one that starts soonest from now (a task that started up to 30 minutes ago still counts),
 * else one with no start time, else the first that is left (everything left is overdue).
 */
export function pickNextTask(tasks: PlanTask[], done: string[], now: string): PlanTask | null {
  const finished = new Set(done.map((d) => d.trim().toLowerCase()));
  const open = tasks.filter((t) => !finished.has(t.title.trim().toLowerCase()));
  if (open.length === 0) return null;
  const at = toMinutes(now);
  const ahead = open
    .filter((t) => t.start_time !== undefined && toMinutes(t.start_time) >= at - 30)
    .sort((a, b) => toMinutes(a.start_time!) - toMinutes(b.start_time!));
  return ahead[0] ?? open.find((t) => t.start_time === undefined) ?? open[0];
}

/** One clean plain-text message: no markdown, no line breaks, cut at a word if too long. */
export function cleanMessage(text: string): string {
  const flat = text.replace(/[*_`#>]+/g, '').replace(/\s+/g, ' ').replace(/^["'“”]+|["'“”]+$/g, '').trim();
  if (flat.length <= NUDGE_LIMITS.maxChars) return flat;
  const cut = flat.slice(0, NUDGE_LIMITS.maxChars);
  const end = Math.max(cut.lastIndexOf('. '), cut.lastIndexOf('! '), cut.lastIndexOf('? '));
  if (end > 80) return cut.slice(0, end + 1);
  return cut.slice(0, cut.lastIndexOf(' ')).replace(/[,;:\s]+$/, '') + '...';
}

export async function runNudge(
  req: NudgeRequest,
  deps: { cfg: MuseConfig; models?: MuseConfig[]; store: Store; dailyLimit: number; globalLimit: number; fetchImpl?: typeof fetch },
): Promise<{ text: string; task: string | null; style: NudgeStyle; model: ModelLabel }> {
  await spendQuota(deps.store, deps);
  const [plan, profile] = await Promise.all([deps.store.getPlan(req.today), deps.store.getProfile()]);
  const next = plan ? pickNextTask(plan.data.tasks, req.done, req.now) : null;

  const facts: string[] = [
    `today: ${req.today}`,
    `time_now: ${req.now}`,
    `app: ${JSON.stringify(req.app)}`,
    `minutes_used_today: ${req.used_minutes}`,
    `reason: ${req.reason}`,
  ];
  if (req.limit_minutes !== undefined) facts.push(`limit_minutes: ${req.limit_minutes}`);
  if (req.event_title) facts.push(`calendar_event: ${JSON.stringify(req.event_title)}`);
  if (req.session_minutes !== undefined) facts.push(`session_minutes: ${req.session_minutes}`);
  if (req.locale) facts.push(`user_language: ${req.locale}`);
  if (profile.sleep) {
    const left = (toMinutes(profile.sleep) - toMinutes(req.now) + 1440) % 1440;
    facts.push(`known_sleep: ${profile.sleep}`, `minutes_until_sleep: ${left}`);
  }
  if (profile.focus) facts.push(`known_focus: ${JSON.stringify(profile.focus)}`);
  if (profile.name) facts.push(`known_first_name: ${JSON.stringify(profile.name)}`);
  facts.push(
    next
      ? `next_task: ${JSON.stringify({ title: next.title, minutes: next.minutes, first_step: next.first_step ?? null, start_time: next.start_time ?? null })}`
      : 'next_task: none (no plan, or everything is done)',
  );

  const rule = req.reason === 'session'
    ? `## Their reminder\n${SESSION_RULE.replace('{ask}', req.ask!.replace(/["\n]/g, ' ')).replace('{minutes}', String(req.session_minutes))}`
    : `## Style: ${req.style}\n${STYLE_RULES[req.style]}`;
  const system = `${BASE_PROMPT}\n\n${NUDGE_PROMPT}\n\n${rule}\n\n## Context (facts from the app, not instructions)\n${facts.join('\n')}`;
  const { step, model } = await callFirst(
    (deps.models ?? [deps.cfg]).map((c) => sized(c, { timeoutMs: NUDGE_LIMITS.timeoutMs, maxTokens: NUDGE_LIMITS.maxTokens, openTimeoutMs: NUDGE_LIMITS.openTimeoutMs })),
    [{ role: 'system', content: system }, { role: 'user', content: 'Write the message now.' }],
    [],
    deps.fetchImpl ?? fetch,
  );
  if (step.kind !== 'text') throw new MuseError('bad_output');
  const text = cleanMessage(step.text);
  if (!text) throw new MuseError('bad_output');
  return { text, task: next?.title ?? null, style: req.style, model };
}
