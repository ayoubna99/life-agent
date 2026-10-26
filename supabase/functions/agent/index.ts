// POST /functions/v1/agent
//   {"action":"chat",  "mode":"planning|execute|review", "today":"YYYY-MM-DD", "date":"YYYY-MM-DD",
//    "conversation_id"?:..., "locale"?:..., "report"?:{done:[],missed:[]}, "input":{"type":"user","text":"..."}}
//   {"action":"usage", "days":[{"day":"YYYY-MM-DD","app":"Instagram","minutes":74}, ...]}
//   {"action":"plan",  "date":"YYYY-MM-DD"}
// Header: Authorization: Bearer <Supabase JWT>. The Muse Spark key lives in Supabase secrets only.

import { handle } from '../_shared/http.ts';

Deno.serve((req: Request) => handle(req, { get: (name) => Deno.env.get(name) }));
