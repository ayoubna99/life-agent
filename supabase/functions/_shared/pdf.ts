// Text out of a PDF. The library is loaded on demand: Deno (Supabase) resolves "npm:unpdf", and the tests
// pass their own loader. Scanned PDFs (pictures of text) have no text and are reported as such.

export interface PdfLib {
  getDocumentProxy(data: Uint8Array): Promise<unknown>;
  extractText(pdf: unknown, opts: { mergePages: true }): Promise<{ totalPages: number; text: string }>;
}

export type PdfLoader = () => Promise<PdfLib>;

export const defaultPdfLoader: PdfLoader = () => import('npm:unpdf@1.9.1') as unknown as Promise<PdfLib>;

export const isPdf = (bytes: Uint8Array): boolean =>
  bytes.length > 4 && bytes[0] === 0x25 && bytes[1] === 0x50 && bytes[2] === 0x44 && bytes[3] === 0x46; // "%PDF"

export async function extractPdfText(bytes: Uint8Array, load: PdfLoader = defaultPdfLoader): Promise<{ text: string; pages: number }> {
  const lib = await load();
  const doc = await lib.getDocumentProxy(bytes);
  const { totalPages, text } = await lib.extractText(doc, { mergePages: true });
  return { text: text.replace(/[ \t]+\n/g, '\n').replace(/\n{3,}/g, '\n\n').trim(), pages: totalPages };
}
