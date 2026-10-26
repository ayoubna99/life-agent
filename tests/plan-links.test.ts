import assert from 'node:assert/strict';
import { test } from 'node:test';

import { isSafePublicUrl, verifyLinks } from '../supabase/functions/_shared/links.ts';
import { isDate, validatePlan } from '../supabase/functions/_shared/plan.ts';
import { fakeNet } from './helpers.ts';

const task = (over: Record<string, unknown> = {}) => ({ title: 'Study algorithms', minutes: 40, ...over });

test('dates are real calendar dates', () => {
  assert.ok(isDate('2026-10-27'));
  for (const bad of ['2026-02-30', '2026-13-01', '27/10/2026', '', null, 5, '2026-1-1']) assert.equal(isDate(bad), false, String(bad));
});

test('a good plan is accepted and cleaned', () => {
  const r = validatePlan({
    wake: '07:00',
    sleep: '23:30',
    tasks: [task({ first_step: '  Open the book ', instructions: ['Read chapter 3', 'Do 2 exercises'], links: ['https://example.com/a'], start_time: '18:00' })],
    limits: [{ app: 'Instagram', minutes_per_day: 30 }],
    note: 'Light day',
  });
  assert.ok(r.ok);
  if (!r.ok) return;
  assert.equal(r.plan.tasks[0].first_step, 'Open the book');
  assert.deepEqual(r.plan.limits, [{ app: 'Instagram', minutes_per_day: 30 }]);
  assert.equal(r.plan.wake, '07:00');
});

test('every bad plan is refused with one sentence the model can act on', () => {
  const refused = (plan: unknown, fragment: RegExp) => {
    const r = validatePlan(plan);
    assert.equal(r.ok, false, JSON.stringify(plan));
    if (!r.ok) assert.match(r.error, fragment);
  };
  refused(null, /object/);
  refused({}, /non-empty/);
  refused({ tasks: [] }, /non-empty/);
  refused({ tasks: Array.from({ length: 13 }, () => task()) }, /12 tasks/);
  refused({ tasks: [task({ title: '  ' })] }, /title/);
  refused({ tasks: [task({ title: 'x'.repeat(121) })] }, /title/);
  refused({ tasks: [task({ minutes: 4 })] }, /minutes/);
  refused({ tasks: [task({ minutes: 481 })] }, /minutes/);
  refused({ tasks: [task({ minutes: 12.5 })] }, /minutes/);
  refused({ tasks: [task({ minutes: '40' })] }, /minutes/);
  refused({ tasks: [task({ start_time: '25:00' })] }, /start_time/);
  refused({ tasks: [task({ first_step: '' })] }, /first_step/);
  refused({ tasks: [task({ instructions: Array.from({ length: 9 }, () => 'x') })] }, /instructions/);
  refused({ tasks: [task({ instructions: [''] })] }, /instructions/);
  refused({ tasks: [task({ links: Array.from({ length: 6 }, () => 'https://a.co') })] }, /links/);
  refused({ tasks: [task()], limits: [{ app: 'X', minutes_per_day: 3 }] }, /limits\[0\]/);
  refused({ tasks: [task()], limits: [{ app: 'X', minutes_per_day: 30 }, { app: 'x', minutes_per_day: 40 }] }, /twice/);
  refused({ tasks: [task()], limits: 'none' }, /limits/);
  refused({ tasks: [task()], wake: '7am' }, /wake/);
  refused({ tasks: [task()], note: 'x'.repeat(301) }, /note/);
});

test('only plain public https links are ever fetched', () => {
  for (const ok of ['https://example.com/a?b=1', 'https://sub.example.org/x']) assert.ok(isSafePublicUrl(ok), ok);
  for (const bad of [
    'http://example.com', 'ftp://example.com', 'https://localhost/x', 'https://app.localhost', 'https://printer.local', 'https://db.internal/x',
    'https://127.0.0.1/x', 'https://10.0.0.5', 'https://169.254.169.254/latest/meta-data', 'https://[::1]/x', 'https://user:pw@example.com',
    'https://example.com:8443/x', 'https://intranet/x', 'not a url', '',
  ]) assert.equal(isSafePublicUrl(bad), null, bad);
});

test('dead links are dropped, guarded ones are kept, unsafe ones are never fetched', async () => {
  const net = fakeNet([], {
    'https://ok.example/a': 200,
    'https://gone.example/a': 404,
    'https://server-error.example/a': 500,
    'https://guarded.example/a': 403,
    'https://down.example/a': 'network',
  });
  const r = await verifyLinks(
    ['https://ok.example/a', 'https://gone.example/a', 'https://server-error.example/a', 'https://guarded.example/a', 'https://down.example/a', 'http://insecure.example/a', 'https://127.0.0.1/x'],
    { fetchImpl: net.fetchImpl },
  );
  assert.deepEqual(r.ok, ['https://ok.example/a', 'https://guarded.example/a']);
  assert.equal(r.dropped.length, 5);
  assert.equal(net.otherUrls.some((u) => u.includes('127.0.0.1') || u.includes('insecure')), false, 'unsafe URLs must not be fetched');
});

test('a site that refuses HEAD is tried with GET', async () => {
  const seen: string[] = [];
  const fetchImpl = (async (_u: string, init: RequestInit) => {
    seen.push(init.method!);
    return new Response('', { status: init.method === 'HEAD' ? 405 : 206 });
  }) as unknown as typeof fetch;
  const r = await verifyLinks(['https://picky.example/a'], { fetchImpl });
  assert.deepEqual(seen, ['HEAD', 'GET']);
  assert.deepEqual(r.ok, ['https://picky.example/a']);
});

test('a slow link times out and is dropped', async () => {
  const hang = ((_u: string, init: RequestInit) =>
    new Promise((_r, rej) => init.signal!.addEventListener('abort', () => rej(new Error('aborted'))))) as unknown as typeof fetch;
  const r = await verifyLinks(['https://slow.example/a'], { fetchImpl: hang, timeoutMs: 20 });
  assert.deepEqual(r.dropped, ['https://slow.example/a']);
});

test('our own storage links are trusted without a request', async () => {
  const net = fakeNet([]);
  const own = 'https://proj.supabase.co/storage/v1/object/sign/materials/u/a.md?token=t';
  const r = await verifyLinks([own], { fetchImpl: net.fetchImpl, trustedPrefix: 'https://proj.supabase.co/storage/v1/object/sign/materials/' });
  assert.deepEqual(r.ok, [own]);
  assert.equal(net.otherUrls.length, 0);
});
