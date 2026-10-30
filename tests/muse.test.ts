import assert from 'node:assert/strict';
import { test } from 'node:test';

import { callMuse, configFromEnv, MuseError, parseStep } from '../supabase/functions/_shared/muse.ts';
import { toolsFor } from '../supabase/functions/_shared/prompt.ts';
import { callsReply, cfg, fakeNet, textReply } from './helpers.ts';

const hi = [{ role: 'user' as const, content: 'hi' }];

test('the request goes to /chat/completions with the key in the header only', async () => {
  const net = fakeNet([textReply('ok')]);
  const calls: { url: string; init: RequestInit }[] = [];
  const spy = (async (url: string, init: RequestInit) => {
    calls.push({ url, init });
    return net.fetchImpl(url, init);
  }) as unknown as typeof fetch;
  await callMuse(cfg, hi, toolsFor('planning'), spy);
  assert.equal(calls[0].url, 'https://muse.example/v1/chat/completions');
  assert.equal((calls[0].init.headers as Record<string, string>).Authorization, 'Bearer sk-secret-key');
  assert.equal((calls[0].init.body as string).includes('sk-secret-key'), false);
});

test('text, tool calls and their arguments are parsed', () => {
  assert.deepEqual(parseStep(textReply('hello')), { kind: 'text', text: 'hello' });
  const step = parseStep(callsReply(['set_app_limit', { app: 'X', minutes_per_day: 30 }, 'k1']));
  assert.equal(step.kind, 'tool_calls');
  if (step.kind === 'tool_calls') {
    assert.deepEqual(step.calls, [{ id: 'k1', name: 'set_app_limit', args: { app: 'X', minutes_per_day: 30 } }]);
    assert.equal(step.assistant.tool_calls![0].id, 'k1');
  }
});

test('anything that is not a clean answer is a bad output', () => {
  const broken = callsReply(['create_task', {}]);
  (broken.choices[0].message.tool_calls![0].function as { arguments: string }).arguments = '{nope';
  const notObject = callsReply(['create_task', {}]);
  (notObject.choices[0].message.tool_calls![0].function as { arguments: string }).arguments = '[1,2]';
  for (const body of [null, {}, { choices: [] }, textReply('   '), { choices: [{ message: { content: null } }] }, broken, notObject]) {
    assert.throws(() => parseStep(body), (e: unknown) => e instanceof MuseError && e.code === 'bad_output');
  }
});

test('upstream errors keep the status and nothing else', async () => {
  for (const status of [401, 429, 500]) {
    const fetchImpl = (async () => new Response('{"error":"leaky detail with sk-secret-key"}', { status })) as unknown as typeof fetch;
    await assert.rejects(callMuse(cfg, hi, [], fetchImpl), (e: unknown) => {
      assert.ok(e instanceof MuseError);
      assert.equal(e.code, 'upstream_status');
      assert.equal(e.status, status);
      assert.equal(e.message.includes('leaky') || e.message.includes('sk-secret-key'), false);
      return true;
    });
  }
});

test('a network failure says why without the URL, and a timeout is told apart', async () => {
  const down = (async () => {
    throw new TypeError('error sending request for url (https://muse.example/v1/chat/completions): dns error: failed to lookup address');
  }) as unknown as typeof fetch;
  await assert.rejects(callMuse(cfg, hi, [], down), (e: unknown) => {
    assert.ok(e instanceof MuseError);
    assert.equal(e.code, 'network');
    assert.match(e.detail ?? '', /dns error/);
    for (const secret of ['muse.example', 'sk-secret-key', 'https://']) assert.equal(e.message.includes(secret), false, secret);
    return true;
  });
  const hang = ((_u: string, init: RequestInit) =>
    new Promise((_r, rej) => init.signal!.addEventListener('abort', () => rej(Object.assign(new Error('aborted'), { name: 'AbortError' }))))) as unknown as typeof fetch;
  await assert.rejects(callMuse({ ...cfg, timeoutMs: 20 }, hi, [], hang), (e: unknown) => e instanceof MuseError && e.code === 'timeout');
});

test('configuration comes from the environment and a missing piece is an error', () => {
  const env: Record<string, string> = { MUSE_BASE_URL: 'https://x/v1/', MUSE_API_KEY: 'k', MUSE_MODEL: 'm' };
  assert.deepEqual(configFromEnv((n) => env[n]), { baseUrl: 'https://x/v1', apiKey: 'k', model: 'm', label: 'spark' });
  for (const missing of Object.keys(env)) {
    const partial = { ...env };
    delete partial[missing];
    assert.throws(() => configFromEnv((n) => partial[n]), (e: unknown) => e instanceof MuseError && e.code === 'not_configured');
  }
});
