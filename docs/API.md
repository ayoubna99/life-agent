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
  `{"type":"tool_calls","conversation_id":"...","calls":[{"id":"call_1","name":"set_app_limit","args":{"app":"Instagram","minutes_per_day":30}}],"plan_saved":false,"artifacts":[]}`
  Run each, then send them ALL back (any order, exactly those ids):
  ```json
  {"action":"chat","mode":"execute","today":"...","date":"...","conversation_id":"...",
   "input":{"type":"tool_results","results":[{"tool_call_id":"call_1","content":"{\"ok\":true}"}]}}
  ```
  `content` is a string (JSON is fine). If a tool failed, say so in it: the agent tells the user.
- `plan_saved: true` means a plan was saved during this request; call `plan` to read it.
- `artifacts` lists what the agent made during this request for the phone to show: `[{"type":"pdf"|"image"|"markdown","title":"My day card","url":"https://..."}]` (links valid for 3 days; the file stays in Storage).

- A user message may carry `"attachments":["<document id>", ...]` (up to 3, from the `attach` action). The agent
  is told the document names and reads them with `read_document`.

### Tools
| Tool | Runs | Modes | Does |
|---|---|---|---|
| `get_usage(app, days?)` | server | planning, review | reads the uploaded usage |
| `get_plan(date)` | server | execute, review | reads the saved plan |
| `save_plan(wake?, sleep?, tasks[], limits[], note?)` | server | planning, review | validates and stores the plan for `date`; drops dead links |
| `create_material(title, markdown, format?)` | server | planning, review | writes a study or work sheet as a **PDF** (default, A4, drawn from the markdown: headings, bullets, numbered lists, simple tables) or as `markdown`; stores it in `materials/<user id>/` and returns a link valid for 3 days. The PDF fonts are Latin only; other scripts show as `?` and the agent is told to use `markdown` instead. Appears in the chat answer's `artifacts` as `pdf` or `markdown` |
| `create_image(title, prompt, shape?)` | server | planning, review | makes one picture with Muse Image (`square`, `portrait` or `landscape`), stores it in `materials/<user id>/images/` and returns a link valid for 3 days. Max 1 per request. It also appears in the chat answer's `artifacts` |
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


## Automatic cleanup of stored files (function `cleanup`)
Files the agent makes (PDF sheets, pictures) and any leftover uploads are deleted **3 days** after they were last written, so the
free storage never fills up. Links to them also last 3 days. Only files in the `materials` and `uploads` buckets are touched.
The text in the database (documents, plans, messages) is kept.

- `POST /functions/v1/cleanup` with header `x-cleanup-secret: <CLEANUP_SECRET>` and an optional body `{"dry_run":true}` (lists what would go, deletes nothing).
  Answer: `{"days":3,"dry_run":false,"deleted":{"materials":4,"uploads":1},"total":5}`.
  Errors: 401 `unauthorized`, 405, 500 `not_configured` (no secret of at least 16 characters, or no service key), 502 `cleanup_failed`.
- Secrets: `CLEANUP_SECRET` (required), `CLEANUP_DAYS` (optional, default 3). The service role key is provided by Supabase itself.
- It is called once a day by Supabase Cron (pg_cron + pg_net); see "Cleanup setup" in the README.
