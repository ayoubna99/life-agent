// Theories the night shift proposes are JUDGED BY CODE on the person's own results, never by the model.
//
// A theory is a falsifiable claim in a fixed shape: "in these moments (when), nudges with this property (test) get the
// person off the app more often than the other nudges in the same moments". Code takes the logged nudges that match
// `when`, splits them into those that match `test` and the rest, gives each group a Beta(1 + left, 1 + stayed)
// posterior, and computes P(the matching group really does better) from 4000 seeded joint draws. That probability is
// the theory's confidence; at least 3 tries on each side decide "kept" (>= 0.9) or "rejected" (<= 0.1), otherwise it
// stays "testing". The counts in the evidence are counted by code. The model's own guess is kept only to show where
// the data overruled it.
//
// Starting beliefs: before the person has any results, each idea starts from a small assumption about what tends to
// work for most people (STARTING_BELIEFS, worth 3 nudges). Their own results outweigh it within a day or two. The same
// slot can later take anonymous totals from all Life users. The phone has the same table (core/Bank.kt).

import { ARMS, BANDS, DAY_TYPES, DEPTHS, TONES, TOPICS, mulberry32, sampleBeta } from './experiments.ts';
import type { Arm, Band, DayType, Depth, ExperimentEvent, Tone, Topic } from './experiments.ts';

export interface TheoryWhen {
  apps?: string[];
  bands?: Band[];
  day_type?: DayType;
  depth?: Depth[];
  task_soon?: boolean;
}

export interface TheoryTest {
  tone?: Tone;
  topic?: Topic;
  style?: Arm;
  angle?: string;
}

export interface Counts {
  tried: number;
  left: number;
}

export interface Verdict {
  status: 'testing' | 'kept' | 'rejected';
  /** P(nudges matching the test do better in these moments), from the data alone. */
  confidence: number;
  evidence: string;
  matching: Counts;
  others: Counts;
}

export const THEORY = { draws: 4000, minEach: 3, keep: 0.9, reject: 0.1 };

/** What tends to work for most people, as starting assumptions (not facts): the chance a nudge gets someone to leave. */
export const STARTING_BELIEFS = {
  strength: 3,
  tone: { blunt: 0.35, dare: 0.33, playful: 0.3, calm: 0.28, question: 0.25 } as Record<Tone, number>,
  topic: { task: 0.35, plan: 0.33, goal: 0.32, sleep: 0.3, cost: 0.27, other: 0.25 } as Record<Topic, number>,
  why: [
    'A concrete next step tends to beat general advice.',
    'Short and direct tends to beat long and polite.',
    'Guilt and numbers tend to be ignored after the first time.',
    'Questions are easy to answer with "one more video".',
  ],
};

/** The starting chance for an idea with this tone and topic. */
export function startingBelief(tone: Tone | undefined, topic: Topic | undefined): number {
  return ((tone ? STARTING_BELIEFS.tone[tone] : 0.28) + (topic ? STARTING_BELIEFS.topic[topic] : 0.28)) / 2;
}

const pick = <T>(v: unknown, all: readonly T[]): T | undefined => (all.includes(v as T) ? (v as T) : undefined);

/** Reads the model's `when` and `test`, keeping only known values. Null when the test says nothing testable. */
export function parseTheoryShape(rawWhen: unknown, rawTest: unknown): { when: TheoryWhen; test: TheoryTest } | null {
  const w = (rawWhen ?? {}) as Record<string, unknown>;
  const t = (rawTest ?? {}) as Record<string, unknown>;
  const when: TheoryWhen = {};
  const apps = Array.isArray(w.apps) ? w.apps.filter((a): a is string => typeof a === 'string' && a.trim() !== '').map((a) => a.trim().slice(0, 40)).slice(0, 6) : [];
  if (apps.length) when.apps = apps;
  const bands = Array.isArray(w.bands) ? w.bands.filter((b): b is Band => BANDS.includes(b as Band)) : [];
  if (bands.length) when.bands = [...new Set(bands)];
  const dayType = pick(w.day_type, DAY_TYPES);
  if (dayType) when.day_type = dayType;
  const depth = Array.isArray(w.depth) ? w.depth.filter((d): d is Depth => DEPTHS.includes(d as Depth)) : [];
  if (depth.length) when.depth = [...new Set(depth)];
  if (typeof w.task_soon === 'boolean') when.task_soon = w.task_soon;
  const test: TheoryTest = {};
  const tone = pick(t.tone, TONES);
  if (tone) test.tone = tone;
  const topic = pick(t.topic, TOPICS);
  if (topic) test.topic = topic;
  const style = pick(t.style, ARMS);
  if (style) test.style = style;
  if (typeof t.angle === 'string' && /^[a-z0-9_-]{1,40}$/.test(t.angle)) test.angle = t.angle;
  return Object.keys(test).length ? { when, test } : null;
}

