// Step-down targets: less of an app, one step at a time, only after the person succeeded at the step before.
//
// The method is the CHANGING-CRITERION design (step-by-step targets, each one earned): start from the person's TYPICAL day
// (the median of the last 7 complete days, not the worst one), set a target about 15% lower, and lower it again only
// when it was met on 2 of the last 3 days. Missing never raises the target and never speeds it up; it simply holds.
// It stops at the person's own goal: the aim is less, not zero. (Cutting down to zero works worse than a set quit day
// for smoking, but nobody quits their phone; reduction is the goal here.)
//
// Code computes every number. Muse Spark Open adds the part that makes the minutes count: when a target steps down it
// writes a TRADE, a concrete "when, what" for the minutes won back, from the person's own plan and goal (an
// implementation intention: "20 minutes back: 5 pages of your thesis at 22:30"). The nudge at the target uses it.

import { callFirst, MuseError, sized, type MuseConfig } from './muse.ts';
import type { PlanData } from './plan.ts';
import type { Profile } from './profile.ts';
import type { UsageRow } from './store.ts';

export interface TaperStep {
  day: string; // the day this target started
  target: number; // minutes per day
}

export interface Taper {
  app: string;
  baseline: number; // typical minutes per day when it started (median of 7 days)
  goal: number; // the floor: it never goes below
  target: number; // today's target
  /** Days at the current target, newest last: met (true) or not. */
  recent: { day: string; met: boolean }[];
  path: TaperStep[];
  /** The last day already judged. */
  judged: string | null;
  /** What to do with the minutes won back at this target (Muse Spark Open), or null. */
  trade: string | null;
}

export const TAPER = { step: 0.15, minStep: 5, need: 2, window: 3, baselineDays: 7, minDays: 3, defaultGoal: 30, round: 5 };

const median = (xs: number[]): number => {
  const s = [...xs].sort((a, b) => a - b);
  const m = Math.floor(s.length / 2);
  return s.length % 2 ? s[m] : Math.round((s[m - 1] + s[m]) / 2);
};
const roundTo = (n: number) => Math.max(TAPER.round, Math.round(n / TAPER.round) * TAPER.round);

/** The next, lower target: about 15% less (at least 5 minutes), rounded to 5, never below the goal. */
export function nextTarget(target: number, goal: number): number {
  const lower = roundTo(Math.min(target * (1 - TAPER.step), target - TAPER.minStep));
  return Math.max(goal, lower);
}

export function addDays(day: string, n: number): string {
  const d = new Date(`${day}T00:00:00Z`);
  d.setUTCDate(d.getUTCDate() + n);
  return d.toISOString().slice(0, 10);
}

/**
 * Brings a taper up to [today]: starts one from the usage of the 7 days before (when there are at least 3 days of data),
 * then judges every complete day not judged yet (a day without data counts as met: the app was not used). Returns the
 * new state and whether the target stepped down (or started) today. Null when there is not enough data to start.
 */
export function advanceTaper(state: Taper | null, app: string, usage: UsageRow[], today: string, goal = TAPER.defaultGoal): { taper: Taper; stepped: boolean } | null {
  const minutesOn = new Map(usage.map((u) => [u.day, u.minutes]));
  let t = state;
  let stepped = false;
  if (!t) {
    const days = Array.from({ length: TAPER.baselineDays }, (_, i) => addDays(today, -1 - i)).filter((d) => minutesOn.has(d));
    if (days.length < TAPER.minDays) return null;
    const baseline = median(days.map((d) => minutesOn.get(d)!));
    if (baseline <= goal) return null; // already within the goal: nothing to taper
    const target = nextTarget(baseline, goal);
    t = { app, baseline, goal, target, recent: [], path: [{ day: today, target }], judged: addDays(today, -1), trade: null };
    stepped = true;
  }
  t = { ...t, recent: [...t.recent], path: [...t.path] };
  let day = t.judged ? addDays(t.judged, 1) : addDays(today, -1);
  while (day < today) {
    t.recent.push({ day, met: (minutesOn.get(day) ?? 0) <= t.target });
    t.recent = t.recent.slice(-TAPER.window);
    if (t.recent.filter((r) => r.met).length >= TAPER.need && t.target > t.goal) {
      t.target = nextTarget(t.target, t.goal);
      t.path.push({ day: addDays(day, 1), target: t.target });
      t.recent = [];
      t.trade = null;
      stepped = true;
    }
    t.judged = day;
    day = addDays(day, 1);
  }
  return { taper: t, stepped };
}

/** "3 h → 2 h 30 → 2 h 10" */
export function minutesText(m: number): string {
  const h = Math.floor(m / 60);
  const r = m % 60;
  return h === 0 ? `${r} min` : r === 0 ? `${h} h` : `${h} h ${r}`;
}

const TRADE_PROMPT = `You help one person use less of an app, one step at a time. Their daily target for the app just went down. Write ONE line saying what they will do with the minutes they win back: a concrete action from their own plan or goal, and when (for example "20 minutes back: 5 pages of your thesis at 22:30."). At most 14 words. Start with the minutes won back. No advice, no health or sleep claims, no emoji, no quotes. Reply in their language.`;

/** The trade for a new target, written by Muse Spark Open; null when the model cannot be reached. */
export async function writeTrade(t: Taper, profile: Profile, plan: PlanData | null, models: MuseConfig[], fetchImpl: typeof fetch = fetch): Promise<string | null> {
  const before = t.path.length > 1 ? t.path[t.path.length - 2].target : t.baseline;
  const facts = [
    `app: ${t.app}`,
    `minutes_won_back_per_day: ${before - t.target}`,
    `new_daily_target_minutes: ${t.target}`,
    profile.focus ? `their_goal: ${JSON.stringify(profile.focus)}` : 'their_goal: not said',
    profile.sleep ? `sleep_time: ${profile.sleep}` : '',
    `tasks_tomorrow: ${JSON.stringify((plan?.tasks ?? []).map((x) => `${x.start_time ?? ''} ${x.title}`.trim()).slice(0, 8))}`,
  ].filter(Boolean);
  try {
    const { step } = await callFirst(
      models.map((c) => sized(c, { maxTokens: 120, timeoutMs: 12_000, openTimeoutMs: 20_000 })),
      [{ role: 'system', content: TRADE_PROMPT }, { role: 'user', content: facts.join('\n') }],
      [],
      fetchImpl,
    );
    if (step.kind !== 'text') return null;
    const line = step.text.replace(/\s+/g, ' ').replace(/^["'“”]+|["'“”]+$/g, '').trim();
    return line && line.split(' ').length <= 18 ? line.slice(0, 140) : null;
  } catch (e) {
    if (e instanceof MuseError) return null;
    throw e;
  }
}
