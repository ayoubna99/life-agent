// The phone tests which kind of personal nudge pulls this user off a limited app. At each limit hit, CODE on the phone
// (not the model) picks the style with CONTEXTUAL Thompson sampling: for this app at this time of day, each style has a
// Beta posterior (how often the user left the app after it) whose prior is borrowed from all moments together
// (hierarchical shrinkage); one draw per style, the highest wins. The phone logs the chance it had of picking that style
// (the propensity), so the server can estimate, without bias, how a fixed nudge would have done (off-policy evaluation). Muse Spark then writes that nudge from the user's own data. The phone
// measures what happened next and sends the result here. The agent reads the totals in review mode; the app shows them
// with their sample sizes. One person, a few days: an early signal, never proof.

import { isDate } from './plan.ts';
import { BadRequest } from './loop.ts';

export type Arm = 'task' | 'cost' | 'goal';
export const ARMS: readonly Arm[] = ['task', 'cost', 'goal'];
export const ARM_LABEL: Record<Arm, string> = {
  task: 'nudges with your next task',
  cost: 'nudges with what the time costs',
  goal: 'nudges with your own goal',
};

export type HitReason = 'approaching' | 'limit' | 'over' | 'event' | 'demo';
const REASONS: readonly HitReason[] = ['approaching', 'limit', 'over', 'event', 'demo'];

export interface ExperimentEvent {
  id: string; // made on the phone, so a retried upload is stored once
  day: string; // the phone's local day
  time: string; // HH:MM, local
  app: string;
  arm: Arm;
  explore: boolean; // picked to test, not because it was the best
  reason: HitReason;
  left: boolean; // the user left the app soon after
  seconds_after: number; // time spent in the app in the window after
  window_seconds: number;
  demo: boolean; // compressed demo thresholds
  /** The chance the phone's policy had of picking this style at that moment (0..1], for off-policy evaluation. */
  propensity?: number;
  /** The moment, as the bandit saw it: the time of day band. */
  context?: Band;
  /** The words Muse Spark wrote for this nudge (the lab notebook shows them). */
  message?: string;
}

export type Band = 'morning' | 'afternoon' | 'evening' | 'night';
export const BANDS: readonly Band[] = ['morning', 'afternoon', 'evening', 'night'];

export const EXPERIMENT_LIMITS = { maxEvents: 50, minTries: 3, draws: 4000, bestProbability: 0.75, minForPolicy: 10, bootstrap: 500, logSize: 40 };

const HHMM = /^([01]\d|2[0-3]):[0-5]\d$/;

export function parseExperimentLog(raw: unknown): ExperimentEvent[] {
  if (!Array.isArray(raw) || raw.length > EXPERIMENT_LIMITS.maxEvents) throw new BadRequest('bad_experiments');
  const seen = new Set<string>();
  return raw.map((r: Record<string, unknown>) => {
    const app = typeof r?.app === 'string' ? r.app.trim() : '';
    const ok =
      typeof r?.id === 'string' && /^[\w-]{1,64}$/.test(r.id) && !seen.has(r.id) &&
      isDate(r.day) && typeof r.time === 'string' && HHMM.test(r.time) &&
      app && app.length <= 60 &&
      ARMS.includes(r.arm as Arm) && REASONS.includes(r.reason as HitReason) &&
      typeof r.explore === 'boolean' && typeof r.left === 'boolean' && typeof r.demo === 'boolean' &&
      Number.isInteger(r.seconds_after) && (r.seconds_after as number) >= 0 && (r.seconds_after as number) <= 3600 &&
      Number.isInteger(r.window_seconds) && (r.window_seconds as number) >= 30 && (r.window_seconds as number) <= 3600 &&
      (r.seconds_after as number) <= (r.window_seconds as number) &&
      (r.propensity === undefined || (typeof r.propensity === 'number' && r.propensity > 0 && r.propensity <= 1)) &&
      (r.context === undefined || BANDS.includes(r.context as Band)) &&
      (r.message === undefined || (typeof r.message === 'string' && r.message.length <= 300));
    if (!ok) throw new BadRequest('bad_experiments');
    seen.add(r.id as string);
    return {
      id: r.id as string,
      day: r.day as string,
      time: r.time as string,
      app,
      arm: r.arm as Arm,
      explore: r.explore as boolean,
      reason: r.reason as HitReason,
      left: r.left as boolean,
      seconds_after: r.seconds_after as number,
      window_seconds: r.window_seconds as number,
      demo: r.demo as boolean,
      ...(r.propensity !== undefined ? { propensity: r.propensity as number } : {}),
      ...(r.context !== undefined ? { context: r.context as Band } : {}),
      ...(typeof r.message === 'string' && r.message.trim() ? { message: r.message.trim() } : {}),
    };
  });
}

