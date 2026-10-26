# Runs the whole backend flow against YOUR Supabase project, with curl.exe. Windows PowerShell.
#   $env:SUPA_URL = "https://YOUR_REF.supabase.co"; $env:SUPA_KEY = "sb_publishable_..."
#   .\scripts\smoke.ps1
# The Muse Spark key stays in Supabase secrets; nothing secret is needed here.
$ErrorActionPreference = "Stop"
$url = $env:SUPA_URL; $key = $env:SUPA_KEY
if (-not $url -or -not $key) { throw "Set `$env:SUPA_URL and `$env:SUPA_KEY first." }
$tmp = Join-Path $env:TEMP "life-smoke.json"
$today = (Get-Date).ToString("yyyy-MM-dd"); $tomorrow = (Get-Date).AddDays(1).ToString("yyyy-MM-dd")

function Post($path, $headers, $body) {
  [System.IO.File]::WriteAllText($tmp, ($body | ConvertTo-Json -Depth 10 -Compress), (New-Object System.Text.UTF8Encoding $false))
  $args = @("-s", "-X", "POST", "$url$path", "-H", "apikey: $key", "-H", "Content-Type: application/json", "-d", "@$tmp")
  foreach ($h in $headers) { $args += @("-H", $h) }
  $out = & curl.exe @args
  try { return $out | ConvertFrom-Json } catch { throw "Not JSON: $out" }
}
function Agent($body) { Post "/functions/v1/agent" @("Authorization: Bearer $script:token") $body }
function Step($n, $t) { Write-Host ""; Write-Host "== $n. $t" -ForegroundColor Cyan }

Step 1 "anonymous sign-in"
$u = Post "/auth/v1/signup" @() @{}
$script:token = $u.access_token
if (-not $token) { throw "No token. Is anonymous sign-in on? $($u | ConvertTo-Json -Compress)" }
Write-Host "ok, token starts with $($token.Substring(0,12))"

Step 2 "upload fake usage for the last 3 days"
$rows = @(); foreach ($i in 0..2) { $d = (Get-Date).AddDays(-$i).ToString("yyyy-MM-dd"); $rows += @{ day = $d; app = "Instagram"; minutes = 70 + 5 * $i } }
(Agent @{ action = "usage"; days = $rows }) | ConvertTo-Json -Compress

Step 3 "planning: one message with everything, asking it to save"
$msg = "Tomorrow I must study algorithms for 40 minutes at 18:00 and go to the gym for 45 minutes. I wake at 07:00 and sleep at 23:30. Instagram pulls me off track, please set a limit from my real usage. This is everything and it is confirmed: please save the plan now."
$r = Agent @{ action = "chat"; mode = "planning"; today = $today; date = $tomorrow; locale = "en"; input = @{ type = "user"; text = $msg } }
$r | ConvertTo-Json -Depth 8
$conv = $r.conversation_id
$guard = 0
while ($r.type -eq "text" -and -not $r.plan_saved -and $guard -lt 3) {
  $guard++
  Write-Host "(the agent asked something; confirming)" -ForegroundColor DarkYellow
  $r = Agent @{ action = "chat"; mode = "planning"; today = $today; date = $tomorrow; conversation_id = $conv; input = @{ type = "user"; text = "Yes, that is everything. Confirmed, please save the plan." } }
  $r | ConvertTo-Json -Depth 8
}
Write-Host "plan_saved = $($r.plan_saved)"

Step 4 "read the saved plan"
$p = Agent @{ action = "plan"; date = $tomorrow }
$p | ConvertTo-Json -Depth 10

Step 5 "execute: pretend it is tomorrow morning and let the agent apply the plan (device tools)"
$e = Agent @{ action = "chat"; mode = "execute"; today = $tomorrow; date = $tomorrow; locale = "en"; input = @{ type = "user"; text = "Apply today's plan." } }
$e | ConvertTo-Json -Depth 8
if ($e.type -eq "tool_calls") {
  $results = @(); foreach ($c in $e.calls) { Write-Host "device would run: $($c.name) $($c.args | ConvertTo-Json -Compress)"; $results += @{ tool_call_id = $c.id; content = '{"ok":true}' } }
  $e2 = Agent @{ action = "chat"; mode = "execute"; today = $tomorrow; date = $tomorrow; conversation_id = $e.conversation_id; input = @{ type = "tool_results"; results = $results } }
  $e2 | ConvertTo-Json -Depth 8
}
Write-Host ""; Write-Host "Done. Check the tables in the Supabase dashboard: plans, messages, usage_days." -ForegroundColor Green
