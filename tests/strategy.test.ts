import assert from 'node:assert/strict';
import { test } from 'node:test';

import { handle } from '../supabase/functions/_shared/http.ts';
import { runChat } from '../supabase/functions/_shared/loop.ts';
import type { ChatRequest } from '../supabase/functions/_shared/loop.ts';
import { parseExperimentLog, probabilityBest, sampleBeta, summarizeExperiments } from '../supabase/functions/_shared/experiments.ts';
import type { ExperimentEvent } from '../supabase/functions/_shared/experiments.ts';
import { validateStrategy } from '../supabase/functions/_shared/strategy.ts';
import { runServerTool } from '../supabase/functions/_shared/tools.ts';
import type { ToolEnv } from '../supabase/functions/_shared/tools.ts';
import { callsReply, cfg, fakeNet, jwt, MemoryStore, SUPABASE_URL, textReply, USER } from './helpers.ts';

const good = {
  limits: [{ app: 'Instagram', minutes: 20, why: '74 min vs 30 limit, 21:00-23:00' }],
  plan_style: { max_tasks: 3, buffer_pct: 30, best_window: '09:00-12:00' },
  risk_windows: ['21:00-23:00'],
  rules: ['Max 3 tasks', 'Schedule an alarm at 20:45'],
  changes: ['Cut Instagram limit 30 to 20', 'Reduced plan from 5 tasks to 3'],
  evidence: ['Finished 3 of 5 tasks on each of the last 2 days'],
};

test('a strategy is checked: no change without evidence, every change cites a number, and the sizes are bounded', () => {
  const ok = validateStrategy(good);
  assert.equal(ok.ok, true);
  const bad = (patch: Record<string, unknown>, re: RegExp) => {
    const r = validateStrategy({ ...good, ...patch });
    assert.equal(r.ok, false);
    assert.match(!r.ok ? r.error : '', re);
  };
  bad({ evidence: [] }, /needs evidence/);
  bad({ changes: ['Be more careful'] }, /cite a number/);
  bad({ evidence: ['You seemed tired'] }, /number/);
  bad({ changes: ['a 1', 'b 2', 'c 3', 'd 4'] }, /at most 3/);
  bad({ rules: ['1', '2', '3', '4', '5', '6'] }, /at most 5/);
  bad({ risk_windows: ['evening'] }, /21:00-23:00/);
  bad({ plan_style: { max_tasks: 0 } }, /max_tasks/);
  bad({ limits: [{ app: 'TikTok', minutes: 2 }] }, /5 to 720/);
  // keeping the strategy (no changes) needs no evidence
  assert.equal(validateStrategy({ ...good, changes: [], evidence: [] }).ok, true);
});

const env = (store: MemoryStore, over: Partial<ToolEnv> = {}): ToolEnv => ({
  store,
  mode: 'review',
  today: '2026-10-29',
  planDate: '2026-10-30',
  supabaseUrl: SUPABASE_URL,
  fetchImpl: fetch,
  randomId: () => 'r',
  ...over,
});

test('save_strategy keeps every version, takes the day from the app, returns the changes; get_strategy reads the newest', async () => {
  const store = new MemoryStore();
  assert.equal(JSON.parse((await runServerTool('get_strategy', {}, env(store))).content).strategy, null);
  const out = await runServerTool('save_strategy', good, env(store));
  assert.deepEqual(out.strategy, { version: 1, changes: good.changes });
  const again = await runServerTool('save_strategy', { ...good, changes: ['Cut TikTok limit 40 to 30'] }, env(store, { planDate: '2026-10-31' }));
  assert.deepEqual(again.strategy, { version: 2, changes: ['Cut TikTok limit 40 to 30'] });
  assert.deepEqual(store.strategies.map((s) => [s.version, s.for_date]), [[1, '2026-10-30'], [2, '2026-10-31']]);
  const r = JSON.parse((await runServerTool('get_strategy', {}, env(store))).content);
  assert.equal(r.strategy.version, 2);
  assert.deepEqual(r.strategy.plan_style, good.plan_style);

  const refused = await runServerTool('save_strategy', { ...good, evidence: [] }, env(store));
  assert.match(JSON.parse(refused.content).error, /evidence/);
  assert.equal(refused.strategy, undefined);
  assert.equal(store.strategies.length, 2);
});

