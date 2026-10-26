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

test('materials are uploaded into the user folder and a week-long link comes back', async () => {
  const { s, seen } = store((x) => (x.url.includes('/object/sign/') ? json({ signedURL: '/object/sign/materials/p?token=abc' }) : json({ Key: 'ok' })));
  const url = await s.saveMaterial('2026-10-27-sheet.md', '# Sheet');
  assert.equal(seen[0].url, `${SUPABASE_URL}/storage/v1/object/materials/${USER}/2026-10-27-sheet.md`);
  assert.equal(seen[0].headers['x-upsert'], 'true');
  assert.equal(seen[0].body, '# Sheet');
  assert.deepEqual(seen[1].body, { expiresIn: 604800 });
  assert.equal(url, `${SUPABASE_URL}/storage/v1/object/sign/materials/p?token=abc`);
});

test('a failing call is a StoreError with the status only', async () => {
  const { s } = store(() => new Response('{"message":"secret schema detail"}', { status: 403 }));
  await assert.rejects(s.getPlan('2026-10-27'), (e: unknown) => e instanceof StoreError && e.status === 403 && !e.message.includes('secret'));
  const down = new RestStore({ supabaseUrl: SUPABASE_URL, apikey: 'k', jwt: 'a.b.c', userId: USER, fetchImpl: (async () => { throw new Error('boom'); }) as unknown as typeof fetch });
  await assert.rejects(down.getPlan('2026-10-27'), (e: unknown) => e instanceof StoreError && e.status === 0);
});
