import assert from 'node:assert/strict';
import { test } from 'node:test';

import { extractPdfText, isPdf } from '../supabase/functions/_shared/pdf.ts';
import { fetchPage, htmlToText, WEB, WebError } from '../supabase/functions/_shared/web.ts';
import { makePdf, realPdfLoader } from './helpers.ts';

const respond = (body: BodyInit | null, init: ResponseInit = {}) => new Response(body, { status: 200, ...init });
const html = (body: string) => respond(body, { headers: { 'content-type': 'text/html; charset=utf-8' } });

test('a real PDF is read, page by page', async () => {
  const pdf = makePdf(['Sorting algorithms: bubble sort, merge sort', 'Big-O notation (n log n)']);
  assert.ok(isPdf(pdf));
  const r = await extractPdfText(pdf, realPdfLoader);
  assert.equal(r.pages, 2);
  assert.match(r.text, /Sorting algorithms: bubble sort, merge sort/);
  assert.match(r.text, /Big-O notation \(n log n\)/);
});

test('a PDF with no text (a scan) comes back empty so the caller can say so', async () => {
  const r = await extractPdfText(makePdf(['']), realPdfLoader);
  assert.equal(r.text, '');
  assert.equal(isPdf(new TextEncoder().encode('hello')), false);
});

test('HTML becomes readable text: scripts, menus and tags go, entities and lists stay readable', () => {
  const r = htmlToText(`<html><head><title>Merge &amp; Quick sort</title><style>p{color:red}</style></head>
    <body><nav>Home | About</nav><script>alert("x")</script>
    <h1>Sorting</h1><p>Merge sort is O(n&nbsp;log&nbsp;n) &mdash; stable.</p>
    <ul><li>Divide</li><li>Merge &#38; return</li></ul><footer>copyright</footer></body></html>`);
  assert.equal(r.title, 'Merge & Quick sort');
  assert.match(r.text, /Sorting/);
  assert.match(r.text, /Merge sort is O\(n log n\) - stable\./);
  assert.match(r.text, /- Divide\n- Merge & return/);
  for (const gone of ['alert', 'color:red', 'Home | About', 'copyright', '<']) assert.equal(r.text.includes(gone), false, gone);
});

test('fetchPage reads html, plain text and PDFs', async () => {
  const pdf = makePdf(['Chapter one text']);
  const net = (async (url: string) => {
    if (url.endsWith('/page')) return html('<title>T</title><p>Hello algorithms</p>');
    if (url.endsWith('/notes.txt')) return respond('plain notes', { headers: { 'content-type': 'text/plain' } });
    if (url.endsWith('/paper.pdf')) return respond(pdf, { headers: { 'content-type': 'application/pdf' } });
    return respond('', { status: 404 });
  }) as unknown as typeof fetch;
  assert.deepEqual(await fetchPage('https://site.example/page', net), { url: 'https://site.example/page', title: 'T', text: 'Hello algorithms', truncated: false });
  assert.equal((await fetchPage('https://site.example/notes.txt', net)).text, 'plain notes');
  assert.match((await fetchPage('https://site.example/paper.pdf', net, realPdfLoader)).text, /Chapter one text/);
});

test('fetchPage never touches an unsafe address, even through a redirect', async () => {
  const seen: string[] = [];
  const net = (async (url: string) => {
    seen.push(url);
    if (url === 'https://start.example/a') return respond(null, { status: 302, headers: { location: 'https://good.example/b' } });
    if (url === 'https://good.example/b') return respond(null, { status: 302, headers: { location: 'https://169.254.169.254/latest/meta-data' } });
    if (url === 'https://redirect-loop.example/a') return respond(null, { status: 302, headers: { location: '/a' } });
    return html('<p>ok</p>');
  }) as unknown as typeof fetch;
  for (const bad of ['http://site.example/a', 'https://127.0.0.1/a', 'https://localhost/a', 'ftp://x.example/a', 'nonsense']) {
    await assert.rejects(fetchPage(bad, net), WebError, bad);
  }
  await assert.rejects(fetchPage('https://start.example/a', net), /redirects somewhere/);
  assert.equal(seen.some((u) => u.includes('169.254')), false, 'the unsafe redirect target must not be requested');
  await assert.rejects(fetchPage('https://redirect-loop.example/a', net), /Too many redirects/);
});

test('fetchPage errors say what happened, in words the agent can pass on', async () => {
  const status = (code: number, type = 'text/html') => (async () => respond('x', { status: code, headers: { 'content-type': type } })) as unknown as typeof fetch;
  await assert.rejects(fetchPage('https://a.example/x', status(404)), /status 404/);
  await assert.rejects(fetchPage('https://a.example/x', status(200, 'image/png')), /cannot be read/);
  await assert.rejects(fetchPage('https://a.example/x', (async () => html('<script>x</script>')) as unknown as typeof fetch), /no readable text/);
  await assert.rejects(fetchPage('https://a.example/x', (async () => { throw new TypeError('down'); }) as unknown as typeof fetch), /could not be reached/);
  await assert.rejects(fetchPage('https://a.example/x', (async () => respond('not a pdf', { headers: { 'content-type': 'application/pdf' } })) as unknown as typeof fetch, realPdfLoader), /PDF could not be read/);
});

test('a huge page is cut, not loaded whole', async () => {
  const big = 'word '.repeat(2_000_000); // 10 MB
  let read = 0;
  const stream = new ReadableStream<Uint8Array>({
    pull(c) {
      read += 65536;
      c.enqueue(new TextEncoder().encode(big.slice(0, 65536)));
      if (read > 20_000_000) c.close();
    },
  });
  const net = (async () => new Response(stream, { status: 200, headers: { 'content-type': 'text/plain' } })) as unknown as typeof fetch;
  const page = await fetchPage('https://big.example/a', net);
  assert.ok(read < 3_000_000, `read ${read} bytes`);
  assert.ok(page.text.length <= WEB.maxChars);
  assert.equal(page.truncated, true);
});

test('a slow page times out', async () => {
  const hang = ((_u: string, init: RequestInit) => new Promise((_r, rej) => init.signal!.addEventListener('abort', () => rej(new Error('aborted'))))) as unknown as typeof fetch;
  const old = WEB.timeoutMs;
  WEB.timeoutMs = 20;
  try {
    await assert.rejects(fetchPage('https://slow.example/a', hang), /could not be reached/);
  } finally {
    WEB.timeoutMs = old;
  }
});

