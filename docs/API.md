# Agent API

One Edge Function, `POST {SUPABASE_URL}/functions/v1/agent`. Headers:

```
Authorization: Bearer <access token of the anonymous Supabase user>
apikey: <publishable key>
Content-Type: application/json
```

Every body has an `"action"`. Errors are `{"error":{"code":"..."}}` with these statuses:
401 `not_signed_in` · 404 `conversation_not_found` · 422 a request problem (`bad_date`, `bad_mode`, `empty_message`,
`tool_results_mismatch`, `tool_results_required`, `mode_mismatch`, `conversation_too_long`, `bad_usage`, ...) ·
429 `daily_limit_reached` (this user) · 429 `demo_at_capacity` (all users together, `AGENT_GLOBAL_DAILY_LIMIT`, default 1000/day, resets at 00:00 UTC) · 500 `agent_not_configured` · 502 `agent_*` (the model) or `store_error` · 504 `agent_timeout`.

## Models (two Meta models, each the other's fallback)
- **Muse Spark** (`MUSE_BASE_URL`, `MUSE_API_KEY`, `MUSE_MODEL`): the planning, execute and review chats (tool calling),
  web search, reading photos and scanned PDFs, pictures.
- **Muse Spark Open**, Meta's open-weights model, served by Baseten (OpenAI compatible): set `OPEN_API_KEY` (optional:
  `OPEN_BASE_URL`, default `https://inference.baseten.co/v1`; `OPEN_MODEL`, default `meta-models/muse-spark-open-1026`;
  `OPEN_REASONING_EFFORT`, sent as `reasoning_effort`, default `low`: tested, the same answer with ~30 reasoning
  tokens instead of ~900; `off` sends none). It writes the nudges, the evening reminders and the
  user's own reminders. `MODEL_ROUTE` lists the jobs it does first (default `nudge,evening`; add `chat` for the chats).
- If the first model fails (down, too slow, or an empty answer), the other answers. The open model always reasons, so it
  gets at least 6000 tokens and 45 s; its reasoning (a `reasoning_content` field or `<think>` tags) is never shown.
- `nudge` and `evening` answers say which model wrote them: `"model":"open"` or `"spark"`.

## The session (anonymous user)
The app and the background watcher share one anonymous session, saved on the phone. Each refresh token works once, so
whoever refreshes saves the new pair at once and the other always reads the saved one before refreshing; if a refresh
is refused, it reads again and retries with the newer pair. The app never silently creates a new user when the session
is lost (that user would have no plans and no settings): it reports `session_lost`, and Settings > Check Lify offers to
start over.

