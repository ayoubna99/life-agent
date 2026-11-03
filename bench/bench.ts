// Life's benchmark: does the learning loop actually work? Runs offline, with no API key and no phone, in seconds.
//
// The people here are SIMULATED, so the right answer is known in advance: each one has a hidden chance of leaving the
// app for every nudge idea, and for half of them a different idea works at night. Real people are messier; this checks
// that the machinery finds the truth when there is one, and does not invent one when there is not.
//
// It uses Life's real code wherever the logic lives on the server (theory judging, off-policy evaluation, the line and
// number checks). The phone's picker (app/.../core/Bank.kt, Kotlin) is mirrored below with the same formula and
// constants; tests/bench.test.ts keeps the mirror honest against the starting beliefs both sides share.

import { ARMS, evaluatePolicy, mulberry32, sampleBeta } from '../supabase/functions/_shared/experiments.ts';
import type { Arm, Band, ExperimentEvent, Tone, Topic } from '../supabase/functions/_shared/experiments.ts';
import { lineProblem } from '../supabase/functions/_shared/nightshift.ts';
import { mentionsAsk, numbersBacked } from '../supabase/functions/_shared/nudge.ts';
import { judge, startingBelief, STARTING_BELIEFS } from '../supabase/functions/_shared/theories.ts';

// ---------------------------------------------------------------------------------------------------------------
// The phone's picker, mirrored from core/Bank.kt (NudgeBank.posterior + pick)

export const PHONE = { PRIOR_STRENGTH: 4, PROPENSITY_DRAWS: 400 };

export interface Stat {
  tried: number;
  left: number;
}

/** NudgeBank.posterior: the prior comes from this idea's results in OTHER moments, which start from the starting belief. */
export function posterior(global: Stat | undefined, local: Stat | undefined, start: number): [number, number] {
  const l = local ?? { tried: 0, left: 0 };
  const g = global ?? { tried: 0, left: 0 };
  const elsewhere = { tried: Math.max(0, g.tried - l.tried), left: Math.max(0, g.left - l.left) };
  const p = (elsewhere.left + STARTING_BELIEFS.strength * start) / (elsewhere.tried + STARTING_BELIEFS.strength);
  return [1 + PHONE.PRIOR_STRENGTH * p + l.left, 1 + PHONE.PRIOR_STRENGTH * (1 - p) + (l.tried - l.left)];
}

/** NudgeBank.pick: Thompson sampling, plus the chance of that choice (logged for off-policy evaluation). */
export function thompson(post: [number, number][], rnd: () => number, propensityDraws = PHONE.PROPENSITY_DRAWS): { chosen: number; propensity: number } {
  const draw = () => {
    let best = 0;
    let top = -1;
    post.forEach(([a, b], i) => {
      const v = sampleBeta(a, b, rnd);
      if (v > top) {
        top = v;
        best = i;
      }
    });
    return best;
  };
  const chosen = draw();
  let same = 0;
  for (let i = 0; i < propensityDraws; i++) if (draw() === chosen) same++;
  return { chosen, propensity: Math.max(same, 1) / propensityDraws };
}

// ---------------------------------------------------------------------------------------------------------------
// Simulated people

export interface Idea {
  id: string;
  tone: Tone;
  topic: Topic;
}

/** Six nudge ideas like the ones the night shift writes. */
export const IDEAS: Idea[] = [
  { id: 'next_step', tone: 'blunt', topic: 'task' },
  { id: 'own_goal', tone: 'calm', topic: 'goal' },
  { id: 'tomorrow_morning', tone: 'blunt', topic: 'cost' },
  { id: 'tonight_plan', tone: 'playful', topic: 'plan' },
  { id: 'small_dare', tone: 'dare', topic: 'other' },
  { id: 'what_for', tone: 'question', topic: 'other' },
];

const BANDS_USED: Band[] = ['afternoon', 'evening', 'night'];

export interface Person {
  /** Hidden chance of leaving the app, per band, per idea. */
  rate: Record<Band, number[]>;
  /** Their best idea at night differs from the daytime one. */
  nightDiffers: boolean;
}

