import assert from 'node:assert/strict';
import { test } from 'node:test';

import { handle } from '../supabase/functions/_shared/http.ts';
import { parseEveningRequest, runEvening } from '../supabase/functions/_shared/evening.ts';
import { lateBy, nightFacts, parseNights } from '../supabase/functions/_shared/nights.ts';
import { runChat } from '../supabase/functions/_shared/loop.ts';
import { cfg, fakeNet, jwt, MemoryStore, SUPABASE_URL, textReply, USER } from './helpers.ts';

test('a phone-down after midnight counts as later than an evening sleep time', () => {
  assert.equal(lateBy('03:10', '23:00'), 250);
  assert.equal(lateBy('22:40', '23:00'), -20);
  assert.equal(lateBy('00:30', '00:00'), 30);
  assert.deepEqual(nightFacts([{ night: '2026-10-27', down: '01:00' }, { night: '2026-10-28', down: '03:10' }], '23:00'), [
    'last_night_phone_down: 03:10 (night of 2026-10-28)',
    'last_night_minutes_after_known_sleep: 250',
    'recent_phone_down_times: ["03:10","01:00"]',
  ]);
  assert.throws(() => parseNights([{ night: '2026-10-28', down: '3am' }]));
});

const body = { today: '2026-10-29', tomorrow: '2026-10-30', now: '22:00', done: ['Gym'], missed: ['German'] };

test('evening reminder: written by Muse Spark from their name, their day and last night; skipped when tomorrow is planned', async () => {
  const store = new MemoryStore();
  store.profile = { apps: [], name: 'Jake', sleep: '23:00' };
  store.nights = [{ night: '2026-10-28', down: '03:12' }];
  const net = fakeNet([textReply('Hey Jake, let\'s make our plans for tomorrow. German is still open.')]);
  const out = await runEvening(parseEveningRequest(body), { cfg, store, dailyLimit: 80, globalLimit: 1000, fetchImpl: net.fetchImpl });
  assert.deepEqual(out, { planned: false, text: 'Hey Jake, let\'s make our plans for tomorrow. German is still open.', model: 'spark' });
  const sys = net.museRequests[0].messages[0].content!;
  assert.match(sys, /known_first_name: "Jake"/);
  assert.match(sys, /last_night_phone_down: 03:12/);
  assert.match(sys, /last_night_minutes_after_known_sleep: 252/);
  assert.match(sys, /tasks_missed: \["German"\]/);
  assert.match(sys, /Never sleep, health or emotional advice/);

  store.plans.set('2026-10-30', { date: '2026-10-30', status: 'ready', data: { tasks: [], limits: [] } as never });
  const quota = store.quota;
  const net2 = fakeNet([]);
  assert.deepEqual(await runEvening(parseEveningRequest(body), { cfg, store, dailyLimit: 80, globalLimit: 1000, fetchImpl: net2.fetchImpl }), { planned: true });
  assert.equal(store.quota, quota, 'no model call, no quota');
  const net3 = fakeNet([textReply('Hey Jake, let\'s plan tomorrow.')]);
  const forced = await runEvening(parseEveningRequest({ ...body, test: true }), { cfg, store, dailyLimit: 80, globalLimit: 1000, fetchImpl: net3.fetchImpl });
  assert.equal(forced.planned, false, 'the test button writes it anyway');
});

async function post(b: unknown, store: MemoryStore, replies: unknown[] = []) {
  const net = fakeNet(replies);
  const res = await handle(new Request('https://x/agent', { method: 'POST', headers: { Authorization: `Bearer ${jwt()}` }, body: JSON.stringify(b) }), {
    get: (n) => ({ SUPABASE_URL, MUSE_API_KEY: 'k', MUSE_BASE_URL: cfg.baseUrl, MUSE_MODEL: cfg.model })[n],
    storeFor: () => store,
    fetchImpl: net.fetchImpl,
  });
  return { status: res.status, body: await res.json() };
}

test('the phone uploads phone-down times with usage; the planning chat sees last night', async () => {
  const store = new MemoryStore();
  let r = await post({ action: 'usage', nights: [{ night: '2026-10-28', down: '03:12', up: '10:40' }] }, store);
  assert.deepEqual(r.body, { saved: 0, nights: 1 });
  r = await post({ action: 'usage', days: [{ day: '2026-10-28', app: 'TikTok', minutes: 90 }], nights: [{ night: '2026-10-28', down: '02:50' }] }, store);
  assert.deepEqual(store.nights, [{ night: '2026-10-28', down: '02:50' }], 'replaced');
  assert.equal((await post({ action: 'usage', nights: [{ night: 'x', down: '02:50' }] }, store)).status, 422);

  store.profile = { apps: [], sleep: '23:00' };
  const net = fakeNet([textReply('ok')]);
  await runChat(
    { mode: 'planning', today: '2026-10-29', date: '2026-10-30', input: { type: 'user', text: 'Plan tomorrow' } },
    { cfg, store, userId: USER, supabaseUrl: SUPABASE_URL, dailyLimit: 80, globalLimit: 1000, fetchImpl: net.fetchImpl },
  );
  const sys = net.museRequests[0].messages[0].content!;
  assert.match(sys, /last_night_phone_down: 02:50/);
  assert.match(sys, /Do not ask what time they will sleep/);
});

test('evening action over HTTP', async () => {
  const store = new MemoryStore();
  const r = await post({ action: 'evening', ...body }, store, [textReply('Hey, let\'s plan tomorrow.')]);
  assert.equal(r.status, 200);
  assert.equal(r.body.planned, false);
  assert.equal((await post({ action: 'evening', ...body, now: '25:00' }, store)).status, 422);
});

test('what the user says about their day is saved for every later chat (save_settings)', async () => {
  const { runServerTool } = await import('../supabase/functions/_shared/tools.ts');
  const store = new MemoryStore();
  store.profile = { apps: ['TikTok'], wake: '07:00' };
  const env = { store, mode: 'planning' as const, today: '2026-10-29', planDate: '2026-10-30', supabaseUrl: SUPABASE_URL, fetchImpl: fetch, randomId: () => 'r' };
  const r = JSON.parse((await runServerTool('save_settings', { sleep: '23:00', focus: 'my thesis' }, env)).content);
  assert.deepEqual(r.saved, ['sleep', 'focus']);
  assert.deepEqual(store.profile, { apps: ['TikTok'], wake: '07:00', sleep: '23:00', focus: 'my thesis' });
  assert.match(JSON.parse((await runServerTool('save_settings', { sleep: '11pm' }, env)).content).error, /HH:MM/);
});
