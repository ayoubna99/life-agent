import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';

import { BLOCKS, guards, IDEAS, learning, offPolicy, PHONE, posterior, theories } from '../bench/bench.ts';
import { STARTING_BELIEFS } from '../supabase/functions/_shared/theories.ts';

const bank = readFileSync(new URL('../app/android/app/src/main/kotlin/org/ngdev/life_agent/core/Bank.kt', import.meta.url), 'utf8');

test('the benchmark mirror uses the same constants and formula as the phone (core/Bank.kt)', () => {
  assert.match(bank, new RegExp(`PRIOR_STRENGTH = ${PHONE.PRIOR_STRENGTH}\\.0`));
  assert.match(bank, new RegExp(`PROPENSITY_DRAWS = ${PHONE.PROPENSITY_DRAWS}\\b`));
  assert.match(bank, new RegExp(`STRENGTH = ${STARTING_BELIEFS.strength}\\.0`));
  for (const [tone, v] of Object.entries(STARTING_BELIEFS.tone)) assert.match(bank, new RegExp(`"${tone}" to ${v.toFixed(2).replace(/0$/, '')}`));
  assert.match(bank, /\(elsewhere\.left \+ StartingBeliefs\.STRENGTH \* start\) \/ \(elsewhere\.tried \+ StartingBeliefs\.STRENGTH\)/);
  // no data: the prior is the starting belief, worth PRIOR_STRENGTH nudges
  const [a, b] = posterior(undefined, undefined, 0.3);
  assert.ok(Math.abs(a - (1 + 4 * 0.3)) < 1e-9 && Math.abs(b - (1 + 4 * 0.7)) < 1e-9);
  assert.equal(IDEAS.length, 6);
});

test('benchmark: Life learns (beats a fixed app and random, and improves over time)', () => {
  const L = learning(40, BLOCKS.slice(0, 3));
  const last = L.blocks.life.length - 1;
  assert.ok(L.blocks.life[last] > L.blocks.generic[last] + 0.03, JSON.stringify(L.blocks));
  assert.ok(L.blocks.life[last] > L.blocks.random[last] + 0.03);
  assert.ok(L.blocks.life[last] > L.blocks.life[0]);
  assert.ok(L.blocks.oracle[last] > L.blocks.life[last]);
  assert.ok(L.foundBest[last] > L.foundBest[0]);
});

test('benchmark: theories the code keeps are mostly true, and clearly false ones are almost never kept', () => {
  const T = theories(30, 60);
  assert.ok(T.kept > 0 && T.keptTrue / T.kept >= 0.6, JSON.stringify(T));
  assert.ok(T.clearlyFalse > 0 && T.clearlyFalseKept / T.clearlyFalse <= 0.05);
});

test('benchmark: off-policy evaluation recovers the true rates within a few points on average', () => {
  const O = offPolicy(30, 70);
  assert.ok(O.meanError < 0.15, JSON.stringify(O));
  assert.ok(O.sameBest > 0.4);
});

test('benchmark: every bad draft in the set is stopped, and no good one', () => {
  const G = guards();
  assert.equal(G.stopped, G.bad, JSON.stringify(G.missed));
  assert.equal(G.wronglyStopped, 0);
});