const clamp = (x: number) => Math.min(0.9, Math.max(0.03, x));

function gauss(rnd: () => number): number {
  return Math.sqrt(-2 * Math.log(Math.max(rnd(), 1e-12))) * Math.cos(2 * Math.PI * rnd());
}

export function makePerson(rnd: () => number): Person {
  const base = 0.15 + rnd() * 0.3; // how easily they leave anyway (0.15 to 0.45)
  const ideas = IDEAS.map(() => base + gauss(rnd) * 0.05);
  const theirs = Math.floor(rnd() * IDEAS.length); // the idea that works on THEM, not on most people
  ideas[theirs] += 0.15 + rnd() * 0.15;
  const day = ideas.map(clamp);
  const nightDiffers = rnd() < 0.5;
  let night = day;
  if (nightDiffers) {
    let other = Math.floor(rnd() * (IDEAS.length - 1));
    if (other >= theirs) other++;
    night = ideas.map((r, i) => clamp(i === theirs ? r - 0.15 : i === other ? r + 0.2 : r));
  }
  return { rate: { morning: day, afternoon: day, evening: day, night }, nightDiffers };
}

// ---------------------------------------------------------------------------------------------------------------
// Part 1: does it find what works on each person?

export type Policy = 'life' | 'generic' | 'random' | 'oracle';

export interface Run {
  events: ExperimentEvent[];
  left: boolean[];
  /** What Life believes is their best idea in each band (by posterior mean), after each checkpoint. */
  believedBest: Record<Band, number>[];
}

function pickBand(rnd: () => number): Band {
  const r = rnd();
  return r < 0.25 ? 'afternoon' : r < 0.55 ? 'evening' : 'night';
}

const GENERIC = IDEAS.map((i) => startingBelief(i.tone, i.topic)).reduce((best, v, i, all) => (v > all[best] ? i : best), 0);

export function runPerson(p: Person, policy: Policy, nudges: number, rnd: () => number, checkpoints: number[] = [nudges]): Run {
  const global = IDEAS.map(() => ({ tried: 0, left: 0 }));
  const local: Record<string, Stat[]> = {};
  for (const b of BANDS_USED) local[b] = IDEAS.map(() => ({ tried: 0, left: 0 }));
  const events: ExperimentEvent[] = [];
  const left: boolean[] = [];
  const believedBest: Record<Band, number>[] = [];
  const believe = () => {
    const out = {} as Record<Band, number>;
    for (const b of BANDS_USED) {
      const post = IDEAS.map((idea, i) => posterior(global[i], local[b][i], startingBelief(idea.tone, idea.topic)));
      out[b] = post.map(([a, c]) => a / (a + c)).reduce((best, v, i, all) => (v > all[best] ? i : best), 0);
    }
    out.morning = out.afternoon;
    return out;
  };
  for (let n = 0; n < nudges; n++) {
    if (checkpoints.includes(n)) believedBest.push(believe());
    const band = pickBand(rnd);
    let chosen: number;
    let propensity = 1;
    if (policy === 'life') {
      const post = IDEAS.map((idea, i) => posterior(global[i], local[band][i], startingBelief(idea.tone, idea.topic)));
      ({ chosen, propensity } = thompson(post, rnd, 60));
    } else if (policy === 'random') {
      chosen = Math.floor(rnd() * IDEAS.length);
      propensity = 1 / IDEAS.length;
    } else if (policy === 'generic') {
      chosen = GENERIC;
    } else {
      chosen = p.rate[band].indexOf(Math.max(...p.rate[band]));
    }
    const didLeave = rnd() < p.rate[band][chosen];
    global[chosen].tried++;
    local[band][chosen].tried++;
    if (didLeave) {
      global[chosen].left++;
      local[band][chosen].left++;
    }
    left.push(didLeave);
    const idea = IDEAS[chosen];
    events.push({
      id: `n${n}`, day: '2026-11-01', time: band === 'night' ? '23:30' : band === 'evening' ? '19:30' : '15:00', app: 'TikTok',
      arm: 'goal', explore: false, reason: 'over', left: didLeave, seconds_after: 0, window_seconds: 120, demo: false,
      propensity, context: band, angle: idea.id, tone: idea.tone, topic: idea.topic,
    });
  }
  if (checkpoints.includes(nudges)) believedBest.push(believe());
  return { events, left, believedBest };
}