export interface ArmResult {
  arm: Arm;
  label: string;
  tried: number;
  left: number;
  left_rate: number | null; // 0..1, null when never tried
  avg_minutes_after: number | null;
  /** Thompson sampling: the chance this style is the best one, given the results so far (Beta(1,1) prior). */
  prob_best: number;
}

export interface ExperimentSummary {
  events: number;
  days: number;
  demo_events: number;
  arms: ArmResult[];
  /** The style that is most likely the best, only when that chance is at least 75% and it was tried at least 3 times. */
  best: Arm | null;
  by_app: { app: string; hits: number; left: number }[];
  /** When limits were hit, local hour by hour, busiest first. */
  hits_by_hour: { hour: string; hits: number }[];
  /** Off-policy evaluation: Life's own choices against always sending one fixed style (null until there is enough data). */
  policy: PolicyEvaluation | null;
  /** What works at which moment: per app and time of day, the style that leads so far. */
  contexts: ContextResult[];
  /** The newest nudges, newest first: what was sent, why, and what the user did next (the lab notebook). */
  log: LogEntry[];
  note: string;
}

export interface PolicyEvaluation {
  /** Events with a logged propensity (the ones that can be evaluated). */
  events: number;
  /** How often the user left the app with Life's own choices (observed). */
  life_rate: number;
  /** Self-normalised inverse propensity estimates of "always send this style", with their effective sample size. */
  fixed: { arm: Arm; estimate: number | null; effective_n: number }[];
  best_fixed: { arm: Arm; estimate: number } | null;
  /** The estimate for picking a style at random. */
  random: number | null;
  /** life_rate minus the best fixed estimate, and a 90% bootstrap interval for it. */
  lift: number | null;
  lift_interval: [number, number] | null;
  note: string;
}

export interface ContextResult {
  app: string;
  band: Band;
  hits: number;
  arms: { arm: Arm; tried: number; left: number }[];
  /** The style with the best posterior mean here, once there are at least 4 hits. */
  leading: Arm | null;
}

export interface LogEntry {
  day: string;
  time: string;
  app: string;
  band: Band | null;
  arm: Arm;
  label: string;
  explore: boolean;
  propensity: number | null;
  message: string | null;
  left: boolean;
  minutes_after: number;
  demo: boolean;
}

const round1 = (n: number) => Math.round(n * 10) / 10;

