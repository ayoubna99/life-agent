import assert from 'node:assert/strict';
import { test } from 'node:test';

import { makePdf, PAGE, parseSheet, toLatin } from '../supabase/functions/_shared/makepdf.ts';
import { extractPdfText, isPdf } from '../supabase/functions/_shared/pdf.ts';
import { runServerTool } from '../supabase/functions/_shared/tools.ts';
import type { ToolEnv } from '../supabase/functions/_shared/tools.ts';
import { MemoryStore, realPdfLoader, realPdfMakeLoader, SUPABASE_URL } from './helpers.ts';
import { StoreError } from '../supabase/functions/_shared/store.ts';

const GERMAN = `## Week 1: Sounds and greetings

- **Hallo** (hello) and **Guten Tag** (good day)
- Say *Tschüss* when you leave
- Letters: ä, ö, ü and ß (Straße, Mädchen)

### Numbers
1. eins
2. zwei
3. drei

| German | English |
|---|---|
| der Apfel | the apple |
| die Brücke | the bridge |

> Tip: 15 minutes every day beats 2 hours on Sunday.

See [Duolingo](https://www.duolingo.com/course/de/en/Learn-German) for practice.
`;

const read = async (bytes: Uint8Array) => (await extractPdfText(bytes, realPdfLoader)).text;