export function inMoment(e: ExperimentEvent, w: TheoryWhen): boolean {
  if (w.apps && !w.apps.some((a) => a.toLowerCase() === e.app.toLowerCase())) return false;
  if (w.bands && (!e.context || !w.bands.includes(e.context))) return false;
  if (w.day_type && e.day_type !== w.day_type) return false;
  if (w.depth && (!e.depth || !w.depth.includes(e.depth))) return false;
  if (w.task_soon !== undefined && e.task_soon !== w.task_soon) return false;
  return true;
}

export function passesTest(e: ExperimentEvent, t: TheoryTest): boolean {
  if (t.tone && e.tone !== t.tone) return false;
  if (t.topic && e.topic !== t.topic) return false;
  if (t.style && e.arm !== t.style) return false;
  if (t.angle && e.angle !== t.angle) return false;
  return true;
}

/** "TikTok, at night, on weekdays, way over the limit, with a task coming up" */
export function describeMoment(w: TheoryWhen): string {
  const parts: string[] = [];
  if (w.apps) parts.push(w.apps.join('/'));
  if (w.bands) parts.push(w.bands.map((b) => (b === 'night' ? 'at night' : `in the ${b}`)).join(' or '));
  if (w.day_type) parts.push(w.day_type === 'weekday' ? 'on weekdays' : 'at weekends');
  if (w.depth) parts.push(w.depth.map((d) => d.replace('_', ' ')).join(' or '));
  if (w.task_soon !== undefined) parts.push(w.task_soon ? 'with a task coming up' : 'with no task coming up');
  return parts.length ? parts.join(', ') : 'all moments';
}

const count = (list: ExperimentEvent[]): Counts => ({ tried: list.length, left: list.filter((e) => e.left).length });

/** P(group a's leave rate > group b's), both Beta(1 + left, 1 + stayed), from seeded joint draws. */
export function probabilityBetter(a: Counts, b: Counts, draws = THEORY.draws, seed = 11): number {
  const rnd = mulberry32(seed);
  let wins = 0;
  for (let i = 0; i < draws; i++) {
    if (sampleBeta(a.left + 1, a.tried - a.left + 1, rnd) > sampleBeta(b.left + 1, b.tried - b.left + 1, rnd)) wins++;
  }
  return Math.round((wins / draws) * 100) / 100;
}

/** The verdict on one theory from the logged nudges (live and from the bank alike). */
export function judge(when: TheoryWhen, test: TheoryTest, events: ExperimentEvent[]): Verdict {
  const moments = events.filter((e) => inMoment(e, when));
  const matching = count(moments.filter((e) => passesTest(e, test)));
  const others = count(moments.filter((e) => !passesTest(e, test)));
  const confidence = probabilityBetter(matching, others);
  const enough = matching.tried >= THEORY.minEach && others.tried >= THEORY.minEach;
  const status = !enough ? 'testing' : confidence >= THEORY.keep ? 'kept' : confidence <= THEORY.reject ? 'rejected' : 'testing';
  const where = describeMoment(when);
  const evidence = matching.tried + others.tried === 0
    ? `Not tried yet (${where})`
    : `Left ${matching.left}/${matching.tried} with it vs ${others.left}/${others.tried} without (${where})${enough ? '' : '; needs 3+ of each'}`;
  return { status, confidence, evidence, matching, others };
}
