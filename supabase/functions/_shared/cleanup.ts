// Deletes stored files older than N days (default 3) from the "materials" and "uploads" buckets, so the free
// storage never fills up. Called once a day by Supabase Cron. It needs the service role key, so it is locked
// behind its own secret: without CLEANUP_SECRET set it refuses everything.

import { limitFromEnv } from './loop.ts';

export const DEFAULT_RETENTION_DAYS = 3;
const BATCH = 500;
const MAX_BATCHES = 6;

export interface CleanupEnv {
  get(name: string): string | undefined;
  fetchImpl?: typeof fetch;
}

const json = (body: unknown, status = 200): Response =>
  new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' } });

/** Same answer for a wrong and a missing secret, and no early exit on the first wrong character. */
function sameSecret(given: string, wanted: string): boolean {
  const a = new TextEncoder().encode(given);
  const b = new TextEncoder().encode(wanted);
  let diff = a.length ^ b.length;
  for (let i = 0; i < Math.max(a.length, b.length); i++) diff |= (a[i] ?? 0) ^ (b[i] ?? 0);
  return diff === 0;
}

export async function handleCleanup(req: Request, env: CleanupEnv): Promise<Response> {
  const secret = env.get('CLEANUP_SECRET')?.trim();
  const supabaseUrl = env.get('SUPABASE_URL')?.trim().replace(/\/+$/, '');
  const serviceKey = env.get('SUPABASE_SERVICE_ROLE_KEY')?.trim();
  if (!secret || secret.length < 16 || !supabaseUrl || !serviceKey) return json({ error: { code: 'not_configured' } }, 500);
  if (req.method !== 'POST') return json({ error: { code: 'method_not_allowed' } }, 405);
  if (!sameSecret(req.headers.get('x-cleanup-secret') ?? '', secret)) return json({ error: { code: 'unauthorized' } }, 401);

  let dryRun = false;
  try {
    const body = (await req.json()) as { dry_run?: unknown } | null;
    dryRun = body?.dry_run === true;
  } catch {
    // no body is fine
  }
  const days = limitFromEnv(env.get('CLEANUP_DAYS'), DEFAULT_RETENTION_DAYS);
  const f = env.fetchImpl ?? fetch;
  const auth = { apikey: serviceKey, Authorization: `Bearer ${serviceKey}` };

  const deleted: Record<string, number> = { materials: 0, uploads: 0 };
  try {
    for (let round = 0; round < MAX_BATCHES; round++) {
      const res = await f(`${supabaseUrl}/rest/v1/rpc/expired_files`, {
        method: 'POST',
        headers: { ...auth, 'Content-Type': 'application/json' },
        body: JSON.stringify({ p_days: days, p_limit: BATCH }),
      });
      if (!res.ok) throw new Error(`list_${res.status}`);
      const rows = (await res.json()) as { bucket_id?: unknown; name?: unknown }[];
      const byBucket = new Map<string, string[]>();
      for (const r of rows) {
        if ((r.bucket_id !== 'materials' && r.bucket_id !== 'uploads') || typeof r.name !== 'string') continue;
        byBucket.set(r.bucket_id, [...(byBucket.get(r.bucket_id) ?? []), r.name]);
      }
      if (byBucket.size === 0) break;
      if (dryRun) {
        for (const [bucket, names] of byBucket) deleted[bucket] += names.length;
        break; // a dry run only reports the first batch
      }
      for (const [bucket, names] of byBucket) {
        const del = await f(`${supabaseUrl}/storage/v1/object/${bucket}`, {
          method: 'DELETE',
          headers: { ...auth, 'Content-Type': 'application/json' },
          body: JSON.stringify({ prefixes: names }),
        });
        if (!del.ok) throw new Error(`delete_${del.status}`);
        deleted[bucket] += names.length;
      }
      if (rows.length < BATCH) break;
    }
  } catch (e) {
    console.error('cleanup failed:', (e as Error).message);
    return json({ error: { code: 'cleanup_failed', detail: (e as Error).message }, deleted }, 502);
  }
  return json({ days, dry_run: dryRun, deleted, total: deleted.materials + deleted.uploads });
}
