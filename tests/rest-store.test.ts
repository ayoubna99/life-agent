import assert from 'node:assert/strict';
import { test } from 'node:test';

import { RestStore, StoreError } from '../supabase/functions/_shared/store.ts';
import { SUPABASE_URL, USER } from './helpers.ts';

interface Seen {
  method: string;
  url: string;
  headers: Record<string, string>;
  body: unknown;
}

function store(answer: (seen: Seen) => Response | undefined = () => undefined) {
  const seen: Seen[] = [];
  const fetchImpl = (async (url: string, init: RequestInit) => {
    const s: Seen = { method: init.method ?? 'GET', url, headers: init.headers as Record<string, string>, body: typeof init.body === 'string' && init.body.startsWith('{') || String(init.body).startsWith('[') ? JSON.parse(init.body as string) : init.body };
    seen.push(s);
    return answer(s) ?? new Response('[]', { status: 200, headers: { 'content-type': 'application/json' } });
  }) as unknown as typeof fetch;
  return { s: new RestStore({ supabaseUrl: `${SUPABASE_URL}/`, apikey: 'sb_publishable_x', jwt: 'tok.en.sig', userId: USER, fetchImpl }), seen };
}
const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json' } });

test('every call carries the caller\'s own token, never a service key', async () => {
  const { s, seen } = store();
  await s.getPlan('2026-10-27');
  assert.equal(seen[0].headers.Authorization, 'Bearer tok.en.sig');
  assert.equal(seen[0].headers.apikey, 'sb_publishable_x');
  assert.equal(seen[0].url, `${SUPABASE_URL}/rest/v1/plans?for_date=eq.2026-10-27&select=for_date,status,data&limit=1`);
});

test('conversations and messages', async () => {
  const { s, seen } = store((x) => (x.method === 'POST' && x.url.includes('conversations') ? json([{ id: 'cid' }]) : undefined));
  assert.equal(await s.createConversation('execute'), 'cid');
  assert.deepEqual(seen[0].body, { user_id: USER, kind: 'execute' });
  assert.equal(seen[0].headers.Prefer, 'return=representation');

  await s.appendMessages('cid', [{ role: 'user', content: 'a' }, { role: 'assistant', content: 'b' }]);
  assert.deepEqual(seen[1].body, [
    { conversation_id: 'cid', user_id: USER, role: 'user', content: { role: 'user', content: 'a' } },
    { conversation_id: 'cid', user_id: USER, role: 'assistant', content: { role: 'assistant', content: 'b' } },
  ]);
  await s.appendMessages('cid', []);
  assert.equal(seen.length, 2, 'nothing sent for an empty list');
});

test('messages come back in order as stored', async () => {
  const { s, seen } = store(() => json([{ content: { role: 'user', content: 'a' } }, { content: { role: 'assistant', content: 'b' } }]));
  assert.deepEqual((await s.loadMessages('cid')).map((m) => m.content), ['a', 'b']);
  assert.match(seen[0].url, /order=id\.asc/);
});

test('saving a plan replaces the one for that day', async () => {
  const { s, seen } = store();
  await s.savePlan('2026-10-27', { tasks: [{ title: 'Study', minutes: 30 }], limits: [] });
  assert.match(seen[0].url, /plans\?on_conflict=user_id,for_date$/);
  assert.equal(seen[0].headers.Prefer, 'resolution=merge-duplicates,return=minimal');
  const row = (seen[0].body as { user_id: string; for_date: string; status: string }[])[0];
  assert.deepEqual([row.user_id, row.for_date, row.status], [USER, '2026-10-27', 'ready']);
});

test('usage lookups cannot be widened with wildcards, and uploads replace per day and app', async () => {
  const { s, seen } = store();
  await s.getUsage('Insta%gram*,or(1=1)', '2026-10-20');
  assert.match(seen[0].url, /app=ilike\.Instagramor1%3D1&day=gte\.2026-10-20/);
  await s.upsertUsage([{ day: '2026-10-26', app: 'Instagram', minutes: 74 }]);
  assert.match(seen[1].url, /usage_days\?on_conflict=user_id,day,app$/);
  assert.deepEqual(seen[1].body, [{ user_id: USER, day: '2026-10-26', app: 'Instagram', minutes: 74 }]);
});

test('the quota counter is read from the database function', async () => {
  const { s, seen } = store(() => json(7));
  assert.equal(await s.bumpQuota(), 7);
  assert.match(seen[0].url, /rpc\/bump_quota$/);
  const { s: broken } = store(() => json('nope'));
  await assert.rejects(broken.bumpQuota(), StoreError);
});

