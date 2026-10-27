import assert from 'node:assert/strict';
import { test } from 'node:test';

import { languageBias, transcribeWav } from '../supabase/functions/_shared/asr.ts';
import { handle } from '../supabase/functions/_shared/http.ts';
import { MuseError } from '../supabase/functions/_shared/muse.ts';
import { parseWav, WavError } from '../supabase/functions/_shared/wav.ts';
import { jwt, makeWav, MemoryStore, SUPABASE_URL, USER } from './helpers.ts';

const asr = { baseUrl: 'https://api.meta.ai/v1/', apiKey: 'sk-secret-key', model: 'muse-voice-transcribe-1.0' };

// ---------- the WAV check ----------

test('good recordings pass: mono, 16-bit, 16 or 24 kHz', () => {
  assert.deepEqual(parseWav(makeWav({ seconds: 2, rate: 24000 })), { sampleRate: 24000, durationMs: 2000 });
  assert.deepEqual(parseWav(makeWav({ seconds: 1.5, rate: 16000 })), { sampleRate: 16000, durationMs: 1500 });
});

test('every format the model does not take is refused with its own reason', () => {
  const refused = (b: Uint8Array, why: string) => assert.throws(() => parseWav(b), (e: unknown) => e instanceof WavError && e.message === why, why);
  refused(makeWav({ channels: 2 }), 'not_mono');
  refused(makeWav({ bits: 8 }), 'not_16bit_pcm');
  refused(makeWav({ format: 3 }), 'not_16bit_pcm');
  refused(makeWav({ rate: 44100 }), 'bad_sample_rate');
  refused(makeWav({ rate: 8000 }), 'bad_sample_rate');
  refused(makeWav({ seconds: 601 }), 'too_long');
  refused(makeWav({ seconds: 0 }), 'empty_audio');
  refused(new TextEncoder().encode('ID3 this is an mp3 not a wav file at all, not even close to it...'), 'not_wav');
  refused(new Uint8Array(10), 'not_wav');
  refused(makeWav().subarray(0, 30), 'not_wav');
});

test('a recording whose header size is wrong (the app was killed mid-recording) is measured by what is there', () => {
  assert.equal(parseWav(makeWav({ seconds: 2, dataSize: 0 })).durationMs, 2000);
  assert.equal(parseWav(makeWav({ seconds: 2, dataSize: 99_999_999 })).durationMs, 2000);
});

// ---------- the request to Meta ----------

test('the request is exactly what Meta documents: multipart "request" JSON + "audio" WAV, key in the header', async () => {
  let seen: { url: string; init: RequestInit } | undefined;
  const fetchImpl = (async (url: string, init: RequestInit) => {
    seen = { url, init };
    return new Response(JSON.stringify({ sessionId: 's', transcript: ' Remind me to study at six. ', audioDurationMs: 2100, turns: [] }), { status: 200 });
  }) as unknown as typeof fetch;
  const r = await transcribeWav(asr, makeWav(), { languages: ['French', 'English'], keywords: ['TikTok', 'algorithms'], sessionId: 'life-abc' }, fetchImpl);
  assert.deepEqual(r, { text: 'Remind me to study at six.', durationMs: 2100 });
  assert.equal(seen!.url, 'https://api.meta.ai/v1/asr/transcribe?sessionId=life-abc');
  assert.equal((seen!.init.headers as Record<string, string>).Authorization, 'Bearer sk-secret-key');
  assert.equal('Content-Type' in (seen!.init.headers as object), false, 'the multipart boundary must be set by fetch');
  const form = seen!.init.body as FormData;
  const part = form.get('request') as Blob;
  assert.equal(part.type, 'application/json');
  assert.deepEqual(JSON.parse(await part.text()), {
    mode: 'PUSH_TO_TALK',
    model: 'muse-voice-transcribe-1.0',
    audioEncoding: 'WAV',
    languageBias: ['French', 'English'],
    keywords: ['TikTok', 'algorithms'],
  });
  const audio = form.get('audio') as File;
  assert.equal(audio.type, 'audio/wav');
  assert.equal(audio.name, 'audio.wav');
  assert.equal(audio.size, makeWav().length);
});