// A small seeded generator, so the same results always give the same probabilities (and the tests are exact).
function mulberry32(seed: number): () => number {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

function normal(rnd: () => number): number {
  const u = Math.max(rnd(), 1e-12);
  return Math.sqrt(-2 * Math.log(u)) * Math.cos(2 * Math.PI * rnd());
}

/** Gamma(shape, 1) by Marsaglia and Tsang (shape >= 1, which Beta(left + 1, missed + 1) always gives). */
function gamma(shape: number, rnd: () => number): number {
  const d = shape - 1 / 3;
  const c = 1 / Math.sqrt(9 * d);
  for (;;) {
    let x: number;
    let v: number;
    do {
      x = normal(rnd);
      v = 1 + c * x;
    } while (v <= 0);
    v = v * v * v;
    const u = rnd();
    if (u < 1 - 0.0331 * x ** 4 || Math.log(u) < 0.5 * x * x + d * (1 - v + Math.log(v))) return d * v;
  }
}

export function sampleBeta(a: number, b: number, rnd: () => number): number {
  const x = gamma(a, rnd);
  return x / (x + gamma(b, rnd));
}

/** For each arm, the share of joint posterior draws in which it is the best (Thompson sampling's own view). */
export function probabilityBest(stats: { tried: number; left: number }[], draws = EXPERIMENT_LIMITS.draws, seed = 42): number[] {
  const rnd = mulberry32(seed);
  const wins = stats.map(() => 0);
  for (let i = 0; i < draws; i++) {
    let best = 0;
    let top = -1;
    stats.forEach((s, k) => {
      const v = sampleBeta(s.left + 1, s.tried - s.left + 1, rnd);
      if (v > top) {
        top = v;
        best = k;
      }
    });
    wins[best]++;
  }
  return wins.map((w) => Math.round((w / draws) * 100) / 100);
}

export function summarizeExperiments(events: ExperimentEvent[]): ExperimentSummary {
  const counted = ARMS.map((arm) => {
    const mine = events.filter((e) => e.arm === arm);
    return { arm, mine, tried: mine.length, left: mine.filter((e) => e.left).length };
  });
  const probs = probabilityBest(counted);
  const arms: ArmResult[] = counted.map(({ arm, mine, tried, left }, k) => ({
    arm,
    label: ARM_LABEL[arm],
    tried,
    left,
    left_rate: tried ? round1((left / tried) * 100) / 100 : null,
    avg_minutes_after: tried ? round1(mine.reduce((s, e) => s + e.seconds_after, 0) / tried / 60) : null,
    prob_best: probs[k],
  }));
  const leader = [...arms].sort((a, b) => b.prob_best - a.prob_best)[0];
  const best = leader.prob_best >= EXPERIMENT_LIMITS.bestProbability && leader.tried >= EXPERIMENT_LIMITS.minTries ? leader.arm : null;

  const apps = new Map<string, { app: string; hits: number; left: number }>();
  const hours = new Map<string, number>();
  for (const e of events) {
    const k = e.app.toLowerCase();
    const a = apps.get(k) ?? { app: e.app, hits: 0, left: 0 };
    a.hits++;
    if (e.left) a.left++;
    apps.set(k, a);
    const h = `${e.time.slice(0, 2)}:00`;
    hours.set(h, (hours.get(h) ?? 0) + 1);
  }
  const days = new Set(events.map((e) => e.day)).size;
  const policy = evaluatePolicy(events);
  return {
    events: events.length,
    days,
    demo_events: events.filter((e) => e.demo).length,
    arms,
    best,
    by_app: [...apps.values()].sort((a, b) => b.hits - a.hits).slice(0, 8),
    hits_by_hour: [...hours].map(([hour, hits]) => ({ hour, hits })).sort((a, b) => b.hits - a.hits || a.hour.localeCompare(b.hour)).slice(0, 6),
    policy,
    contexts: contextResults(events),
    log: [...events].reverse().slice(0, EXPERIMENT_LIMITS.logSize).map((e) => ({
      day: e.day,
      time: e.time,
      app: e.app,
      band: e.context ?? null,
      arm: e.arm,
      label: ARM_LABEL[e.arm],
      explore: e.explore,
      propensity: e.propensity ?? null,
      message: e.message ?? null,
      left: e.left,
      minutes_after: Math.round(e.seconds_after / 6) / 10,
      demo: e.demo,
    })),
    note: `Early signal from one person over ${days} day(s) and ${events.length} limit hit(s), not proof. prob_best is the chance each style is the best given these results; contexts says what leads per app and time of day; policy compares Life's own choices with always sending one style (an estimate). Quote the sample sizes; never make health claims.`,
  };
}

const round2 = (n: number) => Math.round(n * 100) / 100;

/** Self-normalised inverse propensity scoring: the value of a policy that picks `target(e)` with that probability. */
function snips(events: ExperimentEvent[], target: (e: ExperimentEvent) => number): { value: number | null; ess: number } {
  let num = 0;
  let den = 0;
  let sq = 0;
  for (const e of events) {
    const w = target(e) / e.propensity!;
    num += w * (e.left ? 1 : 0);
    den += w;
    sq += w * w;
  }
  return { value: den > 0 ? num / den : null, ess: sq > 0 ? (den * den) / sq : 0 };
}

function lift(events: ExperimentEvent[]): { lift: number | null; best: { arm: Arm; estimate: number } | null } {
  const life = events.filter((e) => e.left).length / events.length;
  let best: { arm: Arm; estimate: number } | null = null;
  for (const arm of ARMS) {
    const v = snips(events, (e) => (e.arm === arm ? 1 : 0)).value;
    if (v !== null && (best === null || v > best.estimate)) best = { arm, estimate: v };
  }
  return { lift: best ? life - best.estimate : null, best };
}

/**
 * Off-policy evaluation. Because the phone logged the probability of every choice it made, "what if Life had always sent
 * style X?" can be estimated from the same data without bias (inverse propensity weighting, self-normalised). The lift is
 * Life's observed rate minus the best fixed style, with a 90% bootstrap interval (seeded, so stable).
 */
export function evaluatePolicy(all: ExperimentEvent[]): PolicyEvaluation | null {
  const events = all.filter((e) => e.propensity !== undefined && e.propensity > 0);
  if (events.length < EXPERIMENT_LIMITS.minForPolicy) return null;
  const life = events.filter((e) => e.left).length / events.length;
  const fixed = ARMS.map((arm) => {
    const r = snips(events, (e) => (e.arm === arm ? 1 : 0));
    return { arm, estimate: r.value === null ? null : round2(r.value), effective_n: Math.round(r.ess * 10) / 10 };
  });
  const random = snips(events, () => 1 / ARMS.length).value;
  const { lift: l, best } = lift(events);

  let interval: [number, number] | null = null;
  if (l !== null) {
    const rnd = mulberry32(7);
    const lifts: number[] = [];
    for (let b = 0; b < EXPERIMENT_LIMITS.bootstrap; b++) {
      const sample = events.map(() => events[Math.floor(rnd() * events.length)]);
      const x = lift(sample).lift;
      if (x !== null) lifts.push(x);
    }
    lifts.sort((a, b) => a - b);
    if (lifts.length > 0) interval = [round2(lifts[Math.floor(lifts.length * 0.05)]), round2(lifts[Math.min(lifts.length - 1, Math.floor(lifts.length * 0.95))])];
  }
  return {
    events: events.length,
    life_rate: round2(life),
    fixed,
    best_fixed: best ? { arm: best.arm, estimate: round2(best.estimate) } : null,
    random: random === null ? null : round2(random),
    lift: l === null ? null : round2(l),
    lift_interval: interval,
    note: 'Estimated with self-normalised inverse propensity weighting from the logged choice probabilities. An estimate from one person, not proof; a wide interval means not enough data yet.',
  };
}

function contextResults(events: ExperimentEvent[]): ContextResult[] {
  const groups = new Map<string, ExperimentEvent[]>();
  for (const e of events) {
    if (!e.context) continue;
    const k = `${e.app.toLowerCase()}|${e.context}`;
    groups.set(k, [...(groups.get(k) ?? []), e]);
  }
  return [...groups.values()]
    .map((list) => {
      const arms = ARMS.map((arm) => {
        const mine = list.filter((e) => e.arm === arm);
        return { arm, tried: mine.length, left: mine.filter((e) => e.left).length };
      });
      const leader = [...arms].sort((a, b) => (b.left + 1) / (b.tried + 2) - (a.left + 1) / (a.tried + 2))[0];
      return { app: list[0].app, band: list[0].context!, hits: list.length, arms, leading: list.length >= 4 ? leader.arm : null };
    })
    .sort((a, b) => b.hits - a.hits)
    .slice(0, 8);
}
