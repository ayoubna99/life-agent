import assert from 'node:assert/strict';
import { test } from 'node:test';

import { handle, userFromAuthHeader } from '../supabase/functions/_shared/http.ts';
import { StoreError } from '../supabase/functions/_shared/store.ts';
import { fakeNet, jwt, MemoryStore, SUPABASE_URL, textReply, USER } from './helpers.ts';

const ENV: Record<string, string> = { MUSE_BASE_URL: 'https://muse.example/v1', MUSE_API_KEY: 'sk-secret-key', MUSE_MODEL: 'muse-test', SUPABASE_URL };

function call(body: unknown, opts: { replies?: unknown[]; store?: MemoryStore; auth?: string | null; method?: string; env?: Record<string, string> } = {}) {
  const store = opts.store ?? new MemoryStore();
  const net = fakeNet(opts.replies ?? []);
  const headers: Record<string, string> = { 'Content-Type': 'application/json', apikey: 'sb_publishable_x' };
  if (opts.auth !== null) headers.Authorization = opts.auth ?? `Bearer ${jwt()}`;
  const req = new Request('https://proj.supabase.co/functions/v1/agent', { method: opts.method ?? 'POST', headers, ...(opts.method === 'GET' ? {} : { body: typeof body === 'string' ? body : JSON.stringify(body) }) });
  return { store, net, res: handle(req, { get: (n) => (opts.env ?? ENV)[n], fetchImpl: net.fetchImpl, storeFor: () => store }) };
}
const chat = { action: 'chat', mode: 'planning', today: '2026-10-26', date: '2026-10-27', input: { type: 'user', text: 'hi' } };
const code = async (r: Promise<Response>) => (await (await r).json()).error?.code;

test('the token is read, not trusted blindly: wrong shape, wrong role, expired or no sub are all refused', () => {
  assert.deepEqual(userFromAuthHeader(`Bearer ${jwt()}`), { userId: USER, jwt: jwt() });
  assert.equal(userFromAuthHeader(null), null);
  assert.equal(userFromAuthHeader('Bearer sb_publishable_abc'), null);
  assert.equal(userFromAuthHeader('Basic abc.def.ghi'), null);
  assert.equal(userFromAuthHeader(`Bearer ${jwt({ role: 'anon' })}`), null);
  assert.equal(userFromAuthHeader(`Bearer ${jwt({ sub: 'not-a-uuid' })}`), null);
  assert.equal(userFromAuthHeader(`Bearer ${jwt({ exp: 1 })}`), null);
  assert.equal(userFromAuthHeader('Bearer a.b.c'), null);
});

test('no token: 401, and only POST is allowed', async () => {
  const noAuth = call(chat, { auth: null });
  assert.equal((await noAuth.res).status, 401);
  assert.equal((await call(chat, { method: 'GET' }).res).status, 405);
  assert.equal((await call('not json').res).status, 400);
});

test('a chat request returns the agent answer and the conversation id', async () => {
  const { res } = call(chat, { replies: [textReply('What do you need to do?')] });
  const r = await res;
  assert.equal(r.status, 200);
  const body = await r.json();
  assert.equal(body.type, 'text');
  assert.equal(body.text, 'What do you need to do?');
  assert.match(body.conversation_id, /^c0000000/);
});

