// The request handler, kept free of Deno APIs so the tests can call it directly.

import { BadRequest, CapacityReached, DEFAULT_DAILY_LIMIT, DEFAULT_GLOBAL_LIMIT, limitFromEnv, NotFound, parseChatRequest, QuotaExceeded, runChat, spendQuota } from './loop.ts';
import { configFromEnv, MuseError } from './muse.ts';
import { ASR_MODEL, languageBias, transcribeWav } from './asr.ts';
import { runNudge, parseNudgeRequest } from './nudge.ts';
import { describeImage, describePdf, IMAGES, ImageError, sniffImage } from './images.ts';
import type { PdfMakeLoader } from './makepdf.ts';
import { extractPdfText, isPdf } from './pdf.ts';
import { parseWav, WavError } from './wav.ts';
import type { PdfLoader } from './pdf.ts';
import { isDate } from './plan.ts';
import { validateProfile } from './profile.ts';
import { RestStore, StoreError } from './store.ts';
import type { Store, UsageRow } from './store.ts';

export interface HandlerEnv {
  get(name: string): string | undefined;
  fetchImpl?: typeof fetch;
  /** Tests inject a store; production builds a RestStore from the caller's token. */
  storeFor?: (userId: string, jwt: string, apikey: string) => Store;
  loadPdf?: PdfLoader;
  loadPdfMaker?: PdfMakeLoader;
}

const json = (body: unknown, status = 200): Response =>
  new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' } });

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/** The gateway already verified the signature (verify_jwt); we only read who it is. Every database call
 *  is made with this same token, so row-level security would refuse anything that is not theirs. */
export function userFromAuthHeader(header: string | null): { userId: string; jwt: string } | null {
  const m = /^Bearer ([\w-]+\.[\w-]+\.[\w-]+)$/.exec(header ?? '');
  if (!m) return null;
  try {
    const b64 = m[1].split('.')[1].replace(/-/g, '+').replace(/_/g, '/');
    const claims = JSON.parse(atob(b64.padEnd(Math.ceil(b64.length / 4) * 4, '=')));
    if (typeof claims.sub !== 'string' || !UUID.test(claims.sub) || claims.role !== 'authenticated') return null;
    if (typeof claims.exp === 'number' && claims.exp * 1000 < Date.now()) return null;
    return { userId: claims.sub, jwt: m[1] };
  } catch {
    return null;
  }
}

const MAX_USAGE_ROWS = 200;
const MAX_UPLOAD_BYTES = 10 * 1024 * 1024;
const MAX_DOC_CHARS = 300_000;

function parseUsage(body: Record<string, unknown>): UsageRow[] {
  const days = body.days;
  if (!Array.isArray(days) || days.length === 0 || days.length > MAX_USAGE_ROWS) throw new BadRequest('bad_usage');
  const seen = new Set<string>();
  return days.map((r: Record<string, unknown>) => {
    const app = typeof r?.app === 'string' ? r.app.trim() : '';
    if (!isDate(r?.day) || !app || app.length > 60 || typeof r.minutes !== 'number' || !Number.isInteger(r.minutes) || r.minutes < 0 || r.minutes > 1440) {
      throw new BadRequest('bad_usage');
    }
    const key = `${r.day}|${app.toLowerCase()}`;
    if (seen.has(key)) throw new BadRequest('bad_usage');
    seen.add(key);
    return { day: r.day as string, app, minutes: r.minutes as number };
  });
}

