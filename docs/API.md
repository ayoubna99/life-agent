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

## action: "usage"  (the phone uploads what really happened)
```json
{"action":"usage","days":[{"day":"2026-10-26","app":"Instagram","minutes":74}]}
```
Up to 200 rows. A row replaces the one for the same day and app. Answer: `{"saved":1}`.
Send **summaries**, never the raw event log.

## action: "chat"
```json
{"action":"chat","mode":"planning","today":"2026-10-26","date":"2026-10-27","locale":"en",
 "conversation_id":"<omit on the first message>",
 "input":{"type":"user","text":"I want to study algorithms tomorrow"}}
```
- `mode`: `planning` (evening, plan `date`), `execute` (morning, apply the plan of `date` = today on the phone),
  `review` (evening, `today` is the day that ended, `date` is tomorrow; send `report`: `{"done":[...],"missed":[...]}`).
- The server keeps the conversation. Send only the new message, or the results of device tools.
- Answer, text: `{"type":"text","conversation_id":"...","text":"...","plan_saved":false}`.
- Answer, device tools to run on the phone:
  `{"type":"tool_calls","conversation_id":"...","calls":[{"id":"call_1","name":"set_app_limit","args":{"app":"Instagram","minutes_per_day":30}}],"plan_saved":false}`
  Run each, then send them ALL back (any order, exactly those ids):
  ```json
  {"action":"chat","mode":"execute","today":"...","date":"...","conversation_id":"...",
   "input":{"type":"tool_results","results":[{"tool_call_id":"call_1","content":"{\"ok\":true}"}]}}
  ```
  `content` is a string (JSON is fine). If a tool failed, say so in it: the agent tells the user.
- `plan_saved: true` means a plan was saved during this request; call `plan` to read it.

- A user message may carry `"attachments":["<document id>", ...]` (up to 3, from the `attach` action). The agent
  is told the document names and reads them with `read_document`.

### Tools
| Tool | Runs | Modes | Does |
|---|---|---|---|
| `get_usage(app, days?)` | server | planning, review | reads the uploaded usage |
| `get_plan(date)` | server | execute, review | reads the saved plan |
| `save_plan(wake?, sleep?, tasks[], limits[], note?)` | server | planning, review | validates and stores the plan for `date`; drops dead links |
| `create_material(title, markdown)` | server | planning, review | saves a study sheet, returns a link valid for a week |
| `fetch_url(url, offset?)` | server | planning, review | reads a public web page or PDF (12 000 characters at a time) |
| `web_search(query)` | server | planning, review | Muse's built-in `web_search` (Responses API, `/responses`): returns `{answer, sources[{title,url}], searched}`. Optional `SEARCH_MODEL` secret |
| `read_document(document_id, offset?)` | server | planning, review | reads a document the user attached |
| `create_task(title, minutes, first_step?, instructions?, links?, start_time?)` | phone | execute | add to Today |
| `set_app_limit(app, minutes_per_day)` | phone | execute | set a daily limit |
| `schedule_alarm(time, message)` | phone | execute | a reminder today at HH:MM |

## action: "plan"
`{"action":"plan","date":"2026-10-27"}` -> `{"plan":{"date":"...","status":"ready","data":{"tasks":[...],"limits":[...]}}}` or `{"plan":null}`.

## action: "profile"  (settings asked in the app, not in the chat)
`{"action":"profile","set":{"wake":"07:00","sleep":"23:30","apps":["Instagram","TikTok"],"focus":"my thesis"}}`
Only the fields sent are saved. Without `set` it just reads. Answer: `{"profile":{"wake":"07:00","sleep":"23:30","apps":[...],"focus":"..."}}`.
The agent receives these as known facts and never asks for them.

## action: "attach"  (a PDF or text file the user sends)
1. The phone uploads the file to Storage: `POST {SUPABASE_URL}/storage/v1/object/uploads/<user id>/<file name>`
   with the user's token (max 10 MB).
2. `{"action":"attach","path":"<user id>/<file name>","name":"Lecture 3.pdf"}` ->
   `{"document_id":"...","name":"...","pages":12,"chars":41000,"truncated":false}`.
   Errors: `bad_path`, `file_not_found`, `pdf_unreadable`, `no_text_in_document` (a scan), `unsupported_file`.
3. Send `document_id` in `attachments` of the next chat message.

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
`reason`: `approaching` | `limit` | `over`. `done`: titles of today's tasks already finished.
Answer: `{"text":"...at most 280 characters, plain text...","task":"Study algorithms"}` (`task` is null if nothing is left).
One short model call; the server reads today's plan and the user's settings itself. Show `text` on top of the app;
if the call fails, show a local message.

## The daily loop
1. Day: the app uploads `usage`.
2. Evening: `chat` `planning` until `plan_saved: true`.
3. During the day: when the user is on a distracting app near or over the limit, `nudge`.
4. Morning: `chat` `execute` -> run the device tool calls -> send results -> text.
5. Next evening: upload `usage`, `chat` `review` with the `report`, which adapts tomorrow's plan.
