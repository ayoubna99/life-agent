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
Android app (Flutter + a little Kotlin) ──> Supabase Edge Function "agent" ──> Muse Spark
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
- **Strategy memory:** in review mode the agent compares plan and reality and saves a new strategy version
  (`save_strategy`: at most 3 changes, each citing a number; no evidence, no change). Planning and the morning run apply the
  newest version. Every version is kept, so the app shows day 1 next to today.
- **Personal nudges, tested on the user (opt-in):** at each limit hit, Muse Spark writes a notification from the user's own
  plan, numbers and words, in one of three styles (next task, what the time costs, own goal). Code on the phone (not the
  model) picks the style by Thompson sampling, measures whether the user left the app and how long they stayed, and
  uploads the result. The agent reads the totals (`get_experiment_results`, with each style's chance of being the best) in
  review; the app shows them with sample sizes as an early signal. Demo mode compresses the thresholds to seconds.
- **Calendar-aware:** `get_calendar` (device tool, Calendar permission) lets the agent plan around real events and set
  reminders before them; the watcher nudges at once when a limited app is opened during an event.
- **Evening reminder and phone-down times:** one hour before the user's sleep time, Muse Spark writes "Hey Jake, let's
  make our plans for tomorrow" (skipped if tomorrow is planned); tapping it opens the planning chat. The phone measures when
  it went quiet each night, so the app and the agent can say "last night your phone went quiet at 03:12" (phone use, never
  a sleep claim). The day ends at 05:00, so planning after midnight still plans the coming day.
- **Tasks carry everything, and alarms fit the task:** a task keeps its links, study sheet, pictures, steps and a summary of
  the chat. Its alarm is either a real phone alarm (gym, prayer, leaving home) or an in-app alarm that rings and opens the
  task's own screen with all of it (reading, emails, study); the agent picks per task. Outside the app Life shows only cards
  and alarms (a notification is used only when "show over other apps" is not allowed).
- **Two Meta models:** Muse Spark runs the planning chats (tool calling, search, vision, pictures); Muse Spark Open, Meta's
  open-weights model on Baseten, writes every nudge and evening reminder. Each is the other's fallback.
- **Your own reminders:** "whenever I am 30 minutes on an app, remind me to do 10 push-ups" becomes a rule on the phone
  (`set_session_rule`); each reminder is written fresh by Muse Spark.
- **Mid-session nudge:** `nudge` returns one short, personal message about the user's next task while they are on an app.
- **Voice:** `transcribe` turns a short recording into text with Muse Voice Transcribe, and the text goes into the chat.
- **Study sheets as real PDFs:** `create_material` writes an A4 PDF (headings, lists, tables) and stores it in the user's private folder; the link goes into the plan task.
- **Photos in and out:** a photo the user sends (timetable, whiteboard, notes) is read by Muse Spark and kept as text (the original is deleted after reading, to save storage); `create_image` makes a picture (e.g. a shareable card of the day) with Muse Image and stores it in the user's private folder.
- **Reads the web and documents:** `fetch_url`, `web_search` (Muse's own built-in search, with cited sources) and PDFs or text files the user sends.
- The Muse Spark key lives only in Supabase secrets. A daily per-user cap protects the credits.
- Links the model suggests are checked before they are saved; dead or unsafe ones are dropped.
- See [docs/API.md](docs/API.md) for every request and answer.

## The night shift: Lify as a scientist studying one person

Every night **Muse Spark Open** reads the user's whole history in one request, using its 1M-token context instead of
retrieval: every nudge it ever sent with what the user did next, their nights, plans and settings, and its own theories
from the night before. It thinks harder than during the day (`reasoning_effort: "medium"`; nudges use `"low"`) and:

1. **Theories:** keeps, revises or rejects each theory against the new results, with counts ("left 4 of 6 after 22:00"),
   and proposes new ones.
2. **Experiment design:** writes tomorrow's **nudge bank**: short lines grouped by **angle** (the idea behind them). It
   writes more lines for the angles that work, adds one or two new angles to test, and drops the ones that failed.
3. **Critic:** a second pass plays "the user's inner skeptic" (`reasoning_effort: "low"`) and cuts generic, preachy or
   repeated lines.
4. **Validation (code):** at most 12 words, no minute counts, no "you're at your limit", no health language, never a
   line already sent.

During the day the phone picks from the bank with **Thompson sampling over angles**, not sentences. A winning idea keeps
coming back in new words, never the same line twice. The card shows at once, with no model call and no network. The open
model's visible reasoning is kept as an excerpt ("how Lify thought about it") in the app. Code: `nightshift.ts`,
`core/Bank.kt`.

## How Life measures itself (not just prompts)

The model writes; code decides and measures. Nothing below can be changed by prompting the model.

1. **Decision (phone, Kotlin):** at each limit hit, contextual Thompson sampling picks one of three nudge styles for
   this app at this time of day. Each style has a Beta posterior; its prior comes from the user's other moments
   (hierarchical shrinkage), so a new moment starts from what is already known. The chance of the choice (the
   propensity) is computed by Monte Carlo and logged.
2. **Words (server, Muse Spark):** the nudge is written for that style from the user's plan, goal, name and numbers. No
   fixed messages: if the model cannot be reached, no nudge is sent and nothing is measured.
3. **Outcome (phone):** Android usage events say whether the user left the app within 2 minutes, and how many minutes
   they spent in it over the next 15. The posterior updates.
4. **Evaluation (server):** with the logged propensities, self-normalised inverse propensity scoring estimates how a
   fixed nudge would have done on the same moments, so Life's lift over the best fixed nudge has a 90% bootstrap interval.
   The test suite checks that the estimator recovers known rates from heavily biased logging.
5. **Memory (server, Muse Spark):** each evening the agent reads these results and writes a new strategy version. The
   server refuses any change that does not cite a number, and every version is kept.
6. **Transparency (app):** the lab notebook shows every nudge, its words, why that style was picked (and with what
   chance), and what the user did next. The cards say "early signal" and show sample sizes.

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
| `app/` | the Android app: Flutter screens and agent client (`app/lib`, `app/test`), plus the Kotlin that only Android can do (`app/android/app/src/main/kotlin`). See [app/README.md](app/README.md) |

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

- **Backend, unit tested (184 tests):** the agent loop, the three modes, server and device tools, plan validation, link checks,
  storage, token handling, per-user and global caps, PDF in and out, photos in and out, voice, cleanup, strategy memory, experiments, the night shift. The migrations were applied
  to a local Postgres 16 and their security rules checked. Functions ran in the real Deno runtime for the PDF writer and reader.
- **App, unit and widget tested (148 Dart tests, 63 Kotlin tests):** sign-in, the API client, the chat loop with device tools, chat, voice,
  files and photos, home, settings, the usage maths, nudge rules and app-name matching.
- **Not yet run on a phone or against Meta's live API:** real Muse Spark tool calls, `/responses` (web search, photos, scanned PDFs),
  `/images/generations`, Voice Transcribe, and everything Android-specific (usage stats, alarms, the watcher service and the overlay).
  The Kotlin glue compiles against the real Android 15 classes but has not run. See [app/README.md](app/README.md).
- Assumption to confirm: Muse Spark is called as an OpenAI-compatible chat-completions API with tool calling.
  If it is not, only `supabase/functions/_shared/muse.ts` changes.

## Cleanup setup (files older than 3 days are deleted)
1. `node -e "console.log(require('crypto').randomBytes(24).toString('hex'))"` makes a secret. Then
   `npx supabase secrets set CLEANUP_SECRET=<that secret>`.
2. `npx supabase db push` (adds the `expired_files` SQL function) and `npx supabase functions deploy cleanup --no-verify-jwt`.
3. Try it without deleting anything:
   `curl.exe -X POST https://<ref>.supabase.co/functions/v1/cleanup -H "x-cleanup-secret: <secret>" -H "Content-Type: application/json" -d "{\"dry_run\":true}"`
4. Run it daily: in the Supabase dashboard enable the extensions `pg_cron` and `pg_net` (Database -> Extensions), then in the SQL editor:
   ```sql
   select cron.schedule('cleanup-files', '17 3 * * *', $$
     select net.http_post(
       url := 'https://<ref>.supabase.co/functions/v1/cleanup',
       headers := '{"Content-Type":"application/json","x-cleanup-secret":"<secret>"}'::jsonb,
       body := '{}'::jsonb);
   $$);
   ```