test('with no language or keywords the request leaves them out', async () => {
  let body: Record<string, unknown> = {};
  const fetchImpl = (async (_u: string, init: RequestInit) => {
    body = JSON.parse(await ((init.body as FormData).get('request') as Blob).text());
    return new Response('{"transcript":"hi"}', { status: 200 });
  }) as unknown as typeof fetch;
  await transcribeWav(asr, makeWav(), {}, fetchImpl);
  assert.deepEqual(Object.keys(body).sort(), ['audioEncoding', 'mode', 'model']);
});

test('Meta errors and odd answers become clean errors without leaking anything', async () => {
  for (const status of [400, 413, 429, 500]) {
    const f = (async () => new Response('{"error":"leaky sk-secret-key"}', { status })) as unknown as typeof fetch;
    await assert.rejects(transcribeWav(asr, makeWav(), {}, f), (e: unknown) => e instanceof MuseError && e.code === 'upstream_status' && e.status === status && !e.message.includes('leaky'));
  }
  for (const body of ['not json', '{}', '{"transcript":5}']) {
    await assert.rejects(transcribeWav(asr, makeWav(), {}, (async () => new Response(body, { status: 200 })) as unknown as typeof fetch), (e: unknown) => e instanceof MuseError && e.code === 'bad_output', body);
  }
  await assert.rejects(transcribeWav(asr, makeWav(), {}, (async () => { throw new TypeError('down'); }) as unknown as typeof fetch), (e: unknown) => e instanceof MuseError && e.code === 'network');
  const hang = ((_u: string, init: RequestInit) => new Promise((_r, rej) => init.signal!.addEventListener('abort', () => rej(Object.assign(new Error('x'), { name: 'AbortError' }))))) as unknown as typeof fetch;
  await assert.rejects(transcribeWav({ ...asr, timeoutMs: 20 }, makeWav(), {}, hang), (e: unknown) => e instanceof MuseError && e.code === 'timeout');
});

test('language names are matched to the model list, the rest is dropped', () => {
  assert.deepEqual(languageBias(['french', ' English ', 'Klingon', 5, 'french']), ['French', 'English']);
  assert.deepEqual(languageBias('French'), []);
  assert.deepEqual(languageBias(['Arabic', 'Mandarin Chinese', 'Spanish', 'German', 'Dutch']), ['Arabic', 'Mandarin Chinese', 'Spanish', 'German']);
});

// ---------- over HTTP ----------

const ENV: Record<string, string> = { MUSE_BASE_URL: 'https://api.meta.ai/v1', MUSE_API_KEY: 'sk-secret-key', MUSE_MODEL: 'muse-spark-1.1', SUPABASE_URL };
function http(body: unknown, store: MemoryStore, answer: (url: string, init: RequestInit) => Response, env = ENV) {
  const calls: { url: string; init: RequestInit }[] = [];
  const fetchImpl = (async (url: string, init: RequestInit) => {
    calls.push({ url, init });
    return answer(url, init);
  }) as unknown as typeof fetch;
  const req = new Request('https://x/functions/v1/agent', { method: 'POST', headers: { Authorization: `Bearer ${jwt()}`, apikey: 'k' }, body: JSON.stringify(body) });
  return { res: handle(req, { get: (n) => env[n], fetchImpl, storeFor: () => store }), calls };
}
const ok = (transcript: string) => new Response(JSON.stringify({ transcript, audioDurationMs: 3000 }), { status: 200 });
const code = async (p: Promise<Response>) => (await (await p).json()).error?.code;

test('transcribe: the recording is read from the user folder, sent with their app names as keywords, then deleted', async () => {
  const store = new MemoryStore();
  store.profile = { apps: ['TikTok', 'Instagram'] };
  store.uploads.set(`${USER}/voice.wav`, makeWav());
  const { res, calls } = http({ action: 'transcribe', path: `${USER}/voice.wav`, languages: ['english'], keywords: ['algorithms', 'tiktok'] }, store, () => ok('Study algorithms at six'));
  const r = await res;
  assert.equal(r.status, 200);
  assert.deepEqual(await r.json(), { text: 'Study algorithms at six', duration_ms: 3000 });
  assert.match(calls[0].url, /^https:\/\/api\.meta\.ai\/v1\/asr\/transcribe\?sessionId=life-/);
  const sent = JSON.parse(await ((calls[0].init.body as FormData).get('request') as Blob).text());
  assert.deepEqual(sent.keywords, ['TikTok', 'Instagram', 'algorithms'], 'app names first, no duplicates');
  assert.deepEqual(sent.languageBias, ['English']);
  assert.equal(sent.model, 'muse-voice-transcribe-1.0');
  assert.deepEqual(store.deleted, [`${USER}/voice.wav`], 'the recording is not kept');
  assert.equal(store.quota, 1);
});

