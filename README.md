# Life: an agent that plans your day and keeps you to it

Life is an Android app that helps people scroll less and do what matters to them.
The night before, you talk to an agent (powered by Meta's Muse Spark) about tomorrow. It asks until it has
everything, estimates how long each task takes, and saves the plan. The next day the agent acts on the plan
through tool calls on your phone, using your real screen-time data: it creates tasks, sets app limits and
schedules alarms. When you reach a limit, Life opens with what the agent prepared for your next task
(instructions, links, files) so starting is easier than scrolling. You can always override it, but it becomes a choice.

It is a planner and enforcer, not a general chatbot, and it gives no medical, mental-health or education advice.

## Hackathon disclosure

Before the hackathon I built an early prototype of this idea (an Android app and a small backend).
**None of its code is in this repository.** Everything here was written from scratch starting 26 Oct 2026.
See the git history: the first commit of this repository is dated 26 Oct 2026.

## Architecture

```
Android app (Kotlin) ──> Supabase Edge Function "agent" ──> Muse Spark
   │                         │  server tools: get_usage, get_plan, save_plan, create_material
   │                         └─ Postgres (plans, messages, usage) + Storage (study sheets), row-level security
   └─ device tools, run on the phone: create_task, set_app_limit, schedule_alarm
```

- **The server remembers the conversation.** The phone sends only the new message (or the results of device tools).
- **Three modes, one agent:** *planning* (evening: asks until it has everything, estimates durations, prepares material,
  saves the plan), *execute* (morning: applies the plan on the phone through device tool calls), *review* (evening:
  compares the plan with real usage and adapts tomorrow's plan).
- **Real data:** the phone uploads usage summaries (minutes per app per day). The agent reads them with `get_usage`.
- **Settings asked in the app:** wake and sleep times, distracting apps and focus are saved by the app (`profile`) and
  handed to the agent as known facts, so the chat never asks for them. The agent estimates task durations itself.
- **Mid-session nudge:** `nudge` returns one short, personal message about the user's next task while they are on an app.
- **Voice:** `transcribe` turns a short recording into text with Muse Voice Transcribe, and the text goes into the chat.
- **Reads the web and documents:** `fetch_url`, `web_search` (Muse's own built-in search, with cited sources) and PDFs or text files the user sends.
- The Muse Spark key lives only in Supabase secrets. A daily per-user cap protects the credits.
- Links the model suggests are checked before they are saved; dead or unsafe ones are dropped.
- See [docs/API.md](docs/API.md) for every request and answer.

## Repository layout

| Path | What |
|---|---|
| `supabase/functions/agent/` | the Edge Function (HTTP entry point) |
| `supabase/functions/_shared/` | prompts and tools, Muse Spark client, the agent loop, storage, plan and link checks |
| `supabase/migrations/` | the Postgres schema with row-level security |
| `tests/` | unit tests with a scripted model and an in-memory store (no network, no key) |
| `scripts/chat.mjs` | talk to the deployed agent from a terminal: planning, settings, a PDF, the mid-session nudge |
| `scripts/smoke.ps1` | runs the whole flow against your Supabase project |
| `docs/API.md` | the API |
| `app/` | the Android app (added from day 2) |

## Run the tests

Node 22.6 or newer (the test script turns on TypeScript support itself):

```
npm test
```

## Set up your own Supabase project

1. Create a project at supabase.com. In *Authentication > Providers*, turn on **Anonymous sign-ins**.
2. Install the CLI (`npm i -g supabase`, or use `npx supabase`), then in this folder:
   ```
   supabase login
   supabase link --project-ref YOUR_PROJECT_REF
   supabase db push
   supabase secrets set MUSE_BASE_URL=https://.../v1 MUSE_API_KEY=... MUSE_MODEL=...
   supabase functions deploy agent
   ```
3. Try it (replace the two values; the anon key is in *Project settings > API*):
   ```
   # an anonymous user and its token
   curl -s -X POST "https://YOUR_PROJECT_REF.supabase.co/auth/v1/signup" -H "apikey: ANON_KEY" -H "Content-Type: application/json" -d "{}"

   # ask the agent
   curl -s -X POST "https://YOUR_PROJECT_REF.supabase.co/functions/v1/agent" \
     -H "Authorization: Bearer ACCESS_TOKEN" -H "apikey: ANON_KEY" -H "Content-Type: application/json" \
     -d '{"messages":[{"role":"user","content":"Help me plan tomorrow"}]}'
   ```

## Status

- Done and unit tested (99 tests, including a real PDF read with the real PDF library): the agent loop, the three modes, server and device tools, plan validation, link checks,
  the storage layer's requests, token handling, per-user cap. Both migrations were applied to a local Postgres 16 and
  their security rules checked.
- Not yet run against the real services: the deployed function with real Muse Spark tool calls (use `scripts/smoke.ps1`).
- Assumption to confirm: Muse Spark is called as an OpenAI-compatible chat-completions API with tool calling.
  If it is not, only `supabase/functions/_shared/muse.ts` changes.
