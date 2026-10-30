import assert from 'node:assert/strict';
import { test } from 'node:test';

import { callFirst, modelsFor, OPEN_DEFAULTS, openConfigFromEnv, parseStep, sized } from '../supabase/functions/_shared/muse.ts';
import type { MuseConfig } from '../supabase/functions/_shared/muse.ts';
import { handle } from '../supabase/functions/_shared/http.ts';
import { jwt, MemoryStore, SUPABASE_URL } from './helpers.ts';

const env = (extra: Record<string, string> = {}) => (n: string) =>
  ({ MUSE_BASE_URL: 'https://muse.example/v1', MUSE_API_KEY: 'spark-key', MUSE_MODEL: 'muse-spark-1.3', ...extra })[n];

test('Muse Spark Open on Baseten: the hackathon model by default, only with a key', () => {
  assert.equal(openConfigFromEnv(env()), null);
  const open = openConfigFromEnv(env({ OPEN_API_KEY: 'bt-key' }))!;
  assert.deepEqual(open, { baseUrl: 'https://inference.baseten.co/v1', apiKey: 'bt-key', model: 'meta-models/muse-spark-open-1026', label: 'open', extra: { reasoning_effort: 'low' } });
  assert.equal(openConfigFromEnv(env({ OPEN_API_KEY: 'k', OPEN_REASONING_EFFORT: 'off' }))!.extra, undefined);
  assert.deepEqual(openConfigFromEnv(env({ OPEN_API_KEY: 'k', OPEN_REASONING_EFFORT: 'medium' }))!.extra, { reasoning_effort: 'medium' });
});

test('routing: nudges and evening reminders on the open model, chats on Muse Spark, each with the other as fallback', () => {
  const g = env({ OPEN_API_KEY: 'bt' });
  assert.deepEqual(modelsFor('nudge', g).map((m) => m.label), ['open', 'spark']);
  assert.deepEqual(modelsFor('evening', g).map((m) => m.label), ['open', 'spark']);
  assert.deepEqual(modelsFor('chat', g).map((m) => m.label), ['spark', 'open']);
  assert.deepEqual(modelsFor('chat', env({ OPEN_API_KEY: 'bt', MODEL_ROUTE: 'chat,nudge' })).map((m) => m.label), ['open', 'spark']);
  assert.deepEqual(modelsFor('nudge', env()).map((m) => m.label), ['spark'], 'no open key: Muse Spark only');
  // only the open model configured
  assert.deepEqual(modelsFor('chat', (n) => ({ OPEN_API_KEY: 'bt' })[n]).map((m) => m.label), ['open']);
});

test('the open model always reasons: it gets room to think, and its reasoning never reaches the user', () => {
  const open = openConfigFromEnv(env({ OPEN_API_KEY: 'bt' }))!;
  const s = sized(open, { maxTokens: 220, timeoutMs: 12_000 });
  assert.equal(s.maxTokens, OPEN_DEFAULTS.minTokens);
  assert.equal(s.timeoutMs, OPEN_DEFAULTS.timeoutMs);
  const spark: MuseConfig = { baseUrl: 'x', apiKey: 'k', model: 'm', label: 'spark' };
  assert.equal(sized(spark, { maxTokens: 220 }).maxTokens, 220);
  // a nudge must land while the person is still in the app: both models together stay under the phone's 30 s wait
  const quick = sized(open, { maxTokens: 220, timeoutMs: 10_000, openTimeoutMs: 14_000 });
  assert.equal(quick.timeoutMs, 14_000);
  assert.equal(quick.maxTokens, OPEN_DEFAULTS.minTokens);
  const s2 = sized(spark, { timeoutMs: 10_000, openTimeoutMs: 14_000 });
  assert.equal(s2.timeoutMs, 10_000);
  assert.equal('openTimeoutMs' in s2, false);
  // reasoning in its own field, or in think tags: only the answer is kept
  const a = parseStep({ choices: [{ message: { role: 'assistant', reasoning_content: 'Let me think about Jake...', content: 'Jake, German is waiting.' } }] });
  assert.deepEqual(a, { kind: 'text', text: 'Jake, German is waiting.', reasoning: 'Let me think about Jake...' });
  const b = parseStep({ choices: [{ message: { role: 'assistant', content: '<think>He has 2 hours on TikTok.</think>Jake, two hours. Your thesis?' } }] });
  assert.deepEqual(b, { kind: 'text', text: 'Jake, two hours. Your thesis?', reasoning: 'He has 2 hours on TikTok.' });
});

