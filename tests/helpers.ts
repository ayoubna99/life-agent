import type { ChatMessage, MuseConfig } from '../supabase/functions/_shared/muse.ts';
import type { PlanData } from '../supabase/functions/_shared/plan.ts';
import type { Mode } from '../supabase/functions/_shared/prompt.ts';
import { StoreError } from '../supabase/functions/_shared/store.ts';
import type { Profile } from '../supabase/functions/_shared/profile.ts';
import type { NewDocument, SavedPlan, Store, StoredDocument, UsageRow } from '../supabase/functions/_shared/store.ts';

export const SUPABASE_URL = 'https://proj.supabase.co';
export const USER = '00000000-0000-0000-0000-00000000000a';
export const cfg: MuseConfig = { baseUrl: 'https://muse.example/v1', apiKey: 'sk-secret-key', model: 'muse-test' };

/** An in-memory copy of everything the agent stores. */
export class MemoryStore implements Store {
  quota = 0;
  conversations = new Map<string, { id: string; kind: Mode }>();
  messages = new Map<string, ChatMessage[]>();
  plans = new Map<string, SavedPlan>();
  usage: UsageRow[] = [];
  materials = new Map<string, string>();
  profile: Profile = { apps: [] };
  documents = new Map<string, StoredDocument>();
  uploads = new Map<string, Uint8Array>();
  failNext: string | null = null;
  private n = 0;

  private check(op: string) {
    if (this.failNext === op) {
      this.failNext = null;
      throw new StoreError(op, 503);
    }
  }

  globalQuota = 0;
  async bumpQuota() {
    return ++this.quota;
  }
  async bumpGlobalQuota() {
    return ++this.globalQuota;
  }
  async getConversation(id: string) {
    return this.conversations.get(id) ?? null;
  }
  async createConversation(kind: Mode) {
    const id = `c0000000-0000-0000-0000-${String(++this.n).padStart(12, '0')}`;
    this.conversations.set(id, { id, kind });
    this.messages.set(id, []);
    return id;
  }
  async loadMessages(id: string) {
    return structuredClone(this.messages.get(id) ?? []);
  }
  async appendMessages(id: string, msgs: ChatMessage[]) {
    this.check('messages');
    this.messages.get(id)!.push(...structuredClone(msgs));
  }
  async getPlan(date: string) {
    return this.plans.get(date) ?? null;
  }
  async savePlan(date: string, data: PlanData) {
    this.check('plan');
    this.plans.set(date, { date, status: 'ready', data: structuredClone(data) });
  }
  async getUsage(app: string, since: string) {
    return this.usage.filter((r) => r.app.toLowerCase() === app.toLowerCase() && r.day >= since).sort((a, b) => b.day.localeCompare(a.day));
  }
  async upsertUsage(rows: UsageRow[]) {
    for (const r of rows) {
      const i = this.usage.findIndex((u) => u.day === r.day && u.app.toLowerCase() === r.app.toLowerCase());
      if (i >= 0) this.usage[i] = r;
      else this.usage.push({ ...r });
    }
  }
  async getProfile() {
    return structuredClone(this.profile);
  }
  async saveProfile(patch: Partial<Profile>) {
    this.profile = { ...this.profile, ...structuredClone(patch) };
  }
  async downloadUpload(path: string, maxBytes: number) {
    const b = this.uploads.get(path);
    return b && b.length <= maxBytes ? b : null;
  }
  deleted: string[] = [];
  docFiles = new Map<string, string | null>();
  files = new Map<string, { bytes: Uint8Array; contentType: string }>();
  async saveFile(fileName: string, bytes: Uint8Array, contentType: string) {
    this.files.set(fileName, { bytes, contentType });
    return `${SUPABASE_URL}/storage/v1/object/sign/materials/${USER}/${fileName}?token=t`;
  }
  async deleteUpload(path: string) {
    this.uploads.delete(path);
    this.deleted.push(path);
  }
  async saveDocument(doc: NewDocument) {
    const id = `d0000000-0000-0000-0000-${String(++this.n).padStart(12, '0')}`;
    this.documents.set(id, { id, name: doc.name, text: doc.text, pages: doc.pages, kind: doc.kind });
    this.docFiles.set(id, doc.filePath);
    return id;
  }
  async getDocument(id: string) {
    return this.documents.get(id) ?? null;
  }
  async saveMaterial(fileName: string, markdown: string) {
    this.materials.set(fileName, markdown);
    return `${SUPABASE_URL}/storage/v1/object/sign/materials/${USER}/${fileName}?token=t`;
  }
}

export const textReply = (text: string) => ({ choices: [{ message: { role: 'assistant', content: text } }] });
export const callsReply = (...calls: [name: string, args: unknown, id?: string][]) => ({
  choices: [
    {
      message: {
        role: 'assistant',
        content: null,
        tool_calls: calls.map(([name, args, id], i) => ({ id: id ?? `call_${i + 1}`, type: 'function', function: { name, arguments: JSON.stringify(args) } })),
      },
    },
  ],
});

export interface FakeNet {
  fetchImpl: typeof fetch;
  /** Every body sent to the model, parsed. */
  museRequests: { messages: ChatMessage[]; tools: { function: { name: string } }[]; model: string }[];
  /** Every other URL that was fetched (link checks). */
  otherUrls: string[];
}

