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
Android app (Kotlin)  ──(messages, tool results)──>  Supabase Edge Function "agent"  ──>  Muse Spark
   │   ▲                                                    │
   │   └──────────(text reply or tool calls)───────────────┘
   ├─ runs the tools on the phone: get_usage, create_task, set_app_limit, schedule_alarm
   └─ stores plans, messages and usage summaries in Supabase Postgres (row-level security, one user = one anonymous account)
```

- The Muse Spark key lives only in Supabase secrets. The app never sees it.
- The server is stateless per turn: the phone sends the conversation, the function adds the system prompt and
  calls the model, and answers with text or tool calls. The phone runs the tools and sends the results back.
- The phone sends **summaries** of real usage (minutes per app per day), never the raw event log.

## Repository layout

| Path | What |
|---|---|
| `supabase/functions/agent/` | the Edge Function (HTTP entry point) |
| `supabase/functions/_shared/` | prompt and tool definitions, Muse Spark client, history validation |
| `supabase/migrations/` | the Postgres schema with row-level security |
| `tests/` | unit tests for the agent logic (no network, no key needed) |
| `app/` | the Android app (added from day 2) |

## Run the tests

Node 22.18 or newer:

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

- Day 1: Edge Function (prompt, tools, Muse Spark client, validation), database schema with row-level security, unit tests.
- Assumption to confirm: Muse Spark is called as an OpenAI-compatible chat-completions API. If it is not, only
  `supabase/functions/_shared/muse.ts` changes.
