// Turns the agent's markdown sheet into a real PDF (A4, Helvetica). The library is loaded on demand, like unpdf:
// Deno (Supabase) resolves "npm:pdf-lib", and the tests pass their own loader.
//
// Built-in PDF fonts only draw Latin text (English, French, German, Spanish...). Anything else (Arabic, Chinese,
// emoji...) would crash the library, so it is replaced by "?" and counted, so the caller can say so.

interface PdfFont {
  widthOfTextAtSize(text: string, size: number): number;
}
interface PdfPage {
  drawText(text: string, opts: { x: number; y: number; size: number; font: PdfFont; color?: unknown }): void;
  drawLine(opts: { start: { x: number; y: number }; end: { x: number; y: number }; thickness: number; color?: unknown }): void;
}
interface PdfDoc {
  embedFont(name: unknown): Promise<PdfFont>;
  addPage(size: [number, number]): PdfPage;
  getPages(): PdfPage[];
  setTitle(t: string): void;
  setCreator(t: string): void;
  setProducer(t: string): void;
  save(): Promise<Uint8Array>;
}
export interface PdfMakeLib {
  PDFDocument: { create(): Promise<PdfDoc> };
  StandardFonts: { Helvetica: unknown; HelveticaBold: unknown };
  rgb(r: number, g: number, b: number): unknown;
}
export type PdfMakeLoader = () => Promise<PdfMakeLib>;

export const defaultPdfMakeLoader: PdfMakeLoader = () => import('npm:pdf-lib@1.17.1') as unknown as Promise<PdfMakeLib>;

export const PAGE = { width: 595, height: 842, margin: 56 } as const;

const NICE: Record<string, string> = {
  '‘': "'", '’': "'", '‚': "'", '“': '"', '”': '"', '„': '"',
  '–': '-', '—': '-', '−': '-', '…': '...', '•': '•', '€': '€',
  '→': '->', '←': '<-', '✓': 'v', '✔': 'v', ' ': ' ', '\t': '    ',
};

/** Keeps what the standard fonts can draw (printable Latin-1 and the bullet and euro), maps common symbols, replaces the rest. */
export function toLatin(text: string): { text: string; replaced: number } {
  let replaced = 0;
  let out = '';
  for (const ch of text) {
    const code = ch.codePointAt(0)!;
    if (code === 0xad || code === 0x200b || code === 0xfe0f || (code >= 0x300 && code <= 0x36f)) continue; // invisible: drop silently
    if (NICE[ch] !== undefined) out += NICE[ch];
    else if ((code >= 0x20 && code <= 0x7e) || (code >= 0xa1 && code <= 0xff)) out += ch;
    else {
      out += '?';
      replaced++;
    }
  }
  return { text: out, replaced };
}

type Block = { kind: 'title' | 'h1' | 'h2' | 'h3' | 'p' | 'bullet' | 'number' | 'gap' | 'rule'; text: string; indent: number };

