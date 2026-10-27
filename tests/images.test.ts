import assert from 'node:assert/strict';
import { test } from 'node:test';

import { describeImage, describePdf, generateImage, ImageError, sniffImage, toBase64 } from '../supabase/functions/_shared/images.ts';
import { handle } from '../supabase/functions/_shared/http.ts';
import { runChat } from '../supabase/functions/_shared/loop.ts';
import { runServerTool } from '../supabase/functions/_shared/tools.ts';
import type { ToolEnv } from '../supabase/functions/_shared/tools.ts';
import { callsReply, cfg, fakeNet, jwt, MemoryStore, realPdfLoader, SUPABASE_URL, textReply, USER } from './helpers.ts';

const pad = (head: number[], n = 40) => Uint8Array.from([...head, ...new Array(n).fill(7)]);
const PNG = pad([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
const JPEG = pad([0xff, 0xd8, 0xff, 0xe0]);
const WEBP = pad([0x52, 0x49, 0x46, 0x46, 1, 2, 3, 4, 0x57, 0x45, 0x42, 0x50]);
const b64 = (b: Uint8Array) => toBase64(b);
const jsonRes = (b: unknown, status = 200) => new Response(JSON.stringify(b), { status, headers: { 'content-type': 'application/json' } });
const visionReply = (text: string) => ({ output: [{ type: 'reasoning', summary: [] }, { type: 'message', content: [{ type: 'output_text', text, annotations: [] }] }] });
const imageReply = (bytes: Uint8Array = WEBP) => ({ created: 1, data: [{ b64_json: b64(bytes) }], output_format: 'webp' });

// ---------- what the bytes are ----------

test('photos are recognised by their bytes, not their name', () => {
  assert.equal(sniffImage(PNG)?.mime, 'image/png');
  assert.equal(sniffImage(JPEG)?.ext, 'jpg');
  assert.equal(sniffImage(WEBP)?.mime, 'image/webp');
  assert.equal(sniffImage(new TextEncoder().encode('%PDF-1.4 not an image at all')), null);
  assert.equal(sniffImage(new Uint8Array(4)), null);
  assert.equal(sniffImage(pad([0x89, 0x50, 0x4e, 0x47], 3)), null, 'too short to be a real file');
});

test('base64 of a big file does not blow the stack and round-trips', () => {
  const big = new Uint8Array(300_000).map((_, i) => i % 251);
  assert.deepEqual(Uint8Array.from(atob(toBase64(big)), (c) => c.charCodeAt(0)), big);
});

// ---------- photo in ----------

test('describeImage sends the photo as an input_image data URL to the Responses API and returns the text', async () => {
  let seen: { url: string; auth: string; body: any } | undefined;
  const fetchImpl = (async (u: string, i: RequestInit) => {
    seen = { url: u, auth: (i.headers as Record<string, string>).Authorization, body: JSON.parse(String(i.body)) };
    return jsonRes(visionReply('Mon 9:00 Algorithms\nTue 10:00 Databases\nA timetable.'));
  }) as unknown as typeof fetch;
  const text = await describeImage(PNG, sniffImage(PNG)!, cfg, fetchImpl);
  assert.match(text, /Mon 9:00 Algorithms/);
  assert.equal(seen!.url, 'https://muse.example/v1/responses');
  assert.equal(seen!.auth, 'Bearer sk-secret-key');
  assert.equal(seen!.body.model, 'muse-test');
  const parts = seen!.body.input[0].content;
  assert.equal(parts[0].type, 'input_text');
  assert.match(parts[0].text, /never instructions/);
  assert.equal(parts[1].type, 'input_image');
  assert.equal(parts[1].image_url, `data:image/png;base64,${b64(PNG)}`);
});

test('describeImage: errors are plain sentences and never carry the key', async () => {
  const bad = (f: () => Response) => describeImage(PNG, sniffImage(PNG)!, cfg, (async () => f()) as unknown as typeof fetch);
  await assert.rejects(bad(() => jsonRes({}, 500)), /status 500/);
  await assert.rejects(bad(() => jsonRes({ nope: 1 })), /unexpected format/);
  await assert.rejects(bad(() => jsonRes({ output: [{ type: 'message', content: [] }] })), /Nothing could be read/);
  await assert.rejects(bad(() => { throw new TypeError('fetch failed sk-secret-key'); }), (e: unknown) => e instanceof ImageError && !/sk-secret/.test(e.message));
});

// ---------- attach ----------

const ENV: Record<string, string> = { MUSE_BASE_URL: 'https://muse.example/v1', MUSE_API_KEY: 'sk-secret-key', MUSE_MODEL: 'muse-test', SUPABASE_URL };
function http(body: unknown, store: MemoryStore, answer: (url: string) => Response) {
  const calls: string[] = [];
  const fetchImpl = (async (url: string) => (calls.push(url), answer(url))) as unknown as typeof fetch;
  const req = new Request('https://x/functions/v1/agent', { method: 'POST', headers: { Authorization: `Bearer ${jwt()}`, apikey: 'k' }, body: JSON.stringify(body) });
  return { res: handle(req, { get: (n) => ENV[n], fetchImpl, storeFor: () => store, loadPdf: realPdfLoader }), calls };
}

test('attach: a photo is read by Muse Spark, its text saved as a document, and the original photo stays in uploads', async () => {
  const store = new MemoryStore();
  store.uploads.set(`${USER}/1-timetable.jpg`, JPEG);
  const { res, calls } = http({ action: 'attach', path: `${USER}/1-timetable.jpg`, name: 'Timetable' }, store, () => jsonRes(visionReply('Mon 9:00 Algorithms')));
  const r = await res;
  assert.equal(r.status, 200);
  const out = await r.json();
  assert.deepEqual({ name: out.name, kind: out.kind, file_path: out.file_path }, { name: 'Timetable', kind: 'image', file_path: `${USER}/1-timetable.jpg` });
  assert.equal(calls.length, 1);
  const doc = store.documents.get(out.document_id)!;
  assert.deepEqual({ kind: doc.kind, text: doc.text }, { kind: 'image', text: 'Mon 9:00 Algorithms' });
  assert.equal(store.docFiles.get(out.document_id), `${USER}/1-timetable.jpg`);
  assert.ok(store.uploads.has(`${USER}/1-timetable.jpg`), 'the photo is kept');
  assert.deepEqual(store.deleted, []);
  assert.equal(store.quota, 1, 'reading a photo is a model call, so it is counted');
  assert.equal(store.globalQuota, 1);
});

test('attach: PDFs are kept too, and labelled pdf', async () => {
  const { makePdf } = await import('./helpers.ts');
  const store = new MemoryStore();
  store.uploads.set(`${USER}/l.pdf`, makePdf(['Quick sort']));
  const out = await (await http({ action: 'attach', path: `${USER}/l.pdf` }, store, () => jsonRes({})).res).json();
  assert.equal(out.kind, 'pdf');
  assert.ok(store.uploads.has(`${USER}/l.pdf`));
  assert.equal(store.quota, 0, 'a PDF is read locally: no model call, no quota');
});

test('attach: a huge photo, an unreadable photo and the other user\'s photo are refused with a reason', async () => {
  const store = new MemoryStore();
  store.uploads.set(`${USER}/big.png`, pad([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a], 6 * 1024 * 1024));
  store.uploads.set(`${USER}/p.png`, PNG);
  const code = async (p: Promise<Response>) => ((await (await p).json()) as { error?: { code: string } }).error?.code;
  const big = http({ action: 'attach', path: `${USER}/big.png` }, store, () => jsonRes(visionReply('x')));
  assert.equal(await code(big.res), 'image_too_large');
  assert.equal(big.calls.length, 0, 'no model call for a file that is too big');
  assert.equal(await code(http({ action: 'attach', path: `${USER}/p.png` }, store, () => jsonRes({}, 500)).res), 'image_unreadable');
  assert.equal(await code(http({ action: 'attach', path: `00000000-0000-0000-0000-00000000000b/p.png` }, store, () => jsonRes({})).res), 'bad_path');
  assert.equal(store.documents.size, 0);
});

test('chat: an attached photo is labelled as a photo that may be misread, and read_document opens its text', async () => {
  const store = new MemoryStore();
  const id = await store.saveDocument({ name: 'Timetable', text: 'Mon 9:00 Algorithms', pages: 1, kind: 'image', filePath: `${USER}/t.png` });
  const net = fakeNet([textReply('ok')]);
  await runChat(
    { mode: 'planning', today: '2026-10-26', date: '2026-10-27', input: { type: 'user', text: 'Plan around this', attachments: [id] } },
    { cfg, store, userId: USER, supabaseUrl: SUPABASE_URL, dailyLimit: 80, globalLimit: 1000, fetchImpl: net.fetchImpl },
  );
  const sent = net.museRequests[0].messages.find((m) => m.role === 'user')!.content!;
  assert.match(sent, /\[Attached photo: "Timetable", read by a vision model so the text may contain mistakes, document_id=/);
  assert.doesNotMatch(sent, /Mon 9:00/, 'the text is opened with read_document, not pasted into the chat');
});

// ---------- photo out ----------

test('generateImage sends the documented request and returns real image bytes', async () => {
  let seen: { url: string; auth: string; body: any } | undefined;
  const fetchImpl = (async (u: string, i: RequestInit) => {
    seen = { url: u, auth: (i.headers as Record<string, string>).Authorization, body: JSON.parse(String(i.body)) };
    return jsonRes(imageReply());
  }) as unknown as typeof fetch;
  const made = await generateImage('a calm desk at sunrise', cfg, { shape: 'portrait', user: USER }, fetchImpl);
  assert.equal(seen!.url, 'https://muse.example/v1/images/generations');
  assert.equal(seen!.auth, 'Bearer sk-secret-key');
  assert.deepEqual(seen!.body, { model: 'muse-image-1.0', prompt: 'a calm desk at sunrise', n: 1, size: '1024x1536', response_format: 'b64_json', output_format: 'webp', reasoning_strength: 'low', user: USER });
  assert.equal(made.type.mime, 'image/webp');
  assert.deepEqual(made.bytes, WEBP);
  const other = await generateImage('x', cfg, { model: 'muse-image-2' }, (async (_u: string, i: RequestInit) => ((seen!.body = JSON.parse(String(i.body))), jsonRes(imageReply(PNG)))) as unknown as typeof fetch);
  assert.equal(seen!.body.model, 'muse-image-2');
  assert.equal(seen!.body.size, '1024x1024');
  assert.equal(other.type.ext, 'png');
});

test('generateImage: safety block, busy, wrong status, no picture and a "picture" that is not an image all say what happened', async () => {
  const run = (f: () => Response) => generateImage('x', cfg, {}, (async () => f()) as unknown as typeof fetch);
  await assert.rejects(run(() => jsonRes({ error: { code: 'content_policy_violation' } }, 400)), /safety filter/);
  await assert.rejects(run(() => jsonRes({}, 429)), /busy/);
  await assert.rejects(run(() => jsonRes({}, 503)), /status 503/);
  await assert.rejects(run(() => jsonRes({ data: [] })), /no picture/);
  await assert.rejects(run(() => jsonRes({ data: [{ b64_json: '!!!not base64!!!' }] })), /broken picture/);
  await assert.rejects(run(() => jsonRes(imageReply(new TextEncoder().encode('<html>not an image</html>')))), /broken picture/);
  await assert.rejects(run(() => { throw new TypeError('down'); }), /could not be reached/);
});

function toolEnv(over: Partial<ToolEnv> = {}): ToolEnv & { store: MemoryStore } {
  return { store: new MemoryStore(), mode: 'review', today: '2026-10-27', planDate: '2026-10-27', supabaseUrl: SUPABASE_URL, fetchImpl: (async () => jsonRes(imageReply())) as unknown as typeof fetch, randomId: () => 'abcdef12', muse: cfg, ...over } as ToolEnv & { store: MemoryStore };
}

test('create_image: the picture is stored in the user folder of the private bucket and the link is returned as an artifact', async () => {
  const env = toolEnv({ images: { left: 2 }, userId: USER });
  const out = await runServerTool('create_image', { title: 'My day card', prompt: 'a sunrise over a tidy desk', shape: 'portrait' }, env);
  const content = JSON.parse(out.content);
  assert.equal(content.title, 'My day card');
  assert.match(content.url, new RegExp(`/object/sign/materials/${USER}/images/2026-10-27-my-day-card-abcdef12\\.webp`));
  assert.deepEqual(out.artifact, { type: 'image', title: 'My day card', url: content.url });
  const saved = env.store.files.get('images/2026-10-27-my-day-card-abcdef12.webp')!;
  assert.equal(saved.contentType, 'image/webp');
  assert.deepEqual(saved.bytes, WEBP);
  assert.equal(env.images!.left, 1);
});

test('create_image: bad input, no setup, no budget and a refused picture come back as plain messages', async () => {
  const run = async (args: Record<string, unknown>, env = toolEnv()) => JSON.parse((await runServerTool('create_image', args, env)).content);
  assert.match((await run({ prompt: 'x' })).error, /title is required/);
  assert.match((await run({ title: 't' })).error, /prompt is required/);
  assert.match((await run({ title: 't', prompt: 'x'.repeat(1001) })).error, /at most 1000/);
  assert.match((await run({ title: 't', prompt: 'p', shape: 'huge' })).error, /shape must be/);
  assert.match((await run({ title: 't', prompt: 'p' }, toolEnv({ muse: undefined }))).error, /not set up/);
  assert.match((await run({ title: 't', prompt: 'p' }, toolEnv({ images: { left: 0 } }))).error, /No more pictures/);
  const blocked = toolEnv({ fetchImpl: (async () => jsonRes({ error: { code: 'content_policy_violation' } }, 400)) as unknown as typeof fetch });
  assert.match((await run({ title: 't', prompt: 'p' }, blocked)).error, /safety filter/);
  assert.equal(blocked.store.files.size, 0);
});

test('chat: the picture reaches the phone as an artifact, at most two per request, and none by default', async () => {
  const store = new MemoryStore();
  const net = fakeNet([
    callsReply(['create_image', { title: 'One', prompt: 'a' }, 'c1'], ['create_image', { title: 'Two', prompt: 'b' }, 'c2'], ['create_image', { title: 'Three', prompt: 'c' }, 'c3']),
    textReply('Here is your card.'),
  ]);
  const fetchImpl = (async (u: string, i?: RequestInit) => (u.endsWith('/images/generations') ? jsonRes(imageReply()) : net.fetchImpl(u, i as RequestInit))) as unknown as typeof fetch;
  let n = 0;
  const r = await runChat(
    { mode: 'review', today: '2026-10-27', date: '2026-10-27', input: { type: 'user', text: 'make me a card of my day' } },
    { cfg, store, userId: USER, supabaseUrl: SUPABASE_URL, dailyLimit: 80, globalLimit: 1000, fetchImpl, randomId: () => `id${++n}abcdefgh` },
  );
  assert.equal(r.type, 'text');
  assert.deepEqual(r.artifacts.map((a) => a.title), ['One', 'Two']);
  assert.equal(store.files.size, 2);
  const toolAnswers = net.museRequests[1].messages.filter((m) => m.role === 'tool').map((m) => JSON.parse(m.content!));
  assert.match(toolAnswers[2].error, /No more pictures/);

  const plain = fakeNet([textReply('hi')]);
  const p = await runChat({ mode: 'planning', today: '2026-10-26', date: '2026-10-27', input: { type: 'user', text: 'hi' } }, { cfg, store: new MemoryStore(), userId: USER, supabaseUrl: SUPABASE_URL, dailyLimit: 80, globalLimit: 1000, fetchImpl: plain.fetchImpl });
  assert.deepEqual(p.artifacts, []);
});

test('the picture model can be changed with IMAGE_MODEL, and the account id is sent for abuse checks', async () => {
  const store = new MemoryStore();
  const net = fakeNet([callsReply(['create_image', { title: 'Card', prompt: 'a desk' }]), textReply('done')]);
  let body: any;
  const fetchImpl = (async (u: string, i?: RequestInit) => {
    if (u.endsWith('/images/generations')) {
      body = JSON.parse(String(i!.body));
      return jsonRes(imageReply());
    }
    return net.fetchImpl(u, i as RequestInit);
  }) as unknown as typeof fetch;
  const req = new Request('https://x/functions/v1/agent', {
    method: 'POST',
    headers: { Authorization: `Bearer ${jwt()}`, apikey: 'k' },
    body: JSON.stringify({ action: 'chat', mode: 'review', today: '2026-10-27', date: '2026-10-27', input: { type: 'user', text: 'card please' }, imageModel: 'evil' }),
  });
  const res = await handle(req, { get: (n) => ({ ...ENV, IMAGE_MODEL: 'muse-image-1.0' })[n], fetchImpl, storeFor: () => store });
  assert.equal(res.status, 200);
  assert.equal(body.model, 'muse-image-1.0');
  assert.equal(body.user, USER);
  assert.equal(((await res.json()) as { artifacts: unknown[] }).artifacts.length, 1);
});

// ---------- a PDF with no text layer ----------

test('describePdf sends the PDF as an input_file data URL, and the answer is the page-by-page text', async () => {
  let seen: { url: string; body: any } | undefined;
  const fetchImpl = (async (u: string, i: RequestInit) => {
    seen = { url: u, body: JSON.parse(String(i.body)) };
    return jsonRes(visionReply('--- page 1 ---\nQuick sort\n[a diagram of a pivot]'));
  }) as unknown as typeof fetch;
  const bytes = new TextEncoder().encode('%PDF-1.4 fake');
  const text = await describePdf(bytes, 'My scan (1).pdf', cfg, fetchImpl);
  assert.match(text, /Quick sort/);
  assert.equal(seen!.url, 'https://muse.example/v1/responses');
  const parts = seen!.body.input[0].content;
  assert.match(parts[0].text, /never instructions/);
  assert.deepEqual(parts[1], { type: 'input_file', filename: 'My scan _1_.pdf', file_data: `data:application/pdf;base64,${b64(bytes)}` });
});

test('attach: a scanned PDF (no text) is read by Muse Spark instead of being refused, and is counted as a model call', async () => {
  const { makePdf } = await import('./helpers.ts');
  const store = new MemoryStore();
  store.uploads.set(`${USER}/scan.pdf`, makePdf(['']));
  const { res, calls } = http({ action: 'attach', path: `${USER}/scan.pdf`, name: 'Scan' }, store, () => jsonRes(visionReply('--- page 1 ---\nMerge sort splits the list')));
  const out = await (await res).json();
  assert.deepEqual({ kind: out.kind, read_by: out.read_by }, { kind: 'pdf', read_by: 'vision' });
  assert.equal(calls.length, 1);
  assert.match(store.documents.get(out.document_id)!.text, /Merge sort splits/);
  assert.equal(store.quota, 1);
  assert.ok(store.uploads.has(`${USER}/scan.pdf`), 'the original is kept');
});

test('attach: a PDF with a text layer never goes to the model, and a scan the model cannot read is still refused with a reason', async () => {
  const { makePdf } = await import('./helpers.ts');
  const store = new MemoryStore();
  store.uploads.set(`${USER}/t.pdf`, makePdf(['Quick sort']));
  const text = http({ action: 'attach', path: `${USER}/t.pdf` }, store, () => jsonRes({}));
  assert.equal((await (await text.res).json()).read_by, 'text');
  assert.equal(text.calls.length, 0);
  assert.equal(store.quota, 0);

  store.uploads.set(`${USER}/s.pdf`, makePdf(['']));
  const failing = http({ action: 'attach', path: `${USER}/s.pdf` }, store, () => jsonRes({}, 500));
  const r = await failing.res;
  assert.equal(r.status, 422);
  assert.equal(((await r.json()) as { error: { code: string } }).error.code, 'no_text_in_document');

  store.uploads.set(`${USER}/b.pdf`, new TextEncoder().encode('%PDF-1.4 this is not a pdf'));
  const broken = http({ action: 'attach', path: `${USER}/b.pdf` }, store, () => jsonRes({}));
  assert.equal(((await (await broken.res).json()) as { error: { code: string } }).error.code, 'pdf_unreadable');
  assert.equal(broken.calls.length, 0, 'a broken file is not sent to the model');
});
