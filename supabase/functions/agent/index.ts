// POST /functions/v1/agent   body: {"messages":[...]}   header: Authorization: Bearer <Supabase JWT>
// Answers {"type":"text","text":"..."} or {"type":"tool_calls","calls":[...],"assistant":{...}}.
// The Muse Spark key lives in Supabase secrets and never leaves this function.

import { BadRequest, runTurn } from '../_shared/agent.ts';
import { configFromEnv, MuseError } from '../_shared/muse.ts';

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' },
  });
}

Deno.serve(async (req: Request) => {
  if (req.method !== 'POST') return json({ error: { code: 'method_not_allowed' } }, 405);

  let body: unknown;
  try {
    body = await req.json();
  } catch {
    return json({ error: { code: 'invalid_json' } }, 400);
  }

  try {
    const cfg = configFromEnv((name) => Deno.env.get(name));
    return json(await runTurn(body, cfg));
  } catch (e) {
    if (e instanceof BadRequest) return json({ error: { code: e.reason } }, 422);
    if (e instanceof MuseError) {
      // Log the kind and status only: never the key, the prompt or what the user wrote.
      console.error(`agent: ${e.message}`);
      const status = e.code === 'not_configured' ? 500 : e.code === 'timeout' ? 504 : 502;
      return json({ error: { code: `agent_${e.code}` } }, status);
    }
    console.error('agent: unexpected error');
    return json({ error: { code: 'internal' } }, 500);
  }
});