test('failover: when the first model is down or answers only with reasoning, the other Meta model answers', async () => {
  const calls: string[] = [];
  const fetchImpl = (async (url: string, init: RequestInit) => {
    const body = JSON.parse(init.body as string);
    calls.push(body.model);
    if (url.startsWith('https://inference.baseten.co')) {
      // ran out of tokens while reasoning: no answer
      return new Response(JSON.stringify({ choices: [{ message: { role: 'assistant', content: '<think>Thinking about it' } }] }), { status: 200 });
    }
    return new Response(JSON.stringify({ choices: [{ message: { role: 'assistant', content: 'Jake, German at 21:00.' } }] }), { status: 200 });
  }) as unknown as typeof fetch;
  const models = modelsFor('nudge', env({ OPEN_API_KEY: 'bt' }));
  const out = await callFirst(models, [{ role: 'user', content: 'x' }], [], fetchImpl);
  assert.equal(out.model, 'spark');
  assert.deepEqual(calls, ['meta-models/muse-spark-open-1026', 'muse-spark-1.3']);
});

test('a nudge over HTTP is written by the open model and says so', async () => {
  const seen: { url: string; auth: string; model: string; max: number }[] = [];
  const fetchImpl = (async (url: string, init: RequestInit) => {
    const body = JSON.parse(init.body as string);
    seen.push({ url, auth: (init.headers as Record<string, string>).Authorization, model: body.model, max: body.max_tokens });
    return new Response(JSON.stringify({ choices: [{ message: { role: 'assistant', content: 'Jake, two hours of scrolling. The thesis is waiting.' } }] }), { status: 200 });
  }) as unknown as typeof fetch;
  const res = await handle(
    new Request('https://x/agent', {
      method: 'POST',
      headers: { Authorization: `Bearer ${jwt()}` },
      body: JSON.stringify({ action: 'nudge', today: '2026-10-29', now: '21:10', app: 'TikTok', used_minutes: 120, limit_minutes: 30, reason: 'over' }),
    }),
    { get: env({ OPEN_API_KEY: 'bt-key', SUPABASE_URL }), storeFor: () => new MemoryStore(), fetchImpl },
  );
  const out = await res.json();
  assert.equal(out.model, 'open');
  assert.equal(seen[0].url, 'https://inference.baseten.co/v1/chat/completions');
  assert.equal(seen[0].auth, 'Bearer bt-key');
  assert.equal(seen[0].model, 'meta-models/muse-spark-open-1026');
  assert.equal(seen[0].max, OPEN_DEFAULTS.minTokens);
});

test('the real Baseten answer format: reasoning in reasoning_content, the answer alone in content', () => {
  const real = {
    id: 'chatcmpl-a659',
    choices: [{ index: 0, message: { content: "Hi Jake, hope you're having a great day!", role: 'assistant', reasoning_content: 'We need to respond with hi to Jake in one sentence...' }, finish_reason: 'stop' }],
    model: 'meta-models/muse-spark-open-1026',
    usage: { prompt_tokens: 153, completion_tokens: 913, completion_tokens_details: { reasoning_tokens: 893 } },
  };
  assert.deepEqual(parseStep(real), { kind: 'text', text: "Hi Jake, hope you're having a great day!", reasoning: 'We need to respond with hi to Jake in one sentence...' });
});
