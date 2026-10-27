import assert from 'node:assert/strict';
import { test } from 'node:test';

import { handleCleanup } from '../supabase/functions/_shared/cleanup.ts';

const SECRET = 'a-long-random-cleanup-secret';
const ENV: Record<string, string> = { CLEANUP_SECRET: SECRET, SUPABASE_URL: 'https://proj.supabase.co', SUPABASE_SERVICE_ROLE_KEY: 'service-key-xyz' };

interface Seen {
  method: string;
  url: string;
  headers: Record<string, string>;
  body: any;
}

/** A fake project: `rpc/expired_files` answers from `batches` in order, deletes are recorded. */
function project(batches: { bucket_id: string; name: string }[][], opts: { listStatus?: number; deleteStatus?: number } = {}) {
  const seen: Seen[] = [];
  let i = 0;
  const fetchImpl = (async (url: string, init: RequestInit) => {
    seen.push({ method: init.method ?? 'GET', url, headers: init.headers as Record<string, string>, body: init.body ? JSON.parse(String(init.body)) : undefined });
    if (url.endsWith('/rest/v1/rpc/expired_files')) {
      if (opts.listStatus) return new Response('{}', { status: opts.listStatus });
      return new Response(JSON.stringify(batches[i++] ?? []), { status: 200, headers: { 'content-type': 'application/json' } });
    }
    return new Response('[]', { status: opts.deleteStatus ?? 200 });
  }) as unknown as typeof fetch;
  return { seen, fetchImpl };
}

const call = (env: Record<string, string>, over: { method?: string; secret?: string | null; body?: unknown } = {}, fetchImpl?: typeof fetch) => {
  const headers: Record<string, string> = {};
  if (over.secret !== null) headers['x-cleanup-secret'] = over.secret ?? SECRET;
  const req = new Request('https://proj.supabase.co/functions/v1/cleanup', { method: over.method ?? 'POST', headers, ...(over.method === 'GET' ? {} : { body: JSON.stringify(over.body ?? {}) }) });
  return handleCleanup(req, { get: (n) => env[n], fetchImpl });
};
const code = async (r: Response) => ((await r.json()) as { error?: { code: string } }).error?.code;

test('without its own secret the function does nothing, whatever is sent', async () => {
  const p = project([[{ bucket_id: 'materials', name: 'u/a.pdf' }]]);
  assert.equal(await code(await call({ ...ENV, CLEANUP_SECRET: '' }, {}, p.fetchImpl)), 'not_configured');
  assert.equal(await code(await call({ ...ENV, CLEANUP_SECRET: 'short' }, { secret: 'short' }, p.fetchImpl)), 'not_configured', 'a weak secret is refused');
  assert.equal(await code(await call({ ...ENV, SUPABASE_SERVICE_ROLE_KEY: '' }, {}, p.fetchImpl)), 'not_configured');
  assert.equal((await call(ENV, { secret: null }, p.fetchImpl)).status, 401);
  assert.equal((await call(ENV, { secret: 'a-long-random-cleanup-secreT' }, p.fetchImpl)).status, 401);
  assert.equal((await call(ENV, { secret: SECRET + 'x' }, p.fetchImpl)).status, 401);
  assert.equal((await call(ENV, { method: 'GET' }, p.fetchImpl)).status, 405);
  assert.equal(p.seen.length, 0, 'nothing was listed or deleted');
});

test('files older than 3 days are listed with the service key and deleted per bucket through the Storage API', async () => {
  const p = project([[
    { bucket_id: 'materials', name: 'u1/2026-10-27-sheet-abcdef12.pdf' },
    { bucket_id: 'materials', name: 'u1/images/card.webp' },
    { bucket_id: 'uploads', name: 'u2/old.jpg' },
  ]]);
  const r = await call(ENV, {}, p.fetchImpl);
  assert.equal(r.status, 200);
  assert.deepEqual(await r.json(), { days: 3, dry_run: false, deleted: { materials: 2, uploads: 1 }, total: 3 });
  const [list, delMaterials, delUploads] = p.seen;
  assert.equal(list.url, 'https://proj.supabase.co/rest/v1/rpc/expired_files');
  assert.deepEqual(list.body, { p_days: 3, p_limit: 500 });
  assert.equal(list.headers.Authorization, 'Bearer service-key-xyz');
  assert.equal(delMaterials.method, 'DELETE');
  assert.equal(delMaterials.url, 'https://proj.supabase.co/storage/v1/object/materials');
  assert.deepEqual(delMaterials.body, { prefixes: ['u1/2026-10-27-sheet-abcdef12.pdf', 'u1/images/card.webp'] });
  assert.equal(delUploads.url, 'https://proj.supabase.co/storage/v1/object/uploads');
  assert.deepEqual(delUploads.body, { prefixes: ['u2/old.jpg'] });
});

test('a dry run reports what would go and deletes nothing', async () => {
  const p = project([[{ bucket_id: 'materials', name: 'u/a.pdf' }]]);
  const r = await call(ENV, { body: { dry_run: true } }, p.fetchImpl);
  assert.deepEqual(await r.json(), { days: 3, dry_run: true, deleted: { materials: 1, uploads: 0 }, total: 1 });
  assert.equal(p.seen.filter((s) => s.method === 'DELETE').length, 0);
});

test('nothing old: one list call, no deletes; CLEANUP_DAYS changes the age, a bad value falls back to 3', async () => {
  const p = project([[]]);
  assert.equal((await (await call({ ...ENV, CLEANUP_DAYS: '7' }, {}, p.fetchImpl)).json()).total, 0);
  assert.equal(p.seen.length, 1);
  assert.equal(p.seen[0].body.p_days, 7);
  const q = project([[]]);
  await call({ ...ENV, CLEANUP_DAYS: 'soon' }, {}, q.fetchImpl);
  assert.equal(q.seen[0].body.p_days, 3);
});

test('a full batch is followed by another one until the list runs out', async () => {
  const full = Array.from({ length: 500 }, (_, i) => ({ bucket_id: 'materials', name: `u/${i}.pdf` }));
  const p = project([full, full, [{ bucket_id: 'uploads', name: 'u/last.jpg' }]]);
  const r = await (await call(ENV, {}, p.fetchImpl)).json();
  assert.equal(r.total, 1001);
  assert.equal(p.seen.filter((s) => s.url.endsWith('expired_files')).length, 3);
});

test('rows that are not ours are ignored, and failures are reported without the key or the file names', async () => {
  const odd = project([[{ bucket_id: 'avatars', name: 'u/x.png' }, { bucket_id: 'materials', name: 'ok.pdf' }, { bucket_id: 'materials', name: 5 as never }]]);
  assert.equal((await (await call(ENV, {}, odd.fetchImpl)).json()).total, 1, 'only the two known buckets, only real names');
  assert.deepEqual(odd.seen.find((s) => s.method === 'DELETE')!.body, { prefixes: ['ok.pdf'] });

  const listFails = await call(ENV, {}, project([], { listStatus: 500 }).fetchImpl);
  assert.equal(listFails.status, 502);
  const deleteFails = await call(ENV, {}, project([[{ bucket_id: 'materials', name: 'secret-user/private-name.pdf' }]], { deleteStatus: 500 }).fetchImpl);
  assert.equal(deleteFails.status, 502);
  const text = JSON.stringify(await deleteFails.json());
  assert.match(text, /delete_500/);
  assert.doesNotMatch(text, /service-key|private-name/);
});