const req = (over: Partial<ChatRequest> = {}): ChatRequest => ({
  mode: 'review',
  today: '2026-10-29',
  date: '2026-10-30',
  input: { type: 'user', text: 'Review my day.' },
  ...over,
});

test('review: the agent saves a strategy and the reply carries its changes for the "Strategy updated" card', async () => {
  const store = new MemoryStore();
  const net = fakeNet([callsReply(['save_strategy', good]), textReply('I cut Instagram to 20 minutes and kept tomorrow to 3 tasks.\nSPOKEN: I adjusted tomorrow.')]);
  const r = await runChat(req(), { cfg, store, userId: USER, supabaseUrl: SUPABASE_URL, dailyLimit: 80, globalLimit: 1000, fetchImpl: net.fetchImpl });
  assert.equal(r.type, 'text');
  assert.deepEqual(r.strategy_update, { version: 1, changes: good.changes });
  assert.equal(store.strategies[0].for_date, '2026-10-30');
});

test('planning and execute see the current strategy in the prompt, with how to apply it', async () => {
  const store = new MemoryStore();
  const checked = validateStrategy(good);
  assert.ok(checked.ok);
  await store.saveStrategy('2026-10-30', checked.strategy);
  for (const mode of ['planning', 'execute'] as const) {
    const net = fakeNet([textReply('ok')]);
    await runChat(req({ mode }), { cfg, store, userId: USER, supabaseUrl: SUPABASE_URL, dailyLimit: 80, globalLimit: 1000, fetchImpl: net.fetchImpl });
    const sys = net.museRequests[0].messages[0].content!;
    assert.match(sys, /Current strategy: \{"version":1/);
    assert.match(sys, /"max_tasks":3/);
    assert.match(sys, /the user wins/);
    assert.doesNotMatch(sys, /Finished 3 of 5/, 'the evidence stays out of the planning prompt');
  }
  const fresh = new MemoryStore();
  const net = fakeNet([textReply('ok')]);
  await runChat(req({ mode: 'planning' }), { cfg, store: fresh, userId: USER, supabaseUrl: SUPABASE_URL, dailyLimit: 80, globalLimit: 1000, fetchImpl: net.fetchImpl });
  assert.match(net.museRequests[0].messages[0].content!, /Current strategy: none yet/);
});

test('save_strategy is a review tool only', async () => {
  const store = new MemoryStore();
  const net = fakeNet([callsReply(['save_strategy', good])]);
  await assert.rejects(runChat(req({ mode: 'planning' }), { cfg, store, userId: USER, supabaseUrl: SUPABASE_URL, dailyLimit: 80, globalLimit: 1000, fetchImpl: net.fetchImpl }));
  assert.equal(store.strategies.length, 0);
});

const ev = (i: number, arm: ExperimentEvent['arm'], left: boolean, over: Partial<ExperimentEvent> = {}): ExperimentEvent => ({
  id: `e${i}`,
  day: '2026-10-29',
  time: '21:15',
  app: 'Instagram',
  arm,
  explore: false,
  reason: 'limit',
  left,
  seconds_after: left ? 30 : 600,
  window_seconds: 900,
  demo: false,
  ...over,
});

test('experiment results: per intervention, the sample sizes, a best one only with enough data, and the hours', () => {
  const events = [
    ...Array.from({ length: 9 }, (_, i) => ev(i, 'task', i < 7)),
    ...Array.from({ length: 8 }, (_, i) => ev(20 + i, 'cost', i < 3, { time: '22:05' })),
    ev(40, 'goal', true, { day: '2026-10-28' }),
    ev(41, 'goal', false, { day: '2026-10-28' }),
    ev(42, 'goal', false, { day: '2026-10-28' }),
  ];
  const s = summarizeExperiments(events);
  assert.equal(s.events, 20);
  assert.equal(s.days, 2);
  const alarm = s.arms.find((a) => a.arm === 'task')!;
  assert.deepEqual([alarm.tried, alarm.left], [9, 7]);
  assert.equal(s.arms.find((a) => a.arm === 'cost')!.left, 3);
  assert.equal(s.best, 'task');
  assert.deepEqual(s.arms.map((a) => a.prob_best), [0.87, 0.05, 0.08]);
  assert.deepEqual(s.hits_by_hour[0], { hour: '21:00', hits: 12 });
  assert.match(s.note, /not proof/);

  // Thompson sampling is honest about thin data: one lucky try is not a winner, and 1 of 1 still competes with 7 of 9
  assert.equal(summarizeExperiments([ev(1, 'task', true), ev(2, 'cost', false)]).best, null);
  const thin = summarizeExperiments([...Array.from({ length: 9 }, (_, i) => ev(i, 'task', i < 7)), ev(50, 'goal', true)]);
  assert.equal(thin.best, null);
  assert.ok(thin.arms.find((a) => a.arm === 'goal')!.prob_best > 0.3);
});

test('the experiment log from the phone is checked', () => {
  assert.equal(parseExperimentLog([ev(1, 'task', true)]).length, 1);
  for (const bad of [
    [{ ...ev(1, 'task', true), arm: 'shock' }],
    [{ ...ev(1, 'task', true), seconds_after: 2000, window_seconds: 900 }],
    [ev(1, 'task', true), ev(1, 'cost', true)],
    [{ ...ev(1, 'task', true), time: '25:00' }],
  ]) {
    assert.throws(() => parseExperimentLog(bad));
  }
});

async function post(body: unknown, store: MemoryStore) {
  const res = await handle(new Request('https://x/agent', { method: 'POST', headers: { Authorization: `Bearer ${jwt()}` }, body: JSON.stringify(body) }), {
    get: (n) => ({ SUPABASE_URL, MUSE_API_KEY: 'k' })[n],
    storeFor: () => store,
  });
  return { status: res.status, body: await res.json() };
}

test('actions: the phone logs experiments once (retries are ignored), the app reads totals and the strategy history', async () => {
  const store = new MemoryStore();
  let r = await post({ action: 'experiments', today: '2026-10-29', log: [ev(1, 'task', true), ev(2, 'cost', false)] }, store);
  assert.equal(r.status, 200);
  r = await post({ action: 'experiments', today: '2026-10-29', log: [ev(1, 'task', true)] }, store);
  assert.equal(r.body.results.events, 2);
  assert.equal((await post({ action: 'experiments', log: [{ id: 'x' }] }, store)).status, 422);

  await store.saveStrategy('2026-10-28', { limits: [], plan_style: { max_tasks: 5 }, risk_windows: [], rules: [], changes: [], evidence: [] });
  await store.saveStrategy('2026-10-30', { ...good });
  r = await post({ action: 'strategy' }, store);
  assert.equal(r.body.strategy.version, 2);
  assert.deepEqual(r.body.history.map((h: { version: number }) => h.version), [2, 1]);
});

test('get_experiment_results reads the last days and says when there is nothing', async () => {
  const store = new MemoryStore();
  let r = JSON.parse((await runServerTool('get_experiment_results', {}, env(store))).content);
  assert.equal(r.events, 0);
  await store.saveExperiments([ev(1, 'task', true), ev(2, 'task', true, { day: '2026-10-01' })]);
  r = JSON.parse((await runServerTool('get_experiment_results', { days: 3 }, env(store))).content);
  assert.equal(r.events, 1);
});

test('Thompson sampling maths: Beta draws have the right mean, and equal results give equal chances', () => {
  let x = 1;
  const rnd = () => {
    x = (x * 16807) % 2147483647;
    return x / 2147483647;
  };
  let sum = 0;
  for (let i = 0; i < 20000; i++) sum += sampleBeta(8, 3, rnd);
  assert.ok(Math.abs(sum / 20000 - 8 / 11) < 0.01);
  const even = probabilityBest([{ tried: 5, left: 2 }, { tried: 5, left: 2 }, { tried: 5, left: 2 }]);
  assert.ok(even.every((p) => Math.abs(p - 1 / 3) < 0.03), String(even));
  // a clear winner over a clear loser; a style never tried keeps a real chance (that is what makes it get tried)
  const [good, bad, untried] = probabilityBest([{ tried: 30, left: 25 }, { tried: 30, left: 5 }, { tried: 0, left: 0 }]);
  assert.ok(good > 0.75 && bad === 0 && untried > 0.1, `${good} ${bad} ${untried}`);
});