test('transcribe: ASR_MODEL and ASR_BASE_URL can be set separately from the chat model', async () => {
  const store = new MemoryStore();
  store.uploads.set(`${USER}/v.wav`, makeWav());
  const { res, calls } = http({ action: 'transcribe', path: `${USER}/v.wav` }, store, () => ok('hi'), { ...ENV, ASR_MODEL: 'muse-voice-transcribe-1.1', ASR_BASE_URL: 'https://asr.example/v1' });
  await res;
  assert.match(calls[0].url, /^https:\/\/asr\.example\/v1\/asr\/transcribe/);
  assert.equal(JSON.parse(await ((calls[0].init.body as FormData).get('request') as Blob).text()).model, 'muse-voice-transcribe-1.1');
});

test('transcribe: only your own folder, only real WAVs, and silence is reported as such', async () => {
  const store = new MemoryStore();
  store.uploads.set('00000000-0000-0000-0000-00000000000b/x.wav', makeWav());
  store.uploads.set(`${USER}/stereo.wav`, makeWav({ channels: 2 }));
  store.uploads.set(`${USER}/music.mp3`, new TextEncoder().encode('ID3 not a wav file at all, not even close to a wav file really'));
  store.uploads.set(`${USER}/quiet.wav`, makeWav());
  const never = () => { throw new Error('Meta must not be called'); };
  for (const path of ['00000000-0000-0000-0000-00000000000b/x.wav', `${USER}/../x.wav`, 'voice.wav', '']) {
    assert.equal(await code(http({ action: 'transcribe', path }, store, never).res), 'bad_path', path);
  }
  assert.equal(await code(http({ action: 'transcribe', path: `${USER}/missing.wav` }, store, never).res), 'file_not_found');
  assert.equal(await code(http({ action: 'transcribe', path: `${USER}/stereo.wav` }, store, never).res), 'bad_audio_not_mono');
  assert.equal(await code(http({ action: 'transcribe', path: `${USER}/music.mp3` }, store, never).res), 'bad_audio_not_wav');
  assert.equal(await code(http({ action: 'transcribe', path: `${USER}/quiet.wav` }, store, () => ok('  ')).res), 'no_speech');
});

test('transcribe counts against the daily limit and passes a failing Meta call on as a model error', async () => {
  const store = new MemoryStore();
  store.uploads.set(`${USER}/v.wav`, makeWav());
  const limited = http({ action: 'transcribe', path: `${USER}/v.wav` }, store, () => ok('x'), { ...ENV, AGENT_DAILY_LIMIT: '0' });
  assert.equal((await limited.res).status, 200, 'a limit of 0 means "not set", so the default of 80 applies');
  store.uploads.set(`${USER}/v.wav`, makeWav());
  store.quota = 80;
  assert.equal((await http({ action: 'transcribe', path: `${USER}/v.wav` }, store, () => ok('x')).res).status, 429);
  store.quota = 0;
  const r = await http({ action: 'transcribe', path: `${USER}/v.wav` }, store, () => new Response('', { status: 429 })).res;
  assert.equal(r.status, 502);
  assert.equal((await r.json()).error.code, 'agent_upstream_status');
});

test('attach keeps the original file, next to its saved text', async () => {
  const store = new MemoryStore();
  store.uploads.set(`${USER}/notes.txt`, new TextEncoder().encode('remember the pivot'));
  const r = await http({ action: 'attach', path: `${USER}/notes.txt` }, store, () => ok('')).res;
  assert.equal(r.status, 200);
  assert.deepEqual(store.deleted, []);
  assert.ok(store.uploads.has(`${USER}/notes.txt`), 'the original stays in uploads');
  assert.equal(store.documents.size, 1);
  assert.deepEqual([...store.docFiles.values()], [`${USER}/notes.txt`]);
  assert.equal([...store.documents.values()][0].kind, 'text');
});