const mean = (xs: number[]) => (xs.length ? xs.reduce((a, b) => a + b, 0) / xs.length : 0);
const rate = (xs: boolean[]) => mean(xs.map((x) => (x ? 1 : 0)));

/** Blocks of nudges, read as weeks: about 30 nudges a week (Life sends at most 4 per app a day). */
export const BLOCKS: { label: string; from: number; to: number }[] = [
  { label: 'Nudges 1-30', from: 0, to: 30 },
  { label: '31-60', from: 30, to: 60 },
  { label: '61-120', from: 60, to: 120 },
  { label: '121-240', from: 120, to: 240 },
];

export interface LearningResult {
  people: number;
  nudges: number;
  /** Leave rate per block of nudges, per policy. */
  blocks: Record<Policy, number[]>;
  /** Share of people whose best idea Life names correctly, after each block. */
  foundBest: number[];
  /** The same at night, for the people whose best idea at night is different. */
  foundNightBest: number[];
  /** Share whose best idea is NOT the one that works for most people (so a fixed app never finds it). */
  notGeneric: number;
}

export function learning(people: number, blocks = BLOCKS, seed = 1): LearningResult {
  const nudges = blocks[blocks.length - 1].to;
  const checkpoints = blocks.map((b) => b.to);
  const policies: Policy[] = ['life', 'generic', 'random', 'oracle'];
  const all: Record<Policy, boolean[][]> = { life: [], generic: [], random: [], oracle: [] };
  const found = blocks.map(() => 0);
  const foundNight = blocks.map(() => 0);
  let differs = 0;
  let notGeneric = 0;
  const makeRnd = mulberry32(seed);
  for (let k = 0; k < people; k++) {
    const p = makePerson(makeRnd);
    const bestDay = p.rate.afternoon.indexOf(Math.max(...p.rate.afternoon));
    const bestNight = p.rate.night.indexOf(Math.max(...p.rate.night));
    if (bestDay !== GENERIC) notGeneric++;
    if (p.nightDiffers) differs++;
    for (const policy of policies) {
      // the same seed for every policy, so they face the same luck
      const r = runPerson(p, policy, nudges, mulberry32(seed * 1000 + k), checkpoints);
      all[policy].push(r.left);
      if (policy === 'life') {
        r.believedBest.forEach((b, i) => {
          if (b.evening === bestDay) found[i]++;
          if (p.nightDiffers && b.night === bestNight) foundNight[i]++;
        });
      }
    }
  }
  const out = {} as Record<Policy, number[]>;
  for (const policy of policies) out[policy] = blocks.map((b) => mean(all[policy].map((l) => rate(l.slice(b.from, b.to)))));
  return {
    people, nudges, blocks: out,
    foundBest: found.map((f) => f / people),
    foundNightBest: foundNight.map((f) => (differs ? f / differs : 0)),
    notGeneric: notGeneric / people,
  };
}

// ---------------------------------------------------------------------------------------------------------------
// Part 2: are theories judged right? (Life's real judge() on the logs from part 1)

export interface TheoryResult {
  theories: number;
  kept: number;
  keptTrue: number;
  rejected: number;
  rejectedFalse: number;
  testing: number;
  /** Theories that were clearly false: how many the code still kept (a model on its own would keep them all). */
  clearlyFalse: number;
  clearlyFalseKept: number;
}