test('a German beginner sheet becomes a real PDF whose text reads back, umlauts included', async () => {
  const made = await makePdf('How to start learning German', GERMAN, realPdfMakeLoader);
  assert.ok(isPdf(made.bytes));
  assert.equal(made.replaced, 0);
  assert.equal(made.pages, 1);
  const text = await read(made.bytes);
  for (const part of ['How to start learning German', 'Week 1: Sounds and greetings', 'Guten Tag', 'Tschüss', 'ä, ö, ü and ß', 'Straße', 'Mädchen', '1. eins', 'der Apfel', 'die Brücke', 'Tip: 15 minutes', 'https://www.duolingo.com/course/de/en/Learn-German']) {
    assert.ok(text.includes(part), `missing: ${part}`);
  }
  assert.doesNotMatch(text, /\*\*|\|---|##/, 'markdown marks are not printed');
  assert.match(text, /•/, 'bullets are drawn');
  assert.match(text, /1 \/ 1/, 'page numbers');
});

test('a long sheet flows onto more pages, and every line stays inside the margins', async () => {
  const md = Array.from({ length: 140 }, (_, i) => `- Line ${i + 1}: ${'Wort '.repeat(25)}`).join('\n');
  const made = await makePdf('Long', md, realPdfMakeLoader);
  assert.ok(made.pages >= 4, `pages: ${made.pages}`);
  const text = await read(made.bytes);
  assert.ok(text.includes('Line 1:') && text.includes('Line 140:'), 'nothing is lost between pages');
  assert.ok(text.includes(`${made.pages} / ${made.pages}`));
  // a word wider than a line (a long link) is cut instead of running off the page
  const long = await makePdf('Link', `https://example.com/${'a'.repeat(300)}`, realPdfMakeLoader);
  assert.equal(long.pages, 1);
  assert.ok(PAGE.margin > 0);
});

test('characters the PDF fonts cannot draw are replaced and counted, never a crash', async () => {
  const made = await makePdf('Arabic and emoji', 'Hello مرحبا 你好 😀 – “quoted” … → done', realPdfMakeLoader);
  assert.ok(made.replaced >= 4, `replaced: ${made.replaced}`);
  const text = await read(made.bytes);
  assert.match(text, /Hello/);
  assert.match(text, /"quoted"/, 'smart quotes are mapped to plain ones');
  assert.match(text, /->/);
  assert.deepEqual(toLatin('café €5 x'), { text: 'café €5 x', replaced: 0 });
  assert.deepEqual(toLatin('a​b­c'), { text: 'abc', replaced: 0 }, 'invisible characters are dropped without a "?"');
});

test('the markdown reader keeps structure and drops the marks', () => {
  const kinds = parseSheet(GERMAN).filter((b) => b.kind !== 'gap').map((b) => b.kind);
  // table header + 2 rows, the tip, and the link line are the five paragraphs
  assert.deepEqual(kinds, ['h2', 'bullet', 'bullet', 'bullet', 'h3', 'number', 'number', 'number', 'p', 'p', 'p', 'p', 'p']);
  const blocks = parseSheet('# T\n```\ncode **kept**\n```\n- a\n  - nested\n---\n**bold** and `code`');
  assert.equal(blocks.find((b) => b.text === 'code **kept**')?.kind, 'p', 'fenced text is printed as it is');
  assert.ok(blocks.find((b) => b.text === 'nested')!.indent > blocks.find((b) => b.text === 'a')!.indent);
  assert.equal(blocks.at(-1)!.text, 'bold and code');
  assert.ok(blocks.some((b) => b.kind === 'rule'));
});

// ---------- the tool ----------

function toolEnv(over: Partial<ToolEnv> = {}): ToolEnv & { store: MemoryStore } {
  return { store: new MemoryStore(), mode: 'planning', today: '2026-10-26', planDate: '2026-10-27', supabaseUrl: SUPABASE_URL, fetchImpl: fetch, randomId: () => 'abcdef12', loadPdfMaker: realPdfMakeLoader, ...over } as ToolEnv & { store: MemoryStore };
}
const run = async (args: Record<string, unknown>, env: ToolEnv) => {
  const out = await runServerTool('create_material', args, env);
  return { ...JSON.parse(out.content), artifact: out.artifact };
};

test('create_material: a PDF by default, with the page count and an artifact for the phone', async () => {
  const env = toolEnv();
  const r = await run({ title: 'Learn German as a beginner', markdown: GERMAN }, env);
  assert.equal(r.format, 'pdf');
  assert.equal(r.pages, 1);
  assert.equal(r.note, undefined);
  assert.match(r.url, /\/materials\/[^?]*2026-10-27-learn-german-as-a-beginner-abcdef12\.pdf/);
  assert.deepEqual(r.artifact, { type: 'pdf', title: 'Learn German as a beginner', url: r.url });
  const saved = env.store.files.get('2026-10-27-learn-german-as-a-beginner-abcdef12.pdf')!;
  assert.equal(saved.contentType, 'application/pdf');
  assert.match(await read(saved.bytes), /Guten Tag/);
});

test('create_material: a sheet in another script says so and the model can ask for markdown instead', async () => {
  const r = await run({ title: 'Arabic basics', markdown: '- مرحبا (hello)' }, toolEnv());
  assert.match(r.note, /could not be drawn.*format "markdown"/);
  const md = await run({ title: 'Arabic basics', markdown: '- مرحبا (hello)', format: 'markdown' }, toolEnv());
  assert.equal(md.format, 'markdown');
  assert.equal(md.note, undefined);
});

test('create_material: if the PDF library cannot be loaded the sheet is saved as markdown instead of failing', async () => {
  const env = toolEnv({ loadPdfMaker: async () => { throw new Error('import failed'); } });
  const r = await run({ title: 'Sheet', markdown: '- a' }, env);
  assert.equal(r.format, 'markdown');
  assert.equal(r.artifact.type, 'markdown');
  assert.deepEqual([...env.store.materials.keys()], ['2026-10-27-sheet-abcdef12.md']);
  assert.equal(env.store.files.size, 0);
});

test('create_material: a broken store still ends the request, it is not hidden by the markdown fallback', async () => {
  const env = toolEnv();
  env.store.saveFile = async () => { throw new StoreError('material', 503); };
  await assert.rejects(run({ title: 'Sheet', markdown: '- a' }, env), (e: unknown) => e instanceof StoreError);
  assert.equal(env.store.materials.size, 0);
});

test('create_material: bad input is told to the model in words', async () => {
  const r = (args: Record<string, unknown>) => run(args, toolEnv());
  assert.match((await r({ markdown: 'x' })).error, /title is required/);
  assert.match((await r({ title: 't' })).error, /markdown is required/);
  assert.match((await r({ title: 't', markdown: 'x'.repeat(6001) })).error, /at most 6000/);
  assert.match((await r({ title: 't', markdown: 'x', format: 'docx' })).error, /format must be pdf or markdown/);
});
