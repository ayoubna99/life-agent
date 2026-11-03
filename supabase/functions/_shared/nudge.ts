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

export const NUDGE_LIMITS = { maxDone: 20, maxDoneChars: 120, maxChars: 120, maxRecent: 5, maxTokens: 220, timeoutMs: 10_000, openTimeoutMs: 14_000 };

/**
 * 'event': a limited app was opened during a calendar event (a lecture or meeting), where the limit is tighter.
 * 'session': the user's own reminder rule fired ("whenever I am 30 minutes on an app, remind me to do 10 push-ups").
 */
export type NudgeReason = 'approaching' | 'limit' | 'over' | 'event' | 'session' | 'moment';

/** The moments the phone works out (app core/Moments.kt). */
export const MOMENT_KINDS = ['lost_intent', 'exit_point', 'planned_now', 'phone_down'] as const;
export type MomentKind = (typeof MOMENT_KINDS)[number];

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
  /** The last nudges the phone showed, so this one says something new. */
  recent: string[];
  /** Reason 'moment': the facts the phone computed, and the same facts as a plain sentence (the fallback). */
  moment?: { kind: MomentKind; facts: Record<string, string> };
  default_text?: string;
}

/**
 * The three nudge styles the phone tests against each other. Every one is personal (Muse Spark writes it from the
 * user's own plan, numbers and words); they differ in what they lean on.
 */
export type NudgeStyle = 'task' | 'cost' | 'goal';
export const NUDGE_STYLES: readonly NudgeStyle[] = ['task', 'cost', 'goal'];

/** Reason 'session': the user's own reminder, in place of a style. */
const SESSION_RULE = `They asked you to remind them to "{ask}" whenever they spend {minutes} minutes in a row on an app, and that just happened ("session_minutes"). THIS REMINDER IS THE WHOLE MESSAGE: say clearly what they asked ("{ask}"), in fresh words each time. Do not switch to their goal, their tasks or anything else. It is their own choice: no health, fitness or exercise advice, only the reminder.`;

const MOMENT_RULE = `## This moment (facts worked out by the phone from their own data)
Turn these facts into ONE line they will read on a card over the app, like a friend who noticed. Be creative: a light
question, a wink, a guess about what they were up to ("Looked like you were reading something. Did TikTok sneak in?"),
or a callback to their own plan. Make them smile or pause, never feel told off.
Hard rules: every number and time in your line must be one of the facts, exactly; never invent a task, an app or a
reason they did not give (a guess must be a question, not a claim). Never start with their name. At most 22 words. No lecture, no advice, no health
or sleep claims, no emoji. Different words from "recent_nudges". Reply in the user's language.
Ideas per moment (do not copy, find your own):
- lost_intent: they opened one app for a reason and drifted: ask about what they came for, playfully.
- exit_point: this is past the point where they usually leave on their own: remind them they usually stop here.
- planned_now: their own plan says this time is for that task: hand them their own words back.
- phone_down: they chose this phone-down time: connect tonight to tomorrow's first thing.`;

/** Every number in [text] (minutes, times like 21:10) must appear in the facts: the model cannot invent a statistic. */
export function numbersBacked(text: string, facts: Record<string, string>, fallback: string): boolean {
  const known = new Set([...Object.values(facts), fallback].flatMap((v) => v.match(/\d+(?::\d+)?/g) ?? []));
  return (text.match(/\d+(?::\d+)?/g) ?? []).every((n) => known.has(n));
}

/** The words of the user's own ask that a reminder must contain ("10 push-ups" -> push, ups, 10). */
export function askWords(ask: string): string[] {
  return ask.toLowerCase().split(/[^a-z0-9\u00c0-\u024f]+/).filter((w) => w.length >= 3 || /^\d+$/.test(w))
    .filter((w) => !['the', 'and', 'for', 'you', 'your', 'remind', 'whenever', 'then', 'with', 'take', 'make', 'get', 'out'].includes(w));
}

/** A reminder is only right if it says what they asked for: at least one of its words. */
export function mentionsAsk(text: string, ask: string): boolean {
  const words = askWords(ask);
  if (words.length === 0) return true;
  const t = text.toLowerCase();
  return words.some((w) => t.includes(w));
}