test('materials are uploaded into the user folder and a 3-day link comes back', async () => {
  const { s, seen } = store((x) => (x.url.includes('/object/sign/') ? json({ signedURL: '/object/sign/materials/p?token=abc' }) : json({ Key: 'ok' })));
  const url = await s.saveMaterial('2026-10-27-sheet.md', '# Sheet');
  assert.equal(seen[0].url, `${SUPABASE_URL}/storage/v1/object/materials/${USER}/2026-10-27-sheet.md`);
  assert.equal(seen[0].headers['x-upsert'], 'true');
  assert.equal(seen[0].body, '# Sheet');
  assert.deepEqual(seen[1].body, { expiresIn: 259200 });
  assert.equal(url, `${SUPABASE_URL}/storage/v1/object/sign/materials/p?token=abc`);
});

test('a failing call is a StoreError with the status only', async () => {
  const { s } = store(() => new Response('{"message":"secret schema detail"}', { status: 403 }));
  await assert.rejects(s.getPlan('2026-10-27'), (e: unknown) => e instanceof StoreError && e.status === 403 && !e.message.includes('secret'));
  const down = new RestStore({ supabaseUrl: SUPABASE_URL, apikey: 'k', jwt: 'a.b.c', userId: USER, fetchImpl: (async () => { throw new Error('boom'); }) as unknown as typeof fetch });
  await assert.rejects(down.getPlan('2026-10-27'), (e: unknown) => e instanceof StoreError && e.status === 0);
});

test('settings are read as times and saved only for the fields sent', async () => {
  const { s, seen } = store(() => json([{ wake_minute: 420, sleep_minute: 1410, distracting_apps: ['Instagram'], focus: 'my thesis', first_name: 'Mo' }]));
  assert.deepEqual(await s.getProfile(), { wake: '07:00', sleep: '23:30', apps: ['Instagram'], focus: 'my thesis', name: 'Mo' });
  await s.saveProfile({ sleep: '22:45' });
  assert.match(seen[1].url, /profiles\?on_conflict=user_id$/);
  assert.equal(seen[1].headers.Prefer, 'resolution=merge-duplicates,return=minimal');
  assert.deepEqual(seen[1].body, { user_id: USER, sleep_minute: 1365 });
  await s.saveProfile({ apps: ['TikTok'], focus: '' });
  assert.deepEqual(seen[2].body, { user_id: USER, distracting_apps: ['TikTok'], focus: '' });
  await s.saveProfile({ name: 'Mo' });
  assert.deepEqual(seen[3].body, { user_id: USER, first_name: 'Mo' });
  const { s: empty } = store(() => json([]));
  assert.deepEqual(await empty.getProfile(), { apps: [] });
});

test('uploads are downloaded with the caller token, and a missing or oversize file is just null', async () => {
  const { s, seen } = store(() => new Response(new Uint8Array([1, 2, 3]), { status: 200 }));
  assert.deepEqual([...(await s.downloadUpload(`${USER}/my file.pdf`, 10))!], [1, 2, 3]);
  assert.equal(seen[0].url, `${SUPABASE_URL}/storage/v1/object/uploads/${USER}/my%20file.pdf`);
  assert.equal(seen[0].headers.Authorization, 'Bearer tok.en.sig');
  assert.equal(await s.downloadUpload(`${USER}/a.pdf`, 2), null, 'bigger than the limit');
  const { s: gone } = store(() => new Response('{}', { status: 400 }));
  assert.equal(await gone.downloadUpload(`${USER}/a.pdf`, 10), null);
  const { s: broken } = store(() => new Response('', { status: 500 }));
  await assert.rejects(broken.downloadUpload(`${USER}/a.pdf`, 10), (e: unknown) => e instanceof StoreError && e.status === 500);
});

test('documents are stored once and read back by id', async () => {
  const { s, seen } = store((x) => (x.method === 'POST' ? json([{ id: 'doc-1' }]) : json([{ id: 'doc-1', name: 'n.pdf', pages: 2, text: 'hello', kind: 'pdf' }])));
  assert.equal(await s.saveDocument({ name: 'n.pdf', text: 'hello', pages: 2, kind: 'pdf', filePath: `${USER}/n.pdf` }), 'doc-1');
  assert.deepEqual(seen[0].body, { user_id: USER, name: 'n.pdf', text: 'hello', pages: 2, kind: 'pdf', file_path: `${USER}/n.pdf` });
  assert.deepEqual(await s.getDocument('doc-1'), { id: 'doc-1', name: 'n.pdf', pages: 2, text: 'hello', kind: 'pdf' });
  assert.match(seen[1].url, /documents\?id=eq\.doc-1&select=id,name,pages,text,kind&limit=1$/);
});