test('every failure has its own status and a code, and never leaks the key or the user words', async () => {
  const secretWords = 'my private diary words';
  const bad = { ...chat, input: { type: 'user', text: secretWords }, mode: 'nope' };
  const r1 = await call(bad).res;
  assert.equal(r1.status, 422);
  assert.equal((await r1.text()).includes(secretWords), false);
  assert.equal(await code(call({ ...chat, today: 'x' }).res), 'bad_date');
  assert.equal(await code(call({ action: 'dance' }).res), 'unknown_action');

  const noKey = call(chat, { env: { SUPABASE_URL } });
  const nk = await noKey.res;
  assert.equal(nk.status, 500);
  assert.equal((await nk.json()).error.code, 'agent_not_configured');

  const store = new MemoryStore();
  const full = call(chat, { store, replies: [textReply('a')], env: { ...ENV, AGENT_DAILY_LIMIT: '1' } });
  await full.res;
  const over = await call(chat, { store, replies: [textReply('b')], env: { ...ENV, AGENT_DAILY_LIMIT: '1' } }).res;
  assert.equal(over.status, 429);
  assert.equal((await over.json()).error.code, 'daily_limit_reached');

  const shared = new MemoryStore();
  const env2 = { ...ENV, AGENT_GLOBAL_DAILY_LIMIT: '2' };
  await call(chat, { store: shared, replies: [textReply('a')], env: env2 }).res;
  await call(chat, { store: shared, replies: [textReply('b')], env: env2 }).res;
  const full2 = await call(chat, { store: shared, replies: [textReply('c')], env: env2 }).res;
  assert.equal(full2.status, 429);
  assert.equal((await full2.json()).error.code, 'demo_at_capacity');

  const missing = await call({ ...chat, conversation_id: 'c0000000-0000-0000-0000-000000000099' }).res;
  assert.equal(missing.status, 404);

  const broken = new MemoryStore();
  broken.failNext = 'messages';
  const s = await call(chat, { store: broken, replies: [textReply('x')] }).res;
  assert.equal(s.status, 502);
  assert.equal((await s.json()).error.code, 'store_error');
  assert.ok(new StoreError('x', 1) instanceof Error);

  const upstream = fakeNet([]);
  upstream.fetchImpl = (async () => new Response('', { status: 401 })) as unknown as typeof fetch;
  const store2 = new MemoryStore();
  const res = await handle(
    new Request('https://x/functions/v1/agent', { method: 'POST', headers: { Authorization: `Bearer ${jwt()}` }, body: JSON.stringify(chat) }),
    { get: (n) => ENV[n], fetchImpl: upstream.fetchImpl, storeFor: () => store2 },
  );
  assert.equal(res.status, 502);
  const text = await res.text();
  assert.equal(text.includes('sk-secret-key'), false);
  assert.match(text, /agent_upstream_status/);
});

test('usage summaries are validated and saved (and sent again, they replace)', async () => {
  const store = new MemoryStore();
  const rows = [{ day: '2026-10-26', app: 'Instagram', minutes: 74 }, { day: '2026-10-25', app: 'TikTok', minutes: 30 }];
  const r = await call({ action: 'usage', days: rows }, { store }).res;
  assert.deepEqual(await r.json(), { saved: 2 });
  await call({ action: 'usage', days: [{ day: '2026-10-26', app: 'instagram', minutes: 80 }] }, { store }).res;
  assert.deepEqual(store.usage.map((u) => [u.app, u.minutes]), [['instagram', 80], ['TikTok', 30]]);

  const refused = async (days: unknown) => assert.equal(await code(call({ action: 'usage', days }).res), 'bad_usage', JSON.stringify(days));
  await refused([]);
  await refused('x');
  await refused(Array.from({ length: 201 }, (_, i) => ({ day: '2026-10-26', app: `a${i}`, minutes: 1 })));
  await refused([{ day: '2026-13-01', app: 'X', minutes: 5 }]);
  await refused([{ day: '2026-10-26', app: '', minutes: 5 }]);
  await refused([{ day: '2026-10-26', app: 'X', minutes: -1 }]);
  await refused([{ day: '2026-10-26', app: 'X', minutes: 1441 }]);
  await refused([{ day: '2026-10-26', app: 'X', minutes: 1.5 }]);
  await refused([{ day: '2026-10-26', app: 'X', minutes: 5 }, { day: '2026-10-26', app: 'x', minutes: 6 }]);
});

test('the app can fetch a saved plan, or null', async () => {
  const store = new MemoryStore();
  store.plans.set('2026-10-27', { date: '2026-10-27', status: 'ready', data: { tasks: [{ title: 'Study', minutes: 30 }], limits: [] } });
  const found = await (await call({ action: 'plan', date: '2026-10-27' }, { store }).res).json();
  assert.equal(found.plan.data.tasks[0].title, 'Study');
  assert.deepEqual(await (await call({ action: 'plan', date: '2026-10-28' }, { store }).res).json(), { plan: null });
  assert.equal(await code(call({ action: 'plan', date: 'soon' }).res), 'bad_date');
});