const inline = (s: string) =>
  s
    .replace(/!?\[([^\]]*)\]\(([^)\s]+)\)/g, (_m, label, url) => (label && label !== url ? `${label} (${url})` : url))
    .replace(/(\*\*|__)(.+?)\1/g, '$2')
    .replace(/`([^`]+)`/g, '$1')
    .replace(/(^|[\s(])\*([^*\s][^*]*?)\*(?=[\s).,;:!?]|$)/g, '$1$2')
    .trim();

export function parseSheet(markdown: string): Block[] {
  const blocks: Block[] = [];
  let fenced = false;
  for (const raw of markdown.replace(/\r\n?/g, '\n').split('\n')) {
    const line = raw.replace(/\s+$/, '');
    if (/^\s*(```|~~~)/.test(line)) {
      fenced = !fenced;
      continue;
    }
    if (fenced) {
      blocks.push({ kind: 'p', text: line, indent: 14 });
      continue;
    }
    if (line.trim() === '') {
      blocks.push({ kind: 'gap', text: '', indent: 0 });
      continue;
    }
    let m: RegExpMatchArray | null;
    if ((m = line.match(/^(#{1,6})\s+(.*)$/))) blocks.push({ kind: m[1].length === 1 ? 'h1' : m[1].length === 2 ? 'h2' : 'h3', text: inline(m[2]), indent: 0 });
    else if (/^\s*([-*_])(\s*\1){2,}\s*$/.test(line)) blocks.push({ kind: 'rule', text: '', indent: 0 });
    else if ((m = line.match(/^(\s*)[-*+]\s+(.*)$/))) blocks.push({ kind: 'bullet', text: inline(m[2]), indent: Math.min(3, Math.floor(m[1].length / 2)) * 16 + 12 });
    else if ((m = line.match(/^(\s*)(\d+)[.)]\s+(.*)$/))) blocks.push({ kind: 'number', text: `${m[2]}. ${inline(m[3])}`, indent: Math.min(3, Math.floor(m[1].length / 2)) * 16 });
    else if ((m = line.match(/^\s*>\s?(.*)$/))) blocks.push({ kind: 'p', text: inline(m[1]), indent: 14 });
    else if (/^\s*\|.*\|\s*$/.test(line)) {
      if (/^\s*\|?[\s:|-]+\|?\s*$/.test(line) && line.includes('-')) continue; // the |---|---| row
      blocks.push({ kind: 'p', text: line.trim().slice(1, -1).split('|').map((c) => inline(c)).join('   |   '), indent: 0 });
    } else blocks.push({ kind: 'p', text: inline(line), indent: 0 });
  }
  return blocks;
}

const SIZES = { title: 20, h1: 16, h2: 13, h3: 11.5, p: 11, bullet: 11, number: 11 } as const;

function wrap(text: string, font: PdfFont, size: number, width: number): string[] {
  const lines: string[] = [];
  let current = '';
  for (let word of text.split(/\s+/).filter(Boolean)) {
    while (font.widthOfTextAtSize(word, size) > width) {
      // a word wider than the line (a long link): cut it
      let n = word.length;
      while (n > 1 && font.widthOfTextAtSize(word.slice(0, n), size) > width) n--;
      if (current) {
        lines.push(current);
        current = '';
      }
      lines.push(word.slice(0, n));
      word = word.slice(n);
    }
    const next = current ? `${current} ${word}` : word;
    if (current && font.widthOfTextAtSize(next, size) > width) {
      lines.push(current);
      current = word;
    } else current = next;
  }
  if (current) lines.push(current);
  return lines;
}

export interface MadePdf {
  bytes: Uint8Array;
  pages: number;
  /** Characters the PDF fonts cannot draw (shown as "?"). */
  replaced: number;
}

export async function makePdf(title: string, markdown: string, load: PdfMakeLoader = defaultPdfMakeLoader): Promise<MadePdf> {
  const lib = await load();
  const doc = await lib.PDFDocument.create();
  const regular = await doc.embedFont(lib.StandardFonts.Helvetica);
  const bold = await doc.embedFont(lib.StandardFonts.HelveticaBold);
  const ink = lib.rgb(0.1, 0.1, 0.12);
  const grey = lib.rgb(0.45, 0.45, 0.5);

  let replaced = 0;
  const clean = (s: string) => {
    const r = toLatin(s);
    replaced += r.replaced;
    return r.text;
  };

  const heading = clean(title);
  doc.setTitle(heading);
  doc.setCreator('Life');
  doc.setProducer('Life');

  let page = doc.addPage([PAGE.width, PAGE.height]);
  let y = PAGE.height - PAGE.margin;
  const width = PAGE.width - PAGE.margin * 2;
  const room = (need: number) => {
    if (y - need < PAGE.margin) {
      page = doc.addPage([PAGE.width, PAGE.height]);
      y = PAGE.height - PAGE.margin;
    }
  };
  const draw = (text: string, size: number, font: PdfFont, x: number, wrapWidth: number, hang = 0) => {
    const lines = wrap(text, font, size, wrapWidth);
    lines.forEach((l, i) => {
      room(size * 1.4);
      y -= size * 1.35;
      page.drawText(l, { x: x + (i > 0 ? hang : 0), y, size, font, color: ink });
    });
  };

  for (const line of wrap(heading, bold, SIZES.title, width)) {
    y -= SIZES.title * 1.3;
    page.drawText(line, { x: PAGE.margin, y, size: SIZES.title, font: bold, color: ink });
  }
  y -= 8;
  page.drawLine({ start: { x: PAGE.margin, y }, end: { x: PAGE.width - PAGE.margin, y }, thickness: 0.8, color: grey });
  y -= 6;

  let lastGap = true;
  for (const b of parseSheet(markdown)) {
    if (b.kind === 'gap') {
      if (!lastGap) y -= 6;
      lastGap = true;
      continue;
    }
    lastGap = false;
    if (b.kind === 'rule') {
      y -= 6;
      room(10);
      page.drawLine({ start: { x: PAGE.margin, y }, end: { x: PAGE.width - PAGE.margin, y }, thickness: 0.5, color: grey });
      y -= 6;
      continue;
    }
    const text = clean(b.text);
    if (b.kind === 'h1' || b.kind === 'h2' || b.kind === 'h3') {
      y -= b.kind === 'h1' ? 10 : 6;
      room(SIZES[b.kind] * 1.35 * 3); // never a heading alone at the bottom of a page
      draw(text, SIZES[b.kind], bold, PAGE.margin, width);
      y -= 2;
    } else if (b.kind === 'bullet') {
      room(SIZES.bullet * 1.4);
      page.drawText('•', { x: PAGE.margin + b.indent - 12, y: y - SIZES.bullet * 1.35, size: SIZES.bullet, font: regular, color: ink });
      draw(text, SIZES.bullet, regular, PAGE.margin + b.indent, width - b.indent);
    } else if (b.kind === 'number') {
      draw(text, SIZES.number, regular, PAGE.margin + b.indent, width - b.indent, 14);
    } else {
      draw(text, SIZES.p, regular, PAGE.margin + b.indent, width - b.indent);
    }
  }

  const pages = doc.getPages();
  pages.forEach((p, i) => {
    const label = `${i + 1} / ${pages.length}`;
    p.drawText(label, { x: PAGE.width / 2 - regular.widthOfTextAtSize(label, 9) / 2, y: PAGE.margin / 2, size: 9, font: regular, color: grey });
  });
  return { bytes: await doc.save(), pages: pages.length, replaced };
}