export async function handle(req: Request, env: HandlerEnv): Promise<Response> {
  if (req.method !== 'POST') return json({ error: { code: 'method_not_allowed' } }, 405);

  const who = userFromAuthHeader(req.headers.get('Authorization'));
  if (!who) return json({ error: { code: 'not_signed_in' } }, 401);

  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return json({ error: { code: 'invalid_json' } }, 400);
  }
  if (!body || typeof body !== 'object') return json({ error: { code: 'invalid_json' } }, 400);

  const supabaseUrl = env.get('SUPABASE_URL') ?? '';
  const apikey = req.headers.get('apikey') ?? env.get('SUPABASE_ANON_KEY') ?? '';
  const store =
    env.storeFor?.(who.userId, who.jwt, apikey) ??
    new RestStore({ supabaseUrl, apikey, jwt: who.jwt, userId: who.userId, fetchImpl: env.fetchImpl });

  try {
    const limits = {
      dailyLimit: limitFromEnv(env.get('AGENT_DAILY_LIMIT'), DEFAULT_DAILY_LIMIT),
      globalLimit: limitFromEnv(env.get('AGENT_GLOBAL_DAILY_LIMIT'), DEFAULT_GLOBAL_LIMIT),
    };
    switch (body.action) {
      case 'chat': {
        const result = await runChat(parseChatRequest(body), {
          cfg: configFromEnv((n) => env.get(n)),
          store,
          userId: who.userId,
          supabaseUrl,
          ...limits,
          fetchImpl: env.fetchImpl,
          searchModel: env.get('SEARCH_MODEL')?.trim() || undefined,
          imageModel: env.get('IMAGE_MODEL')?.trim() || undefined,
          loadPdf: env.loadPdf,
          loadPdfMaker: env.loadPdfMaker,
        });
        return json(result);
      }
      case 'nudge': {
        const result = await runNudge(parseNudgeRequest(body), {
          cfg: configFromEnv((n) => env.get(n)),
          store,
          ...limits,
          fetchImpl: env.fetchImpl,
        });
        return json(result);
      }
      case 'profile': {
        if (body.set !== undefined) {
          const checked = validateProfile(body.set);
          if (!checked.ok) throw new BadRequest(checked.error);
          await store.saveProfile(checked.patch);
        }
        return json({ profile: await store.getProfile() });
      }
      case 'attach': {
        // The phone uploaded the file to Storage (bucket "uploads", folder = the user's id); we read it once.
        const path = typeof body.path === 'string' ? body.path : '';
        if (!path.startsWith(`${who.userId}/`) || path.includes('..') || path.length > 200) throw new BadRequest('bad_path');
        const name = (typeof body.name === 'string' && body.name.trim() ? body.name.trim() : path.split('/').pop()!).slice(0, 120);
        const bytes = await store.downloadUpload(path, MAX_UPLOAD_BYTES);
        if (!bytes) throw new BadRequest('file_not_found');
        let text: string;
        let pages = 1;
        let kind: 'pdf' | 'text' | 'image' = 'text';
        let readBy: 'text' | 'vision' = 'text';
        const image = sniffImage(bytes);
        if (image) {
          // A photo: Muse Spark reads it once. The text is what the agent works with; the photo itself stays in "uploads".
          if (bytes.length > IMAGES.maxInputBytes) throw new BadRequest('image_too_large');
          await spendQuota(store, limits);
          kind = 'image';
          readBy = 'vision';
          try {
            text = await describeImage(bytes, image, configFromEnv((n) => env.get(n)), env.fetchImpl);
          } catch (e) {
            if (e instanceof ImageError) throw new BadRequest('image_unreadable');
            throw e;
          }
        } else if (isPdf(bytes)) {
          kind = 'pdf';
          try {
            ({ text, pages } = await extractPdfText(bytes, env.loadPdf));
          } catch {
            throw new BadRequest('pdf_unreadable');
          }
          if (text.trim() === '') {
            // No text layer (a scan, or slides that are pictures): Muse Spark reads the pages as images instead.
            await spendQuota(store, limits);
            readBy = 'vision';
            try {
              text = await describePdf(bytes, name, configFromEnv((n) => env.get(n)), env.fetchImpl);
            } catch (e) {
              if (e instanceof ImageError) throw new BadRequest('no_text_in_document');
              throw e;
            }
          }
        } else {
          text = new TextDecoder('utf-8', { fatal: false }).decode(bytes).replace(/\u0000/g, '').trim();
          if (/[\u0000-\u0008\u000e-\u001f]/.test(text.slice(0, 2000))) throw new BadRequest('unsupported_file');
        }
        if (text.trim() === '') throw new BadRequest('no_text_in_document');
        const truncated = text.length > MAX_DOC_CHARS;
        if (truncated) text = text.slice(0, MAX_DOC_CHARS);
        // Originals (photos can be several MB) are deleted once read: the text is what the agent uses. KEEP_ORIGINALS=true keeps them
        // in "uploads/<your id>/", private to the user.
        const keep = env.get('KEEP_ORIGINALS')?.trim().toLowerCase() === 'true';
        const id = await store.saveDocument({ name, text, pages, kind, filePath: keep ? path : null });
        if (!keep) await store.deleteUpload(path);
        return json({ document_id: id, name, kind, read_by: readBy, pages, chars: text.length, truncated, file_path: keep ? path : null });
      }
      case 'transcribe': {
        // The phone uploaded a short WAV recording to Storage; we send it to Muse Voice Transcribe and return the text.
        const path = typeof body.path === 'string' ? body.path : '';
        if (!path.startsWith(`${who.userId}/`) || path.includes('..') || path.length > 200) throw new BadRequest('bad_path');
        await spendQuota(store, limits);
        const wav = await store.downloadUpload(path, MAX_UPLOAD_BYTES);
        if (!wav) throw new BadRequest('file_not_found');
        try {
          parseWav(wav);
        } catch (e) {
          if (e instanceof WavError) throw new BadRequest(`bad_audio_${e.message}`);
          throw e;
        }
        const keywords = [...(await store.getProfile()).apps, ...(Array.isArray(body.keywords) ? body.keywords : [])]
          .filter((k): k is string => typeof k === 'string' && k.trim() !== '' && k.length <= 40)
          .map((k) => k.trim())
          .filter((k, i, all) => all.findIndex((x) => x.toLowerCase() === k.toLowerCase()) === i)
          .slice(0, 25);
        const muse = configFromEnv((n) => env.get(n));
        const out = await transcribeWav(
          { baseUrl: env.get('ASR_BASE_URL')?.trim() || muse.baseUrl, apiKey: muse.apiKey, model: env.get('ASR_MODEL')?.trim() || ASR_MODEL },
          wav,
          { languages: languageBias(body.languages), keywords, sessionId: `life-${who.userId.slice(0, 8)}-${Date.now()}` },
          env.fetchImpl,
        );
        await store.deleteUpload(path); // the recording is not kept
        if (!out.text) throw new BadRequest('no_speech');
        return json({ text: out.text, duration_ms: out.durationMs });
      }
      case 'usage': {
        const rows = parseUsage(body);
        await store.upsertUsage(rows);
        return json({ saved: rows.length });
      }
      case 'plan': {
        if (!isDate(body.date)) throw new BadRequest('bad_date');
        return json({ plan: await store.getPlan(body.date) });
      }
      default:
        throw new BadRequest('unknown_action');
    }
  } catch (e) {
    if (e instanceof BadRequest) return json({ error: { code: e.reason } }, 422);
    if (e instanceof QuotaExceeded) return json({ error: { code: 'daily_limit_reached' } }, 429);
    if (e instanceof CapacityReached) return json({ error: { code: 'demo_at_capacity' } }, 429);
    if (e instanceof NotFound) return json({ error: { code: 'conversation_not_found' } }, 404);
    if (e instanceof StoreError) {
      console.error(`agent: ${e.message}`);
      return json({ error: { code: 'store_error' } }, 502);
    }
    if (e instanceof MuseError) {
      // The kind and status only: never the key, the prompt or what the user wrote.
      console.error(`agent: ${e.message}`);
      const status = e.code === 'not_configured' ? 500 : e.code === 'timeout' ? 504 : 502;
      return json({ error: { code: `agent_${e.code}` } }, status);
    }
    console.error('agent: unexpected error');
    return json({ error: { code: 'internal' } }, 500);
  }
}
