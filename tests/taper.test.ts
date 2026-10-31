import assert from 'node:assert/strict';
import { test } from 'node:test';

import { handle } from '../supabase/functions/_shared/http.ts';
import { advanceTaper, minutesText, nextTarget } from '../supabase/functions/_shared/taper.ts';
import { jwt, MemoryStore, SUPABASE_URL } from './helpers.ts';

const days = (from: string, minutes: number[]) =>
  minutes.map((m, i) => {
    const d = new Date(`${from}T00:00:00Z`);
    d.setUTCDate(d.getUTCDate() + i);
    return { day: d.toISOString().slice(0, 10), app: 'TikTok', minutes: m };
  });

test('it starts from the typical day (the median, not the worst) and asks for about 15% less', () => {
  // the week before 2026-11-01: 180 on a typical day, one 400 binge
  const usage = days('2026-10-25', [170, 180, 400, 185, 175, 180, 190]);
  const r = advanceTaper(null, 'TikTok', usage, '2026-11-01')!;
  assert.equal(r.taper.baseline, 180);
  assert.equal(r.taper.target, 155);
  assert.equal(r.stepped, true);
  assert.equal(advanceTaper(null, 'TikTok', usage.slice(0, 2), '2026-11-01'), null, 'fewer than 3 days of data: not started');
  assert.equal(advanceTaper(null, 'TikTok', days('2026-10-25', [10, 20, 15]), '2026-11-01'), null, 'already within the goal');
});

test('it steps down only after the target was met on 2 of the last 3 days, never goes up, stops at the goal', () => {
  const week = days('2026-10-25', [180, 180, 180, 180, 180, 180, 180]);
  let t = advanceTaper(null, 'TikTok', week, '2026-11-01')!.taper; // target 155
  // 1 Nov: 170 (missed), 2 Nov: 150 (met): not yet
  let r = advanceTaper(t, 'TikTok', [...week, ...days('2026-11-01', [170, 150])], '2026-11-03')!;
  assert.equal(r.taper.target, 155);
  assert.equal(r.stepped, false);
  // 3 Nov: 140 (met): 2 of the last 3, step down
  r = advanceTaper(r.taper, 'TikTok', [...week, ...days('2026-11-01', [170, 150, 140])], '2026-11-04')!;
  assert.equal(r.taper.target, 130);
  assert.equal(r.stepped, true);
  assert.deepEqual(r.taper.path.map((p) => p.target), [155, 130]);
  assert.equal(r.taper.trade, null, 'a new target needs a new trade');
  // a terrible day never raises it
  t = advanceTaper(r.taper, 'TikTok', [...week, ...days('2026-11-01', [170, 150, 140, 400])], '2026-11-05')!.taper;
  assert.equal(t.target, 130);
  assert.equal(nextTarget(35, 30), 30, 'never below the goal');
  assert.equal(nextTarget(30, 30), 30);
  assert.equal(minutesText(130), '2 h 10');
});

test('the taper action: code sets the target, Muse Spark Open writes the trade, and live nudges use both', async () => {
  const store = new MemoryStore();
  store.profile = { apps: ['TikTok'], focus: 'finish my thesis', sleep: '23:00' };
  store.usage = days('2026-10-25', [180, 180, 180, 180, 180, 180, 180]);
  const env: Record<string, string> = { MUSE_BASE_URL: 'https://api.meta.ai/v1', MUSE_API_KEY: 'k', MUSE_MODEL: 'm', SUPABASE_URL, OPEN_API_KEY: 'bt' };
  const sent: string[] = [];
  const fetchImpl = (async (_u: string, init: RequestInit) => {
    sent.push((JSON.parse(init.body as string).messages as { content: string }[]).map((m) => m.content).join('\n'));
    return new Response(JSON.stringify({ choices: [{ message: { role: 'assistant', content: '25 minutes back: two pages of your thesis at 22:15.' } }] }));
  }) as unknown as typeof fetch;
  const call = (body: unknown) => handle(new Request('https://x/functions/v1/agent', { method: 'POST', headers: { Authorization: `Bearer ${jwt()}`, apikey: 'k' }, body: JSON.stringify(body) }), { get: (n) => env[n], fetchImpl, storeFor: () => store });
  const out = await (await call({ action: 'taper', today: '2026-11-01' })).json();
  assert.equal(out.tapers[0].target, 155);
  assert.equal(out.tapers[0].trade, '25 minutes back: two pages of your thesis at 22:15.');
  assert.match(sent[0], /minutes_won_back_per_day: 25/);
  assert.match(sent[0], /finish my thesis/);
  // the same day again: no new model call
  await call({ action: 'taper', today: '2026-11-01' });
  assert.equal(sent.length, 1);
  // a live nudge on TikTok knows today's target and the trade
  await call({ action: 'nudge', today: '2026-11-01', now: '22:40', app: 'TikTok', used_minutes: 160, limit_minutes: 155, reason: 'limit' });
  assert.match(sent[1], /todays_target_minutes: 155 \(they started at 180/);
  assert.match(sent[1], /their_trade_for_the_minutes_won_back: "25 minutes back/);
});
