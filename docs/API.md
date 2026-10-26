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
429 `daily_limit_reached` · 500 `agent_not_configured` · 502 `agent_*` (the model) or `store_error` · 504 `agent_timeout`.

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

### Tools
| Tool | Runs | Modes | Does |
|---|---|---|---|
| `get_usage(app, days?)` | server | planning, review | reads the uploaded usage |
| `get_plan(date)` | server | execute, review | reads the saved plan |
| `save_plan(wake?, sleep?, tasks[], limits[], note?)` | server | planning, review | validates and stores the plan for `date`; drops dead links |
| `create_material(title, markdown)` | server | planning, review | saves a study sheet, returns a link valid for a week |
| `create_task(title, minutes, first_step?, instructions?, links?, start_time?)` | phone | execute | add to Today |
| `set_app_limit(app, minutes_per_day)` | phone | execute | set a daily limit |
| `schedule_alarm(time, message)` | phone | execute | a reminder today at HH:MM |

## action: "plan"
`{"action":"plan","date":"2026-10-27"}` -> `{"plan":{"date":"...","status":"ready","data":{"tasks":[...],"limits":[...]}}}` or `{"plan":null}`.

## The daily loop
1. Day: the app uploads `usage`.
2. Evening: `chat` `planning` until `plan_saved: true`.
3. Morning: `chat` `execute` -> run the device tool calls -> send results -> text.
4. Next evening: upload `usage`, `chat` `review` with the `report`, which adapts tomorrow's plan.
