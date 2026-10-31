import assert from 'node:assert/strict';
import { test } from 'node:test';

import type { ExperimentEvent } from '../supabase/functions/_shared/experiments.ts';
import { validateShift } from '../supabase/functions/_shared/nightshift.ts';
import { describeMoment, judge, parseTheoryShape, probabilityBetter, startingBelief, STARTING_BELIEFS } from '../supabase/functions/_shared/theories.ts';

let n = 0;
const ev = (o: Partial<ExperimentEvent>): ExperimentEvent => ({
  id: `e${n++}`, day: '2026-10-29', time: '23:10', app: 'TikTok', arm: 'goal', explore: false, reason: 'over', left: false,
  seconds_after: 300, window_seconds: 900, demo: false, context: 'night', day_type: 'weekday', depth: 'way_over', task_soon: true,
  tone: 'calm', topic: 'other', ...o,
});

// TikTok at night: blunt lines work (5 of 6), the rest do not (1 of 6). In the morning it is the other way round.
const data = [
  ...Array.from({ length: 6 }, (_, i) => ev({ tone: 'blunt', left: i < 5 })),
  ...Array.from({ length: 6 }, (_, i) => ev({ tone: 'question', left: i < 1 })),
  ...Array.from({ length: 6 }, (_, i) => ev({ context: 'morning', tone: 'blunt', left: i < 1 })),
  ...Array.from({ length: 6 }, (_, i) => ev({ context: 'morning', tone: 'playful', left: i < 5 })),
];

test('code, not the model, decides: blunt works on TikTok at night (kept) but not in the morning (rejected)', () => {
  const night = judge({ apps: ['tiktok'], bands: ['night'] }, { tone: 'blunt' }, data);
  assert.equal(night.status, 'kept');
  assert.ok(night.confidence >= 0.95);
  assert.deepEqual([night.matching, night.others], [{ tried: 6, left: 5 }, { tried: 6, left: 1 }]);
  assert.equal(night.evidence, 'Left 5/6 with it vs 1/6 without (tiktok, at night)');

  const morning = judge({ bands: ['morning'] }, { tone: 'blunt' }, data);
  assert.equal(morning.status, 'rejected');
  assert.ok(morning.confidence <= 0.05);

  // the same claim over all moments mixes both: not decided
  assert.equal(judge({}, { tone: 'blunt' }, data).status, 'testing');
});

test('too little data stays "testing", whatever the numbers look like', () => {
  const v = judge({ bands: ['night'] }, { tone: 'blunt' }, data.slice(0, 2).concat(data.slice(6, 8)));
  assert.equal(v.status, 'testing');
  assert.match(v.evidence, /needs 3\+ of each/);
  assert.equal(judge({ day_type: 'weekend' }, { tone: 'blunt' }, data).evidence, 'Not tried yet (at weekends)');
});

test('the model\'s own verdict is overruled by the data', () => {
  const s = validateShift({
    theories: [{ id: 'q', statement: 'Questions work best at night', when: { bands: ['night'] }, test: { tone: 'question' }, status: 'kept', confidence: 0.95 }],
    angles: [{ id: 'a', name: 'A', tone: 'shouty', topic: 'gym', lines: ['One page. I dare you.'] }],
  }, '2026-10-30', new Set(), undefined, data);
  const t = s.theories[0];
  assert.equal(t.status, 'rejected');
  assert.deepEqual(t.model_said, { status: 'kept', confidence: 0.95 });
  assert.equal(s.angles[0].tone, 'calm', 'unknown tags fall back to neutral ones');
  assert.equal(s.angles[0].topic, 'other');
});

test('theory shapes: only known moments and properties; nothing testable means no theory', () => {
  assert.deepEqual(parseTheoryShape({ bands: ['night', 'dusk'], depth: ['way_over'], task_soon: true, mood: 'x' }, { tone: 'blunt', vibe: 1 }), {
    when: { bands: ['night'], depth: ['way_over'], task_soon: true },
    test: { tone: 'blunt' },
  });
  assert.equal(parseTheoryShape({}, { vibe: 'good' }), null);
  assert.equal(describeMoment({ apps: ['TikTok'], bands: ['night'], day_type: 'weekday', depth: ['way_over'], task_soon: true }), 'TikTok, at night, on weekdays, way over, with a task coming up');
  assert.ok(probabilityBetter({ tried: 0, left: 0 }, { tried: 0, left: 0 }) > 0.4);
});

test('starting assumptions are small and favour concrete, blunt lines over questions', () => {
  assert.ok(startingBelief('blunt', 'task') > startingBelief('question', 'other'));
  assert.equal(STARTING_BELIEFS.strength, 3);
  assert.equal(startingBelief(undefined, undefined), 0.28);
});