## action: "usage"  (the phone uploads what really happened)
```json
{"action":"usage","days":[{"day":"2026-10-26","app":"Instagram","minutes":74}]}
```
Up to 200 rows. A row replaces the one for the same day and app. Answer: `{"saved":1}`.
Send **summaries**, never the raw event log.
Optionally with `"nights":[{"night":"2026-10-28","down":"03:12","up":"10:40"}]` (up to 14): when the phone went quiet
each night and was first picked up again, measured on the phone (the longest gap of at least 3 hours in its usage events
between 18:00 and 14:00 the next day; `night` is the evening's date). Phone use, never called sleep. `days` may be left
out when only `nights` is sent. The planning and review chats get `last_night_phone_down` and the recent times as facts.

## action: "evening"  (the reminder one hour before sleep)
`{"action":"evening","today":"2026-10-29","tomorrow":"2026-10-30","now":"22:00","locale":"en","done":["Gym"],"missed":["German"]}`
(`"test":true` writes it even when tomorrow is planned: the app's test button)
-> `{"planned":true}` when tomorrow already has a plan (no model call), else `{"planned":false,"text":"Hey Jake, let's make our plans for tomorrow..."}`,
written by Muse Spark from the name, today's done and missed tasks and last night's phone-down time. The phone shows it as
a card on top of other apps that opens "Plan tomorrow"; if the call fails twice, nothing is shown.
The app's day ends at 05:00, not midnight: at 01:00 `today` is still the day before, so planning then plans the day that
is about to start.

## action: "chat"
```json
{"action":"chat","mode":"planning","today":"2026-10-26","date":"2026-10-27","locale":"en",
 "conversation_id":"<omit on the first message>",
 "input":{"type":"user","text":"I want to study algorithms tomorrow"}}
```
- `mode`: `planning` (evening, plan `date`), `execute` (morning, apply the plan of `date` = today on the phone),
  `review` (evening, `today` is the day that ended, `date` is tomorrow; send `report`: `{"done":[...],"missed":[...]}`).
- The server keeps the conversation. Send only the new message, or the results of device tools.
- Answer, text: `{"type":"text","conversation_id":"...","text":"...","spoken":"...","plan_saved":false}`. `text` is what is shown; `spoken` (optional) is one or two natural sentences the agent wrote to be read aloud (the phone reads it when the person talked; without it the phone makes its own short version).
- Answer, device tools to run on the phone:
  `{"type":"tool_calls","conversation_id":"...","calls":[{"id":"call_1","name":"set_app_limit","args":{"app":"Instagram","minutes_per_day":30}}],"plan_saved":false,"artifacts":[]}`
  Run each, then send them ALL back (any order, exactly those ids):
  ```json
  {"action":"chat","mode":"execute","today":"...","date":"...","conversation_id":"...",
   "input":{"type":"tool_results","results":[{"tool_call_id":"call_1","content":"{\"ok\":true}"}]}}
  ```
  `content` is a string (JSON is fine). If a tool failed, say so in it: the agent tells the user.
- Answers are plain text: reasoning tags, markdown marks and links to our own private files are removed before the text is stored or sent (files arrive in `artifacts`).
- `plan_saved: true` means a plan was saved during this request; call `plan` to read it.
- `strategy_update` (optional, on either answer type) is set when the agent saved a new strategy version in this request (review mode): `{"version":3,"changes":["Cut Instagram limit 30 to 20"]}`. The app shows it as the "Strategy updated" card.
- `artifacts` lists what the agent made during this request for the phone to show: `[{"type":"pdf"|"image"|"markdown","title":"My day card","url":"https://..."}]` (links valid for 3 days; the file stays in Storage).

- A user message may carry `"attachments":["<document id>", ...]` (up to 3, from the `attach` action). The agent
  is told the document names and reads them with `read_document`.

### Tools
| Tool | Runs | Modes | Does |
|---|---|---|---|
| `get_usage(app, days?)` | server | planning, review | reads the uploaded usage |
| `get_plan(date)` | server | planning, execute, review | reads the saved plan |
| `save_plan(wake?, sleep?, tasks[], limits[], note?)` | server | planning, review | validates and stores the plan for `date` (replacing the stored one, so the agent first reads it with `get_plan` and keeps what should stay: new requests are ADDED); drops dead links. **Refused in the first exchange of a conversation**: the agent must show the plan and the user must answer first |
| `create_material(title, markdown, format?)` | server | planning, review | writes a study or work sheet as a **PDF** (default, A4, drawn from the markdown: headings, bullets, numbered lists, simple tables) or as `markdown`; stores it in `materials/<user id>/` and returns a link valid for 3 days. The PDF fonts are Latin only; other scripts show as `?` and the agent is told to use `markdown` instead. Appears in the chat answer's `artifacts` as `pdf` or `markdown` |
| `create_image(title, prompt, shape?)` | server | planning, review | makes one picture with Muse Image (`square`, `portrait` or `landscape`), stores it in `materials/<user id>/images/` and returns a link valid for 3 days. Max 1 per request. It also appears in the chat answer's `artifacts` |
| `fetch_url(url, offset?)` | server | planning, review | reads a public web page or PDF (12 000 characters at a time) |
| `web_search(query)` | server | planning, review | Muse's built-in `web_search` (Responses API, `/responses`): returns `{answer, sources[{title,url}], searched}`. Optional `SEARCH_MODEL` secret |
| `read_document(document_id, offset?)` | server | planning, review | reads a document the user attached |
| `save_settings(wake?, sleep?, focus?, apps?)` | server | planning, execute, review | saves what the user just said about their usual day to their profile, so no later chat asks again |
| `get_strategy()` | server | planning, execute, review | the newest strategy (below), or `null` before the first review. Planning and execute also get it in the system prompt ("Current strategy: ...") with how to apply it; the user wins on a conflict |
| `save_strategy(limits, plan_style, risk_windows?, rules, changes, evidence)` | server | review | stores a NEW version (`version` = previous + 1, `for_date` = the request's `date`; every version is kept). At most 3 `changes`, 5 `rules`, 8 `limits`. **No evidence, no change**: refused when there are changes but no evidence, or a change or evidence line without a number. Returns `{saved, version, for_date, changes}` and sets `strategy_update` |
| `get_experiment_results(days?)` | server | planning, review | totals of the experiments (see action `experiments`): per nudge style how often sent and left, `prob_best`, `best` (at least 75% likely and sent 3+ times), apps, the hours limits were hit, and a note that it is an early signal |
| `get_calendar(date)` | phone | planning, execute, review | the phone's calendar events that day: `{"ok":true,"access":true,"events":[{"title","start":"10:00","end":"12:00","all_day"?,"free"?}]}`, or `{"ok":true,"access":false,"note":...}` without the Calendar permission |
| `set_session_rule(app, minutes, ask)` | phone | planning, execute, review | the user's own reminder: whenever they spend `minutes` (5-240) in a row on `app` (`"any"` = every app), the phone sends a personal reminder to do `ask` ("do 10 push-ups"), written by Muse Spark (`nudge` reason `session`). Replaces the rule for the same app; stays until removed |
| `remove_session_rule(app)` | phone | planning, execute, review | removes that app's reminder |
| `create_task(title, minutes, first_step?, instructions?, links?, start_time?, notes?)` | phone | execute | add to Today. `links` (up to 6, 1000 characters each, so signed links to our own files fit) and `notes` (what was decided in the chat) are shown on the task's own screen |
| `set_app_limit(app, minutes_per_day)` | phone | execute | set a daily limit |
| `schedule_alarm(time, message, kind, task_title?)` | phone | execute | an alarm today at HH:MM. `kind` `phone`: a real alarm in the phone's Clock app (gym, prayer, leaving home). `kind` `in_app`: Life rings and opens the task's screen (links, PDFs, pictures, steps, notes). The agent picks the kind per task |

## action: "strategy"  (what Lify learned, every version)
`{"action":"strategy"}` -> `{"strategy":{...newest...},"history":[{...newest first, at most 30...}]}`. One version:
```json
{"version":3,"for_date":"2026-10-30","created_at":"...",
 "limits":[{"app":"Instagram","minutes":20,"why":"74 min vs 30 limit, 21:00-23:00"}],
 "plan_style":{"max_tasks":3,"buffer_pct":30,"best_window":"09:00-12:00"},
 "risk_windows":["21:00-23:00"],
 "rules":["Max 3 tasks","Schedule an alarm at 20:45"],
 "changes":["Cut Instagram limit 30 to 20","Reduced plan from 5 tasks to 3"],
 "evidence":["Finished 3 of 5 tasks on each of the last 2 days"]}
```
Written only by the agent in review mode (`save_strategy`), stored in the `strategies` table (one row per version).

## action: "experiments"  (which personal nudge style works for this user; opt-in)
At each limit hit, code on the phone (never the model) picks the nudge style by **contextual Thompson sampling**: for
this app and time-of-day band (`morning`, `afternoon`, `evening`, `night`) each style has a Beta belief about its chance
of making the user leave the app. Its prior is the style's rate in all OTHER moments, worth 4 tries (hierarchical
shrinkage), plus this moment's own results; one value is drawn per style, the highest draw wins. The chosen style's
**propensity** (its chance of winning the draw, from 400 extra draws) is logged with it. Muse Spark then writes that nudge (action `nudge` with `style`), shown as a notification. Styles: `task` (the
next task and its first step), `cost` (what the time costs, in their numbers), `goal` (their own goal, in their words).
The phone measures whether the user left the app within 2 minutes and how long they spent in it over the next 15 (demo
mode: 15 s in the app is a hit, left within 20 s, a 1 minute window), then sends the results:
```json
{"action":"experiments","today":"2026-10-29","log":[{"id":"<uuid>","day":"2026-10-29","time":"21:14","app":"Instagram",
  "arm":"task","explore":false,"reason":"limit","left":true,"seconds_after":40,"window_seconds":900,"demo":false,
  "propensity":0.81,"context":"night","message":"Ayoub, German at 21:00..."}]}
```
`propensity`, `context` and `message` (the words Muse Spark wrote, at most 300 characters) are optional for older events.
`explore` is true when the draw picked a style that is not the best on average so far. `reason`: `approaching` | `limit`
| `over` | `event` (during a calendar event) | `demo`. Up to 50 per call; an `id` already stored is ignored, so a retried
upload is safe. Without `log` it only reads. Answer (last `days`, default 14):
`{"results":{"events":20,"days":2,"demo_events":0,"best":"task","arms":[{"arm":"task","label":"nudges with your next task","tried":9,"left":7,"left_rate":0.78,"avg_minutes_after":1.5,"prob_best":0.87},...],"by_app":[{"app":"Instagram","hits":20,"left":11}],"hits_by_hour":[{"hour":"21:00","hits":12}],"note":"Early signal ..."}}`.
The answer also has `policy` (off-policy evaluation, from 10 events with a propensity): `life_rate` (how often the
user left with Life's own choices), `fixed` (self-normalised inverse propensity estimates of "always send this style",
with effective sample sizes), `best_fixed`, `random`, `lift` (life_rate minus the best fixed) and `lift_interval` (90%
bootstrap, 500 resamples, seeded); `contexts` (per app and band: hits, per-style counts, `leading` from 4 hits); and
`log` (the 40 newest nudges, newest first: time, app, band, style, `explore`, `propensity`, `message`, `left`,
`minutes_after`), which the app shows as the lab notebook.
`prob_best` is the chance each style is the best given the results (4000 joint posterior draws, seeded, so stable).
`best` is set only when that chance is at least 75% and the style was sent at least 3 times. One person over a few
days: the app always shows the sample sizes and calls it an early signal.

## action: "plan"
`{"action":"plan","date":"2026-10-27"}` -> `{"plan":{"date":"...","status":"ready","data":{"tasks":[...],"limits":[...]}}}` or `{"plan":null}`.

## action: "profile"  (settings asked in the app, not in the chat)
`{"action":"profile","set":{"wake":"07:00","sleep":"23:30","apps":["Instagram","TikTok"],"focus":"my thesis","name":"Mo"}}`
`name` is the first name from onboarding (at most 40 characters).
Only the fields sent are saved. Without `set` it just reads. Answer: `{"profile":{"wake":"07:00","sleep":"23:30","apps":[...],"focus":"...","name":"Mo"}}`.
The agent receives these as known facts and never asks for them.

## action: "attach"  (a PDF, a photo or a text file the user sends)
1. The phone uploads the file to Storage: `POST {SUPABASE_URL}/storage/v1/object/uploads/<user id>/<file name>`
   with the user's token (max 10 MB). **Photos:** PNG, JPEG or WebP, **at most 5 MB** (the type is read from the bytes).
2. `{"action":"attach","path":"<user id>/<file name>","name":"Lecture 3.pdf"}` ->
   `{"document_id":"...","name":"...","kind":"pdf","pages":12,"chars":41000,"truncated":false,"file_path":null}`.
   `kind` is `pdf`, `text` or `image`; `read_by` is `text` (read on the server, free) or `vision`. A photo is read once by Muse Spark
   (it transcribes the text and describes the layout). A PDF with no text layer (a scan, slides that are pictures) is also
   sent to Muse Spark, which reads the pages as images (Meta converts the first 50 pages). Both count as one request against the daily caps.
   Errors: `bad_path`, `file_not_found`, `pdf_unreadable`, `no_text_in_document` (a scan), `unsupported_file`,
   `image_too_large`, `image_unreadable`, `daily_limit_reached`, `demo_at_capacity`.
3. Send `document_id` in `attachments` of the next chat message. The agent sees a photo as text (with a warning that it
   may be misread) and opens it with `read_document`.
4. **Storage:** the original is **deleted after it has been read** (`file_path: null`), because photos and PDFs can be several MB and the
   agent only needs the text, which is kept in the `documents` table. Set the secret `KEEP_ORIGINALS=true` to keep the original in the
   private bucket `uploads/<user id>/...` instead (then `file_path` says where). Pictures the agent makes are about 100 to 300 KB and PDF
   sheets about 2 KB; both go to `materials/<user id>/`.
   The phone should shrink photos before uploading (about 1600 px on the long side, JPEG quality 80, which is a few hundred KB).

## action: "speak"  (Lify's voice)

`{"action":"speak","text":"Jake, forty minutes on TikTok <chuckle>"}` -> `{"audio":"<base64 WAV, 24 kHz mono>","format":"wav","voice":"tara"}`.
Orpheus TTS deployed on Baseten (`TTS_URL` = its predict URL; key `TTS_API_KEY`, else `OPEN_API_KEY`; `TTS_VOICE`
tara/leah/jess/leo/dan/mia/zac/zoe). Markdown, links and emoji are removed; `<laugh> <chuckle> <sigh> <gasp> <groan> <yawn>`
are kept. Not set up: `501 tts_not_configured`, and the app uses the phone's voice.

## action: "transcribe"  (the user talks instead of typing)
1. The phone records, wraps the audio in a WAV header (**mono, 16-bit, 16 or 24 kHz**, under 10 minutes; the 10 MB
   upload limit means about 3 to 5 minutes), and uploads it to `uploads/<user id>/<name>.wav` like an attachment.
2. `{"action":"transcribe","path":"<user id>/<name>.wav","languages":["English","French"],"keywords":["algorithms"]}` ->
   `{"text":"I need to study algorithms tomorrow","duration_ms":4000}`.
   The user's distracting apps are added as keywords automatically. The recording is deleted after use.
   Errors: `bad_path`, `file_not_found`, `bad_audio_not_wav` / `_not_mono` / `_not_16bit_pcm` / `_bad_sample_rate` /
   `_too_long` / `_empty_audio`, `no_speech`, `daily_limit_reached`, `agent_upstream_status`.
3. Send `text` as the next chat message. Speech output (reading the answer aloud) is the phone's text-to-speech.
Uses Muse Voice Transcribe: `POST {base}/asr/transcribe` (multipart), model `muse-voice-transcribe-1.0`. Set `ASR_MODEL` or
`ASR_BASE_URL` secrets only if they differ from the chat model's.

## action: "nudge"  (the agent speaks up in the middle of a session)
```json
{"action":"nudge","today":"2026-10-27","now":"17:40","app":"TikTok","used_minutes":52,"limit_minutes":60,
 "reason":"approaching","locale":"en","done":["Gym"]}
```
`reason`: `approaching` | `limit` | `over` | `event` (a limited app opened during a calendar event; send `event_title`) | `session` (the user's own reminder rule fired; send `ask` and `session_minutes`, `limit_minutes` is not needed). `style`: `task` (default) | `cost` | `goal`, what the message leans on (see `experiments`). `done`: titles of today's tasks already finished.
Answer: `{"text":"...at most 280 characters, plain text...","task":"Study algorithms","style":"task"}` (`task` is null if nothing is left).
One short model call; the server reads today's plan and the user's settings itself. The phone shows `text` as a card on
top of the app (app icon, a bold line from the phone's numbers such as "2 hours on TikTok", then `text`; a countdown bar,
tap to open Life, swipe up to dismiss), or as a notification without the overlay permission. There are no fixed messages:
if the call fails twice, no nudge is shown.

## The daily loop
1. Day: the app uploads `usage`.
2. Evening: `chat` `planning` until `plan_saved: true`.
3. During the day: when the user is on a distracting app near or over the limit, `nudge`.
4. Morning: `chat` `execute` -> run the device tool calls -> send results -> text.
5. Next evening: upload `usage`, `chat` `review` with the `report`: the agent updates the strategy (`save_strategy`), then offers to adapt tomorrow's plan.
6. The next planning and morning runs apply the newest strategy.


## Automatic cleanup of stored files (function `cleanup`)
Files the agent makes (PDF sheets, pictures) and any leftover uploads are deleted **3 days** after they were last written, so the
free storage never fills up. Links to them also last 3 days. Only files in the `materials` and `uploads` buckets are touched.
The text in the database (documents, plans, messages) is kept.

- `POST /functions/v1/cleanup` with header `x-cleanup-secret: <CLEANUP_SECRET>` and an optional body `{"dry_run":true}` (lists what would go, deletes nothing).
  Answer: `{"days":3,"dry_run":false,"deleted":{"materials":4,"uploads":1},"total":5}`.
  Errors: 401 `unauthorized`, 405, 500 `not_configured` (no secret of at least 16 characters, or no service key), 502 `cleanup_failed`.
- Secrets: `CLEANUP_SECRET` (required), `CLEANUP_DAYS` (optional, default 3). The service role key is provided by Supabase itself.
- It is called once a day by Supabase Cron (pg_cron + pg_net); see "Cleanup setup" in the README.