export function theories(people: number, nudges: number, seed = 2): TheoryResult {
  const r: TheoryResult = { theories: 0, kept: 0, keptTrue: 0, rejected: 0, rejectedFalse: 0, testing: 0, clearlyFalse: 0, clearlyFalseKept: 0 };
  const makeRnd = mulberry32(seed);
  for (let k = 0; k < people; k++) {
    const p = makePerson(makeRnd);
    const { events } = runPerson(p, 'life', nudges, mulberry32(seed * 1000 + k));
    for (const bands of [undefined, ['night'] as Band[]]) {
      const moments = events.filter((e) => !bands || bands.includes(e.context!));
      for (let i = 0; i < IDEAS.length; i++) {
        // the truth, for the comparison the judge makes: this idea vs the mix of other ideas actually sent there
        const mine = moments.filter((e) => e.angle === IDEAS[i].id);
        const others = moments.filter((e) => e.angle !== IDEAS[i].id);
        if (!mine.length || !others.length) continue;
        const trueMine = mean(mine.map((e) => p.rate[e.context!][i]));
        const trueOthers = mean(others.map((e) => p.rate[e.context!][IDEAS.findIndex((x) => x.id === e.angle)]));
        const isTrue = trueMine > trueOthers;
        const v = judge(bands ? { bands } : {}, { angle: IDEAS[i].id }, events);
        r.theories++;
        if (v.status === 'kept') {
          r.kept++;
          if (isTrue) r.keptTrue++;
        } else if (v.status === 'rejected') {
          r.rejected++;
          if (!isTrue) r.rejectedFalse++;
        } else r.testing++;
        if (trueMine < trueOthers - 0.1) {
          r.clearlyFalse++;
          if (v.status === 'kept') r.clearlyFalseKept++;
        }
      }
    }
  }
  return r;
}

// ---------------------------------------------------------------------------------------------------------------
// Part 3: does the "independent second opinion" (off-policy evaluation, Life's real evaluatePolicy) tell the truth?

export interface OpeResult {
  people: number;
  nudges: number;
  meanError: number;
  sameBest: number;
}

export function offPolicy(people: number, nudges: number, seed = 3): OpeResult {
  const makeRnd = mulberry32(seed);
  const errors: number[] = [];
  let same = 0;
  let counted = 0;
  for (let k = 0; k < people; k++) {
    // three styles, as in the live style test (next task, what it costs, own goal)
    const base = 0.2 + makeRnd() * 0.25;
    const truth = ARMS.map(() => clamp(base + gauss(makeRnd) * 0.1));
    const rnd = mulberry32(seed * 1000 + k);
    const stats = ARMS.map(() => ({ tried: 0, left: 0 }));
    const events: ExperimentEvent[] = [];
    for (let n = 0; n < nudges; n++) {
      const post = stats.map((s) => [1 + s.left, 1 + s.tried - s.left] as [number, number]);
      const { chosen, propensity } = thompson(post, rnd, 200);
      const didLeave = rnd() < truth[chosen];
      stats[chosen].tried++;
      if (didLeave) stats[chosen].left++;
      events.push({
        id: `o${n}`, day: '2026-11-01', time: '22:00', app: 'TikTok', arm: ARMS[chosen] as Arm, explore: false, reason: 'over',
        left: didLeave, seconds_after: 0, window_seconds: 120, demo: false, propensity,
      });
    }
    const ev = evaluatePolicy(events);
    if (!ev) continue;
    counted++;
    ev.fixed.forEach((f, i) => {
      if (f.estimate !== null && f.effective_n >= 5) errors.push(Math.abs(f.estimate - truth[i]));
    });
    const trueBest = ARMS[truth.indexOf(Math.max(...truth))];
    if (ev.best_fixed?.arm === trueBest) same++;
  }
  return { people: counted, nudges, meanError: mean(errors), sameBest: counted ? same / counted : 0 };
}

// ---------------------------------------------------------------------------------------------------------------
// Part 4: do the guards stop bad lines? A hand-written set of drafts, each with the right answer.

export interface Draft {
  text: string;
  bad: boolean;
  why: string;
  check: 'line' | 'moment' | 'reminder';
}

const MOMENT_FACTS = { opened_for: 'Chrome', since_unlock: '14 minutes ago', since_then: 'TikTok' };
const MOMENT_FALLBACK = 'You picked up your phone for Chrome 14 minutes ago. Since then: TikTok.';
const ASK = '10 push-ups';