test('deleting an upload uses the caller token and never throws', async () => {
  const { s, seen } = store(() => new Response('', { status: 200 }));
  await s.deleteUpload(`${USER}/my file.wav`);
  assert.equal(seen[0].method, 'DELETE');
  assert.equal(seen[0].url, `${SUPABASE_URL}/storage/v1/object/uploads/${USER}/my%20file.wav`);
  assert.equal(seen[0].headers.Authorization, 'Bearer tok.en.sig');
  const down = new RestStore({ supabaseUrl: SUPABASE_URL, apikey: 'k', jwt: 'a.b.c', userId: USER, fetchImpl: (async () => { throw new Error('boom'); }) as unknown as typeof fetch });
  await down.deleteUpload(`${USER}/a.wav`);
});

test('the shared counter is read from its own database function', async () => {
  const { s, seen } = store(() => json(412));
  assert.equal(await s.bumpGlobalQuota(), 412);
  assert.match(seen[0].url, /rpc\/bump_global_quota$/);
  const { s: broken } = store(() => json(null));
  await assert.rejects(broken.bumpGlobalQuota(), StoreError);
});

test('strategy versions: read newest first, a save adds the next version number', async () => {
  const row = { version: 2, for_date: '2026-10-30', strategy: { limits: [], plan_style: { max_tasks: 3 }, risk_windows: [], rules: [], changes: ['x 1'], evidence: ['y 2'] }, created_at: 't' };
  const { s, seen } = store((x) => (x.method === 'GET' ? json([row]) : undefined));
  const got = await s.getStrategy();
  assert.equal(got?.version, 2);
  assert.deepEqual(got?.plan_style, { max_tasks: 3 });
  assert.match(seen[0].url, /strategies\?select=version,for_date,strategy,created_at&order=version\.desc&limit=1$/);
  assert.equal(await s.saveStrategy('2026-10-31', row.strategy), 3);
  const post = seen.find((x) => x.method === 'POST')!;
  assert.deepEqual(post.body, { user_id: USER, version: 3, for_date: '2026-10-31', strategy: row.strategy });
});

test('experiments are stored once per event id and read back in the phone\'s shape', async () => {
  const { s, seen } = store((x) =>
    x.method === 'GET'
      ? json([{ event_id: 'e1', day: '2026-10-29', local_time: '21:10', app: 'Instagram', arm: 'task', explore: true, reason: 'limit', left_app: true, seconds_after: 40, window_seconds: 900, demo: false }])
      : undefined,
  );
  await s.saveExperiments([{ id: 'e1', day: '2026-10-29', time: '21:10', app: 'Instagram', arm: 'task', explore: true, reason: 'limit', left: true, seconds_after: 40, window_seconds: 900, demo: false }]);
  assert.match(seen[0].url, /experiments\?on_conflict=user_id,event_id$/);
  assert.equal(seen[0].headers.Prefer, 'resolution=ignore-duplicates,return=minimal');
  assert.equal((seen[0].body as { left_app: boolean }[])[0].left_app, true);
  const back = await s.getExperiments('2026-10-23');
  assert.deepEqual(back[0], { id: 'e1', day: '2026-10-29', time: '21:10', app: 'Instagram', arm: 'task', explore: true, reason: 'limit', left: true, seconds_after: 40, window_seconds: 900, demo: false });
  assert.match(seen[1].url, /experiments\?day=gte\.2026-10-23&/);
});

test('phone-down nights: upserted per night, read newest first', async () => {
  const { s, seen } = store((x) => (x.method === 'GET' ? json([{ night: '2026-10-28', down_at: '03:12', up_at: null }]) : undefined));
  await s.upsertNights([{ night: '2026-10-28', down: '03:12', up: '10:40' }]);
  assert.match(seen[0].url, /phone_nights\?on_conflict=user_id,night$/);
  assert.deepEqual(seen[0].body, [{ user_id: USER, night: '2026-10-28', down_at: '03:12', up_at: '10:40' }]);
  assert.deepEqual(await s.getNights('2026-10-29'), [{ night: '2026-10-28', down: '03:12' }]);
  assert.match(seen[1].url, /phone_nights\?night=lte\.2026-10-29&select=night,down_at,up_at&order=night\.desc&limit=7$/);
});
