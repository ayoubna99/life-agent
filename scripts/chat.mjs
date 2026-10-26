// Talk to your deployed agent from the terminal, as the app would.
//
//   $env:SUPA_URL = "https://YOUR_REF.supabase.co"; $env:SUPA_KEY = "sb_publishable_..."
//   node scripts/chat.mjs                 evening planning chat, stops when the plan is saved
//   node scripts/chat.mjs --fake-usage    first uploads fake Instagram/TikTok usage so the agent has real numbers
//   node scripts/chat.mjs execute         the morning run: shows the device tool calls and answers "ok" to each
//
// Commands while chatting:  /plan  show the saved plan   /quit  leave
// Needs Node 18 or newer and curl (curl.exe comes with Windows 10/11). Nothing secret is needed here:
// the Muse Spark key stays in Supabase.

import { execFile } from 'node:child_process';
import dns from 'node:dns';
import readline from 'node:readline';

// Some networks (IPv6 that does not work, VPNs, proxies) make Node's fetch time out while curl works.
dns.setDefaultResultOrder('ipv4first');

const url = (process.env.SUPA_URL ?? '').replace(/\/+$/, '');
const key = process.env.SUPA_KEY ?? '';
if (!url || !key) {
  console.error('Set SUPA_URL and SUPA_KEY first (see the top of this file).');
  process.exit(1);
}
const args = process.argv.slice(2);
const mode = args.find((a) => ['planning', 'execute', 'review'].includes(a)) ?? 'planning';
const fakeUsage = args.includes('--fake-usage');

const iso = (d) => `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
const now = new Date();
const addDays = (n) => new Date(now.getFullYear(), now.getMonth(), now.getDate() + n);
const today = iso(addDays(0));
// Planning and review plan tomorrow; execute applies today's plan.
const planDate = mode === 'execute' ? today : iso(addDays(1));

/** The same request through curl, which follows the system's proxy and network settings. */
function curlPost(target, headers, body) {
  return new Promise((resolve, reject) => {
    const args = ['-s', '-S', '--max-time', '90', '-X', 'POST', target, '-d', '@-', '-w', '\n%{http_code}'];
    for (const [k, v] of Object.entries(headers)) args.push('-H', `${k}: ${v}`);
    const child = execFile(process.platform === 'win32' ? 'curl.exe' : 'curl', args, { maxBuffer: 10 * 1024 * 1024 }, (err, stdout, stderr) => {
      if (err && !stdout) return reject(new Error(`curl failed: ${stderr || err.message}`));
      const cut = stdout.lastIndexOf('\n');
      resolve({ status: Number(stdout.slice(cut + 1)), text: stdout.slice(0, cut) });
    });
    child.stdin.end(body);
  });
}

// curl is the default (it follows your system's network and proxy settings). USE_FETCH=1 uses Node's own fetch.
let useCurl = process.env.USE_FETCH !== '1';

async function post(path, body, token) {
  const headers = { apikey: key, 'Content-Type': 'application/json' };
  if (token) headers.Authorization = `Bearer ${token}`;
  const payload = JSON.stringify(body);
  let status, text;
  if (!useCurl) {
    try {
      const res = await fetch(`${url}${path}`, { method: 'POST', headers, body: payload });
      status = res.status;
      text = await res.text();
    } catch (e) {
      console.log(`(Node's fetch could not connect: ${e.cause?.code ?? e.message}. Using curl.)`);
      useCurl = true;
    }
  }
  if (useCurl) ({ status, text } = await curlPost(`${url}${path}`, headers, payload));
  let json;
  try {
    json = JSON.parse(text);
  } catch {
    json = { raw: text };
  }
  return { status, json };
}

const signup = await post('/auth/v1/signup', {});
const token = signup.json.access_token;
if (!token) {
  if (signup.json.raw !== undefined) {
    console.error(`No usable answer from ${url} (HTTP ${signup.status}): ${JSON.stringify(signup.json.raw).slice(0, 200)}`);
    console.error('Check SUPA_URL (https://YOUR_REF.supabase.co) and your internet connection.');
  } else {
    console.error('Could not sign in anonymously:', JSON.stringify(signup.json));
    console.error('Is "Allow anonymous sign-ins" on in Authentication > Sign In / Providers? Is SUPA_KEY the full publishable key?');
  }
  process.exit(1);
}
console.log(`Signed in anonymously. Mode: ${mode}. Plan day: ${planDate}.`);

