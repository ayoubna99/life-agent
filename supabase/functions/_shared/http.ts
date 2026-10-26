// The request handler, kept free of Deno APIs so the tests can call it directly.

import { BadRequest, NotFound, parseChatRequest, QuotaExceeded, runChat } from './loop.ts';
import { configFromEnv, MuseError } from './muse.ts';
import { isDate } from './plan.ts';
import { RestStore, StoreError } from './store.ts';
import type { Store, UsageRow } from './store.ts';

export interface HandlerEnv {
  get(name: string): string | undefined;
  fetchImpl?: typeof fetch;
  /** Tests inject a store; production builds a RestStore from the caller's token. */
  storeFor?: (userId: string, jwt: string, apikey: string) => Store;
}

const json = (body: unknown, status = 200): Response =>
  new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' } });

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/** The gateway already verified the signature (verify_jwt); we only read who it is. Every database call
 *  is made with this same token, so row-level security would refuse anything that is not theirs. */
export function userFromAuthHeader(header: string | null): { userId: string; jwt: string } | null {
  const m = /^Bearer ([\w-]+\.[\w-]+\.[\w-]+)$/.exec(header ?? '');
  if (!m) return null;
  try {
    const b64 = m[1].split('.')[1].replace(/-/g, '+').replace(/_/g, '/');
    const claims = JSON.parse(atob(b64.padEnd(Math.ceil(b64.length / 4) * 4, '=')));
    if (typeof claims.sub !== 'string' || !UUID.test(claims.sub) || claims.role !== 'authenticated') return null;
    if (typeof claims.exp === 'number' && claims.exp * 1000 < Date.now()) return null;
    return { userId: claims.sub, jwt: m[1] };
  } catch {
    return null;
  }
}

const MAX_USAGE_ROWS = 200;

function parseUsage(body: Record<string, unknown>): UsageRow[] {
  const days = body.days;
  if (!Array.isArray(days) || days.length === 0 || days.length > MAX_USAGE_ROWS) throw new BadRequest('bad_usage');
  const seen = new Set<string>();
  return days.map((r: Record<string, unknown>) => {
    const app = typeof r?.app === 'string' ? r.app.trim() : '';
    if (!isDate(r?.day) || !app || app.length > 60 || typeof r.minutes !== 'number' || !Number.isInteger(r.minutes) || r.minutes < 0 || r.minutes > 1440) {
      throw new BadRequest('bad_usage');
    }
    const key = `${r.day}|${app.toLowerCase()}`;
    if (seen.has(key)) throw new BadRequest('bad_usage');
    seen.add(key);
    return { day: r.day as string, app, minutes: r.minutes as number };
  });
}

export async function handle(req: Request, env: HandlerEnv): Promise<Response> {
  if (req.method !== 'POST') return json({ error: { code: 'method_not_allowed' } }, 405);

  const who = userFromAuthHeader(req.headers.get('Authorization'));
  if (!who) return json({ error: { code: 'not_signed_in' } }, 401);

  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return json({ error: { code: 'invalid_json' } }, 400);
  }
  if (!body || typeof body !== 'object') return json({ error: { code: 'invalid_json' } }, 400);

  const supabaseUrl = env.get('SUPABASE_URL') ?? '';
  const apikey = req.headers.get('apikey') ?? env.get('SUPABASE_ANON_KEY') ?? '';
  const store =
    env.storeFor?.(who.userId, who.jwt, apikey) ??
    new RestStore({ supabaseUrl, apikey, jwt: who.jwt, userId: who.userId, fetchImpl: env.fetchImpl });

  try {
    switch (body.action) {
      case 'chat': {
        const limit = Number(env.get('AGENT_DAILY_LIMIT'));
        const result = await runChat(parseChatRequest(body), {
          cfg: configFromEnv((n) => env.get(n)),
          store,
          userId: who.userId,
          supabaseUrl,
          dailyLimit: Number.isInteger(limit) && limit > 0 ? limit : 80,
          fetchImpl: env.fetchImpl,
        });
        return json(result);
      }
      case 'usage': {
        const rows = parseUsage(body);
        await store.upsertUsage(rows);
        return json({ saved: rows.length });
      }
      case 'plan': {
        if (!isDate(body.date)) throw new BadRequest('bad_date');
        return json({ plan: await store.getPlan(body.date) });
      }
      default:
        throw new BadRequest('unknown_action');
    }
  } catch (e) {
    if (e instanceof BadRequest) return json({ error: { code: e.reason } }, 422);
    if (e instanceof QuotaExceeded) return json({ error: { code: 'daily_limit_reached' } }, 429);
    if (e instanceof NotFound) return json({ error: { code: 'conversation_not_found' } }, 404);
    if (e instanceof StoreError) {
      console.error(`agent: ${e.message}`);
      return json({ error: { code: 'store_error' } }, 502);
    }
    if (e instanceof MuseError) {
      // The kind and status only: never the key, the prompt or what the user wrote.
      console.error(`agent: ${e.message}`);
      const status = e.code === 'not_configured' ? 500 : e.code === 'timeout' ? 504 : 502;
      return json({ error: { code: `agent_${e.code}` } }, status);
    }
    console.error('agent: unexpected error');
    return json({ error: { code: 'internal' } }, 500);
  }
}
