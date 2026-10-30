import assert from 'node:assert/strict';
import { test } from 'node:test';

import { evaluatePolicy, parseExperimentLog, summarizeExperiments } from '../supabase/functions/_shared/experiments.ts';
import type { Arm, Band, ExperimentEvent } from '../supabase/functions/_shared/experiments.ts';

let seed = 11;
const rnd = () => {
  seed = (seed * 16807) % 2147483647;
  return seed / 2147483647;
};

const ev = (i: number, arm: Arm, left: boolean, propensity: number, over: Partial<ExperimentEvent> = {}): ExperimentEvent => ({
  id: `e${i}`,
  day: '2026-10-29',
  time: '21:10',
  app: 'TikTok',
  arm,
  explore: false,
  reason: 'limit',
  left,
  seconds_after: left ? 20 : 540,
  window_seconds: 900,
  demo: false,
  propensity,
  context: 'night',
  ...over,
});

test('off-policy evaluation recovers each fixed style from biased logging (inverse propensity weighting)', () => {
  // The true chance of leaving after each style; the logging policy strongly prefers "task", the worst one.
  const truth: Record<Arm, number> = { task: 0.3, cost: 0.7, goal: 0.5 };
  const policy: Record<Arm, number> = { task: 0.7, cost: 0.1, goal: 0.2 };
  const events: ExperimentEvent[] = [];
  for (let i = 0; i < 6000; i++) {
    const u = rnd();
    const arm: Arm = u < 0.7 ? 'task' : u < 0.8 ? 'cost' : 'goal';
    events.push(ev(i, arm, rnd() < truth[arm], policy[arm]));
  }
  const p = evaluatePolicy(events)!;
  for (const f of p.fixed) assert.ok(Math.abs(f.estimate! - truth[f.arm]) < 0.04, `${f.arm}: ${f.estimate} vs ${truth[f.arm]}`);
  assert.equal(p.best_fixed?.arm, 'cost');
  // the naive average is biased towards the over-picked style; the random-policy estimate is the mean of the truths
  assert.ok(Math.abs(p.life_rate - (0.7 * 0.3 + 0.1 * 0.7 + 0.2 * 0.5)) < 0.03);
  assert.ok(Math.abs(p.random! - 0.5) < 0.04);
  assert.ok(p.lift! < 0, 'this logging policy is worse than always sending "cost"');
  assert.ok(p.lift_interval![0] <= p.lift! && p.lift! <= p.lift_interval![1]);
});

test('a policy that learned the right style beats every fixed one, and the interval says how sure that is', () => {
  // Context matters: "cost" works at night, "task" in the afternoon; a fixed style is right only half the time.
  const events: ExperimentEvent[] = [];
  for (let i = 0; i < 1200; i++) {
    const night = i % 2 === 0;
    const good: Arm = night ? 'cost' : 'task';
    const explore = rnd() < 0.2;
    const arm: Arm = explore ? (rnd() < 0.5 ? (night ? 'task' : 'cost') : 'goal') : good;
    const p = arm === good ? 0.8 : 0.1;
    events.push(ev(i, arm, rnd() < (arm === good ? 0.8 : 0.2), p, { context: night ? 'night' : 'afternoon', time: night ? '22:00' : '14:00' }));
  }
  const p = evaluatePolicy(events)!;
  assert.ok(p.lift! > 0.1 && p.lift! < 0.26, `lift ${p.lift} (true lift 0.18)`);
  assert.ok(p.lift_interval![0] > 0, `interval ${p.lift_interval}`);
  const s = summarizeExperiments(events);
  const at = (band: Band) => s.contexts.find((c) => c.band === band)!;
  assert.equal(at('night').leading, 'cost');
  assert.equal(at('afternoon').leading, 'task');
});

test('too little data: no policy evaluation; events without a propensity are not evaluated', () => {
  assert.equal(evaluatePolicy(Array.from({ length: 9 }, (_, i) => ev(i, 'task', true, 0.5))), null);
  const old = Array.from({ length: 12 }, (_, i) => ({ ...ev(i, 'task', true, 0.5), propensity: undefined }));
  assert.equal(evaluatePolicy(old), null);
});

test('the lab notebook lists the newest nudges first with their words, why they were picked and what happened', () => {
  const s = summarizeExperiments([
    ev(1, 'task', false, 0.62, { message: 'Ayoub, German is waiting.', time: '21:00' }),
    ev(2, 'cost', true, 0.21, { message: 'That is 2 hours of TikTok.', time: '21:30', explore: true }),
  ]);
  assert.deepEqual(s.log[0], {
    day: '2026-10-29', time: '21:30', app: 'TikTok', band: 'night', arm: 'cost', label: 'nudges with what the time costs',
    explore: true, propensity: 0.21, message: 'That is 2 hours of TikTok.', angle: null, pulled: false, left: true, minutes_after: 0.3, demo: false,
  });
  assert.equal(s.log[1].minutes_after, 9);
});

test('the phone log may carry the propensity, the moment and the message, and they are checked', () => {
  const base = { id: 'a', day: '2026-10-29', time: '21:10', app: 'TikTok', arm: 'task', explore: false, reason: 'limit', left: true, seconds_after: 10, window_seconds: 900, demo: false };
  const ok = parseExperimentLog([{ ...base, propensity: 0.4, context: 'night', message: 'Hi' }])[0];
  assert.equal(ok.propensity, 0.4);
  assert.equal(ok.context, 'night');
  for (const bad of [{ propensity: 0 }, { propensity: 1.2 }, { context: 'dawn' }, { message: 'x'.repeat(301) }]) {
    assert.throws(() => parseExperimentLog([{ ...base, ...bad }]));
  }
});