/** Muse Spark answers from `replies` in order; any other URL answers from `others` (status by URL, default 200). */
export function fakeNet(replies: unknown[], others: Record<string, number | 'network'> = {}): FakeNet {
  const net: FakeNet = { fetchImpl: undefined as unknown as typeof fetch, museRequests: [], otherUrls: [] };
  let i = 0;
  net.fetchImpl = (async (url: string, init?: RequestInit) => {
    if (url.startsWith('https://muse.example/')) {
      net.museRequests.push(JSON.parse(init!.body as string));
      if (i >= replies.length) throw new Error('the test scripted fewer Muse Spark replies than were asked for');
      return new Response(JSON.stringify(replies[i++]), { status: 200 });
    }
    net.otherUrls.push(`${init?.method ?? 'GET'} ${url}`);
    const planned = others[url] ?? 200;
    if (planned === 'network') throw new TypeError('fetch failed');
    return new Response('', { status: planned });
  }) as unknown as typeof fetch;
  return net;
}

export function jwt(claims: Record<string, unknown> = {}): string {
  const b64 = (o: unknown) => Buffer.from(JSON.stringify(o)).toString('base64url');
  return `${b64({ alg: 'ES256', typ: 'JWT' })}.${b64({ sub: USER, role: 'authenticated', exp: Math.floor(Date.now() / 1000) + 3600, ...claims })}.sig`;
}

/** A real, minimal PDF with one line of text per page (an empty string gives a page with no text, like a scan). */
export function makePdf(pages: string[]): Uint8Array {
  const objs: string[] = [];
  const kids: string[] = [];
  objs[1] = '<< /Type /Catalog /Pages 2 0 R >>';
  const first = 4 + pages.length; // object numbers: 1 catalog, 2 pages, 3 font, then (page, content) pairs
  pages.forEach((text, i) => {
    const pageNo = 4 + i * 2;
    kids.push(`${pageNo} 0 R`);
    const stream = text ? `BT /F1 14 Tf 72 720 Td (${text.replace(/[()\\]/g, '\\$&')}) Tj ET` : '';
    objs[pageNo] = `<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 3 0 R >> >> /Contents ${pageNo + 1} 0 R >>`;
    objs[pageNo + 1] = `<< /Length ${stream.length} >>\nstream\n${stream}\nendstream`;
  });
  void first;
  objs[2] = `<< /Type /Pages /Kids [${kids.join(' ')}] /Count ${pages.length} >>`;
  objs[3] = '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>';
  let out = '%PDF-1.4\n';
  const offsets: number[] = [];
  for (let n = 1; n < objs.length; n++) {
    offsets[n] = out.length;
    out += `${n} 0 obj\n${objs[n]}\nendobj\n`;
  }
  const xref = out.length;
  out += `xref\n0 ${objs.length}\n0000000000 65535 f \n`;
  for (let n = 1; n < objs.length; n++) out += `${String(offsets[n]).padStart(10, '0')} 00000 n \n`;
  out += `trailer\n<< /Size ${objs.length} /Root 1 0 R >>\nstartxref\n${xref}\n%%EOF\n`;
  return new TextEncoder().encode(out);
}

/** The PDF library as the tests load it (Deno loads "npm:unpdf" itself). */
/** The PDF writer as the tests load it (Deno loads "npm:pdf-lib" itself). */
export const realPdfMakeLoader = () => import('pdf-lib') as unknown as Promise<import('../supabase/functions/_shared/makepdf.ts').PdfMakeLib>;

export const realPdfLoader = () => import('unpdf') as unknown as Promise<import('../supabase/functions/_shared/pdf.ts').PdfLib>;

/** A WAV file of silence (or a quiet tone) with the given format. */
export function makeWav(opts: { seconds?: number; rate?: number; channels?: number; bits?: number; format?: number; dataSize?: number } = {}): Uint8Array {
  const { seconds = 2, rate = 24000, channels = 1, bits = 16, format = 1 } = opts;
  const bytes = Math.round(seconds * rate * channels * (bits / 8));
  const out = new Uint8Array(44 + bytes);
  const v = new DataView(out.buffer);
  const tag = (at: number, t: string) => [...t].forEach((c, i) => (out[at + i] = c.charCodeAt(0)));
  tag(0, 'RIFF'); v.setUint32(4, 36 + bytes, true); tag(8, 'WAVE'); tag(12, 'fmt ');
  v.setUint32(16, 16, true); v.setUint16(20, format, true); v.setUint16(22, channels, true); v.setUint32(24, rate, true);
  v.setUint32(28, (rate * channels * bits) / 8, true); v.setUint16(32, (channels * bits) / 8, true); v.setUint16(34, bits, true);
  tag(36, 'data'); v.setUint32(40, opts.dataSize ?? bytes, true);
  return out;
}

/** A planning conversation where the agent already showed its plan and asked for confirmation (so a save is allowed next). */
export async function askedToConfirm(store: MemoryStore, kind: Mode = 'planning'): Promise<string> {
  const id = await store.createConversation(kind);
  await store.appendMessages(id, [
    { role: 'user', content: 'Study algorithms tomorrow' },
    { role: 'assistant', content: 'Here is the plan: study 40 minutes at 18:00. Does that look good?' },
  ]);
  return id;
}