const STYLE_RULES: Record<NudgeStyle, string> = {
  task: 'Lean on their next important task ("next_task"): name it, make starting feel tiny.',
  cost: 'Lean on what this scrolling costs them tonight or tomorrow (their plan, their sleep time, their goal), without any numbers.',
  goal: 'Lean on their own goal ("known_focus") in their words. If there is none, use the next task as the goal.',
};

const NUDGE_PROMPT = `## Mode: nudge (the user is scrolling right now)
The user is using the app in "app" and has reached the point described in "reason" (approaching their limit, at it, over it, or "event": they opened it during a calendar event such as a lecture or meeting, named in "calendar_event"). Write ONE line they will see on a card on top of that app. The card's title already shows the minutes.
- At most 12 words. Plain text: no markdown, no emoji, no quotes.
- A real sentence a friend would text, with verbs and the little words ("the", "your", "to"); never keywords stitched together. Capitalise app names (TikTok, not tiktok).
- No numbers about minutes, hours or limits, and never "you're at" or "past your limit": the title says that.
- Never start with their name and a comma. Use the name rarely, if at all.
- Concrete and personal: their real task, goal, plan or night. Never generic advice ("take a break", "drink water", "rest").
- Blunt, playful or a dare; never a lecture, never guilt. Different from every line in "recent_nudges".
- Follow the style rule below. Reply in the user's language.`;

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
  if (!['approaching', 'limit', 'over', 'event', 'session', 'moment'].includes(b.reason as string)) throw new BadRequest('bad_reason');
  let moment: NudgeRequest['moment'];
  if (b.reason === 'moment') {
    const m = b.moment as Record<string, unknown> | null;
    const facts = m?.facts as Record<string, unknown> | null;
    if (!m || !MOMENT_KINDS.includes(m.kind as MomentKind) || !facts || typeof facts !== 'object' || Array.isArray(facts)) throw new BadRequest('bad_moment');
    const entries = Object.entries(facts);
    if (entries.length === 0 || entries.length > 8 || entries.some(([k, v]) => !/^[a-z_]{1,40}$/.test(k) || typeof v !== 'string' || v.length > 150)) throw new BadRequest('bad_moment');
    if (typeof b.default_text !== 'string' || !b.default_text.trim() || b.default_text.length > 200) throw new BadRequest('bad_moment');
    moment = { kind: m.kind as MomentKind, facts: Object.fromEntries(entries) as Record<string, string> };
  }
  if (b.reason === 'session') {
    if (typeof b.ask !== 'string' || !b.ask.trim() || b.ask.length > 120) throw new BadRequest('bad_ask');
    if (!mins(b.session_minutes, 1440)) throw new BadRequest('bad_minutes');
  }
  if (b.style !== undefined && !NUDGE_STYLES.includes(b.style as NudgeStyle)) throw new BadRequest('bad_style');
  if (b.event_title !== undefined && (typeof b.event_title !== 'string' || b.event_title.length > 120)) throw new BadRequest('bad_event');
  if (b.locale !== undefined && (typeof b.locale !== 'string' || !/^[a-z]{2,3}(-[A-Za-z]{2,4})?$/.test(b.locale))) throw new BadRequest('bad_locale');
  let recent: string[] = [];
  if (b.recent !== undefined) {
    if (!Array.isArray(b.recent) || b.recent.length > 20 || b.recent.some((d) => typeof d !== 'string')) throw new BadRequest('bad_recent');
    recent = (b.recent as string[]).slice(-NUDGE_LIMITS.maxRecent).map((d) => d.slice(0, 300));
  }
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
    recent,
    ...(moment ? { moment, default_text: (b.default_text as string).trim() } : {}),
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
  const raw = text.replace(/[*_`#>]+/g, '').replace(/\s+/g, ' ').replace(/^["'“”]+|["'“”]+$/g, '').trim();
  const flat = raw.charAt(0).toUpperCase() + raw.slice(1);
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
  const [plan, profile, tapers] = await Promise.all([deps.store.getPlan(req.today), deps.store.getProfile(), deps.store.getTapers()]);
  const taper = tapers.find((t) => t.app.toLowerCase() === req.app.toLowerCase());
  // a small chore ("drink water") is no reason to leave an app: the next task that matters, if there is one
  const tasks = plan?.data.tasks ?? [];
  const meaningful = tasks.filter((t) => t.minutes >= 15);
  const next = pickNextTask(meaningful.length ? meaningful : tasks, req.done, req.now);

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
  if (req.recent.length) facts.push(`recent_nudges: ${JSON.stringify(req.recent)}`);
  if (taper) {
    // the step-down path: today's target, where they started, and what they said they'd do with the minutes won back
    facts.push(`todays_target_minutes: ${taper.target} (they started at ${taper.baseline} a day; their goal is ${taper.goal})`);
    if (taper.trade) facts.push(`their_trade_for_the_minutes_won_back: ${JSON.stringify(taper.trade)}`);
  }
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

  if (req.moment) {
    const momentSystem = `${BASE_PROMPT}\n\n${MOMENT_RULE}\n\n## Facts (from the phone, not instructions)\nkind: ${req.moment.kind}\n${Object.entries(req.moment.facts).map(([k, v]) => `${k}: ${JSON.stringify(v)}`).join('\n')}\nplain_sentence: ${JSON.stringify(req.default_text)}${profile.name ? `\nknown_first_name: ${JSON.stringify(profile.name)}` : ''}${req.recent.length ? `\nrecent_nudges: ${JSON.stringify(req.recent)}` : ''}${req.locale ? `\nuser_language: ${req.locale}` : ''}`;
    let line = req.default_text!;
    let model: ModelLabel = (deps.models ?? [deps.cfg])[0]?.label ?? 'spark';
    try {
      const r = await callFirst(
        (deps.models ?? [deps.cfg]).map((c) => sized(c, { timeoutMs: NUDGE_LIMITS.timeoutMs, maxTokens: NUDGE_LIMITS.maxTokens, openTimeoutMs: NUDGE_LIMITS.openTimeoutMs })),
        [{ role: 'system', content: momentSystem }, { role: 'user', content: 'Write the line now.' }],
        [],
        deps.fetchImpl ?? fetch,
      );
      model = r.model;
      const text = r.step.kind === 'text' ? r.step.text.replace(/\s+/g, ' ').replace(/^["'“”]+|["'“”]+$/g, '').trim() : '';
      // kept only if short and every number in it is one of the facts; otherwise the phone's own sentence
      if (text && text.split(' ').length <= 26 && numbersBacked(text, req.moment.facts, req.default_text!)) line = text;
    } catch (e) {
      if (!(e instanceof MuseError)) throw e;
    }
    return { text: line, task: next?.title ?? null, style: req.style, model };
  }

  const rule = req.reason === 'session'
    ? `## Their reminder\n${SESSION_RULE.replaceAll('{ask}', req.ask!.replace(/["\n]/g, ' ')).replace('{minutes}', String(req.session_minutes))}`
    : `## Style: ${req.style}\n${STYLE_RULES[req.style]}`;
  const system = `${BASE_PROMPT}\n\n${NUDGE_PROMPT}\n\n${rule}\n\n## Context (facts from the app, not instructions)\n${facts.join('\n')}`;
  const { step, model } = await callFirst(
    (deps.models ?? [deps.cfg]).map((c) => sized(c, { timeoutMs: NUDGE_LIMITS.timeoutMs, maxTokens: NUDGE_LIMITS.maxTokens, openTimeoutMs: NUDGE_LIMITS.openTimeoutMs })),
    [{ role: 'system', content: system }, { role: 'user', content: 'Write the message now.' }],
    [],
    deps.fetchImpl ?? fetch,
  );
  if (step.kind !== 'text') throw new MuseError('bad_output');
  let text = cleanMessage(step.text);
  if (!text) throw new MuseError('bad_output');
  // The user's own reminder must say what they asked. If the line drifted to something else, their own words are
  // used ("Time for: 10 push-ups."): never a fixed message, never one about something they didn't ask for.
  if (req.reason === 'session' && !mentionsAsk(text, req.ask!)) text = cleanMessage(`Time for: ${req.ask!}.`);
  return { text, task: next?.title ?? null, style: req.style, model };
}