export const DRAFTS: Draft[] = [
  // night-shift bank lines (lineProblem)
  { check: 'line', bad: false, why: 'fine', text: 'Your chapter is still open. One page, then decide.' },
  { check: 'line', bad: false, why: 'fine', text: 'The gym bag is packed. Tomorrow-you says thanks.' },
  { check: 'line', bad: false, why: 'fine', text: 'Dare: close it before this video ends.' },
  { check: 'line', bad: false, why: 'fine', text: 'What did you open the phone for?' },
  { check: 'line', bad: false, why: 'fine', text: '{task} is waiting. Two minutes to start it.' },
  { check: 'line', bad: false, why: 'fine', text: 'TikTok will be here tomorrow. Your plan will not wait.' },
  { check: 'line', bad: true, why: 'invents a statistic', text: "You've spent 45 minutes here already." },
  { check: 'line', bad: true, why: 'invents a statistic', text: 'That is 2 hours gone tonight.' },
  { check: 'line', bad: true, why: 'reads like a meter', text: "You're at your daily TikTok budget." },
  { check: 'line', bad: true, why: 'reads like a meter', text: 'Past your limit again, champ.' },
  { check: 'line', bad: true, why: 'health language', text: 'This looks like an addiction pattern.' },
  { check: 'line', bad: true, why: 'health language', text: 'Scrolling feeds anxiety. Put it down.' },
  { check: 'line', bad: true, why: 'health language', text: 'Doomscrolling is linked to depression.' },
  { check: 'line', bad: true, why: 'too long', text: 'Remember that every single minute you spend scrolling here is a minute you are not spending on the things you care about most.' },
  { check: 'line', bad: true, why: 'more than one line', text: 'Stop.\nGo study.' },
  { check: 'line', bad: true, why: 'the old template', text: 'Sam, you said you would study tonight.' },
  { check: 'line', bad: true, why: 'repeats a line already sent', text: 'Your chapter is waiting for you.' },
  // moments (numbersBacked): every number must be one of the phone's facts
  { check: 'moment', bad: false, why: 'fine', text: 'Came for Chrome 14 minutes ago. Did TikTok sneak in?' },
  { check: 'moment', bad: false, why: 'fine', text: 'Chrome first, then TikTok. What were you looking up?' },
  { check: 'moment', bad: true, why: 'invents a number', text: 'Came for Chrome 20 minutes ago. TikTok took over.' },
  { check: 'moment', bad: true, why: 'invents a number', text: 'This is your 5th TikTok detour today.' },
  { check: 'moment', bad: true, why: 'invents a time', text: 'Chrome at 21:40, TikTok since. Back to it?' },
  // the user's own reminder (mentionsAsk): it must say what they asked for
  { check: 'reminder', bad: false, why: 'fine', text: 'Time for those 10 push-ups. Floor is right there.' },
  { check: 'reminder', bad: false, why: 'fine', text: 'Push-ups break: you asked for it.' },
  { check: 'reminder', bad: true, why: 'drifts to something else', text: 'Your exam is coming. Back to studying?' },
  { check: 'reminder', bad: true, why: 'drifts to something else', text: 'An hour in. Maybe call it a night.' },
];

const USED = new Set(['your chapter is waiting for you']);

export function caught(d: Draft): boolean {
  if (d.check === 'line') return lineProblem(d.text, USED, 'Sam') !== null;
  if (d.check === 'moment') return !numbersBacked(d.text, MOMENT_FACTS, MOMENT_FALLBACK);
  return !mentionsAsk(d.text, ASK);
}

export interface GuardResult {
  bad: number;
  stopped: number;
  good: number;
  wronglyStopped: number;
  missed: Draft[];
}

export function guards(): GuardResult {
  const bad = DRAFTS.filter((d) => d.bad);
  const good = DRAFTS.filter((d) => !d.bad);
  const missed = bad.filter((d) => !caught(d));
  return { bad: bad.length, stopped: bad.length - missed.length, good: good.length, wronglyStopped: good.filter(caught).length, missed };
}