const agent = (body) => post('/functions/v1/agent', { ...body, mode, today, date: planDate, locale: 'en' }, token);

if (fakeUsage) {
  const rows = [];
  for (let i = 0; i < 5; i++) {
    const day = iso(addDays(-i));
    rows.push({ day, app: 'Instagram', minutes: 70 + 5 * i }, { day, app: 'TikTok', minutes: 40 + 3 * i });
  }
  const r = await agent({ action: 'usage', days: rows }); // mode/date are ignored for usage
  console.log(r.status === 200 ? 'Uploaded fake usage for Instagram and TikTok (about 70 and 40 minutes a day).' : `Usage upload failed: ${JSON.stringify(r.json)}`);
}

let conversation;

function fail(r) {
  const code = r.json?.error?.code ?? JSON.stringify(r.json);
  console.log(`\n[problem ${r.status}: ${code}]`);
  const hints = {
    daily_limit_reached: 'You used today\'s allowance (see AGENT_DAILY_LIMIT).',
    agent_not_configured: 'The Muse Spark secrets are missing in Supabase.',
    agent_upstream_status: 'Muse Spark refused the request: check the key, model and base URL secrets.',
    agent_bad_output: 'Muse Spark answered in a format the backend could not read.',
    agent_network: 'The function could not reach Muse Spark: check MUSE_BASE_URL. The reason is in the function logs.',
    store_error: 'The database refused a call: was the second migration applied (npx supabase db push)?',
  };
  if (hints[code]) console.log(hints[code]);
}

async function showPlan() {
  const r = await agent({ action: 'plan', date: planDate });
  if (r.status !== 200) return fail(r);
  if (!r.json.plan) return console.log('No plan is saved for that day yet.');
  const { tasks, limits, wake, sleep, note } = r.json.plan.data;
  console.log(`\n=== Saved plan for ${planDate} ===`);
  if (wake || sleep) console.log(`Wake ${wake ?? '?'}, sleep ${sleep ?? '?'}`);
  for (const t of tasks) {
    console.log(`- ${t.start_time ?? '--:--'}  ${t.title} (${t.minutes} min)`);
    if (t.first_step) console.log(`    first step: ${t.first_step}`);
    for (const line of t.instructions ?? []) console.log(`    * ${line}`);
    for (const link of t.links ?? []) console.log(`    link: ${link}`);
  }
  for (const l of limits) console.log(`- limit: ${l.app} ${l.minutes_per_day} min a day`);
  if (note) console.log(`Note: ${note}`);
}

/** Sends one input, follows device tool calls until the agent answers in text, prints it. Returns true once a plan was saved. */
async function turn(input) {
  let saved = false;
  let next = input;
  for (let guard = 0; guard < 6; guard++) {
    const r = await agent({ action: 'chat', conversation_id: conversation, input: next });
    if (r.status !== 200) {
      fail(r);
      return saved;
    }
    conversation = r.json.conversation_id;
    saved ||= r.json.plan_saved;
    if (r.json.type === 'text') {
      console.log(`\nagent> ${r.json.text}`);
      return saved;
    }
    const results = r.json.calls.map((c) => {
      console.log(`\n[device would run] ${c.name} ${JSON.stringify(c.args)}`);
      return { tool_call_id: c.id, content: JSON.stringify({ ok: true }) };
    });
    next = { type: 'tool_results', results };
  }
  console.log('[stopped: too many tool rounds]');
  return saved;
}

const rl = readline.createInterface({ input: process.stdin, output: process.stdout, terminal: process.stdin.isTTY });
const lines = rl[Symbol.asyncIterator]();
const ask = async (q) => {
  process.stdout.write(q);
  const { value, done } = await lines.next();
  return done ? null : value;
};

if (mode === 'execute') {
  if (await turn({ type: 'user', text: "Apply today's plan." })) await showPlan();
  process.exit(0);
}

console.log(mode === 'review' ? 'Type what happened today; /quit to leave.' : 'Type as the user. The chat ends when the agent saves your plan. /plan shows it, /quit leaves.');
for (;;) {
  const line = await ask('\nyou> ');
  if (line === null || line.trim() === '/quit') break;
  if (line.trim() === '') continue;
  if (line.trim() === '/plan') {
    await showPlan();
    continue;
  }
  if (await turn({ type: 'user', text: line })) {
    console.log('\n*** The agent saved the plan. ***');
    await showPlan();
    break;
  }
}
rl.close();
process.exit(0);
