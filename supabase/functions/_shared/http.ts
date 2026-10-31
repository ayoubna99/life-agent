// The request handler, kept free of Deno APIs so the tests can call it directly.

import { BadRequest, CapacityReached, DEFAULT_DAILY_LIMIT, DEFAULT_GLOBAL_LIMIT, limitFromEnv, NotFound, parseChatRequest, QuotaExceeded, runChat, spendQuota } from './loop.ts';
import { configFromEnv, modelsFor, MuseError } from './muse.ts';
import type { MuseConfig } from './muse.ts';
import { ASR_MODEL, languageBias, transcribeWav } from './asr.ts';
import { runNudge, parseNudgeRequest } from './nudge.ts';
import { describeImage, describePdf, IMAGES, ImageError, sniffImage } from './images.ts';
import type { PdfMakeLoader } from './makepdf.ts';
import { extractPdfText, isPdf } from './pdf.ts';
import { parseWav, WavError } from './wav.ts';
import type { PdfLoader } from './pdf.ts';
import { isDate, type PlanData } from './plan.ts';
import { validateProfile } from './profile.ts';
import { parseExperimentLog, summarizeExperiments } from './experiments.ts';
import { parseNights } from './nights.ts';
import { parseEveningRequest, runEvening } from './evening.ts';
import { speakableText, synthesize, toBase64, ttsConfigFromEnv } from './tts.ts';
import { historyText, judgeTheories, NIGHT, runCritic, runStudy, usedLines, type StoredShift } from './nightshift.ts';
import { STARTING_BELIEFS } from './theories.ts';
import { angleResults } from './experiments.ts';
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

  // Muse Spark, or the first model available (web search, photos and pictures need Muse Spark itself).
  const spark = (models: MuseConfig[]): MuseConfig => models.find((m) => m.label === 'spark') ?? models[0];

  try {
    const limits = {
      dailyLimit: limitFromEnv(env.get('AGENT_DAILY_LIMIT'), DEFAULT_DAILY_LIMIT),
      globalLimit: limitFromEnv(env.get('AGENT_GLOBAL_DAILY_LIMIT'), DEFAULT_GLOBAL_LIMIT),
    };
    switch (body.action) {
      case 'chat': {
        const models = modelsFor('chat', (n) => env.get(n));
        const result = await runChat(parseChatRequest(body), {
          cfg: spark(models),
          models,
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
        const models = modelsFor('nudge', (n) => env.get(n));
        const result = await runNudge(parseNudgeRequest(body), {
          cfg: spark(models),
          models,
          store,
          ...limits,
          fetchImpl: env.fetchImpl,
        });
        return json(result);
      }
      case 'nightshift': {
        // Lify's night shift (see nightshift.ts): "study" writes the theories and tomorrow's nudge bank, "critic" cuts the
        // weak lines, "get" returns the newest shift with how each angle did.
        const step = body.step ?? 'get';
        if (step === 'get') {
          const latest = await store.getNightShift();
          const events = await store.getExperiments(addDays(new Date().toISOString().slice(0, 10), -NIGHT.historyDays));
          // the verdicts are recomputed on every read: always the newest results, always computed by code
          if (latest) latest.shift.theories = judgeTheories(latest.shift.theories.filter((t) => t.when && t.test), events);
          return json({ shift: latest, angles: angleResults(events), beliefs: STARTING_BELIEFS });
        }
        const day = body.day;
        if (!isDate(day)) throw new BadRequest('bad_date');
        const models = modelsFor('nightshift', (n) => env.get(n));
        const deps = { models, fetchImpl: env.fetchImpl };
        if (step === 'study') {
          const previous = await store.getNightShift();
          const fresh = previous?.day === day && previous.updated_at && Date.now() - Date.parse(previous.updated_at) < NIGHT.minHoursBetween * 3600_000;
          if (fresh && body.test !== true) return json({ shift: previous, skipped: 'recent' });
          await spendQuota(store, limits);
          const [profile, strategy, nights, events] = await Promise.all([
            store.getProfile(),
            store.getStrategy(),
            store.getNights(day),
            store.getExperiments(addDays(day, -NIGHT.historyDays)),
          ]);
          const plans: { date: string; data: PlanData }[] = [];
          for (const d of [addDays(day, -2), addDays(day, -1), day]) {
            const p = await store.getPlan(d);
            if (p) plans.push({ date: d, data: p.data });
          }
          const recent = events.slice(-NIGHT.maxEvents);
          const history = historyText({ profile, strategy, nights, plans, events: recent, previous });
          const { shift, model } = await runStudy(history, day, usedLines(recent, previous), profile.name, deps, recent);
          const stored: StoredShift = { day, status: 'draft', shift, model };
          await store.saveNightShift(stored);
          return json({ shift: stored });
        }
        if (step === 'critic') {
          const draft = await store.getNightShift(day);
          if (!draft) throw new BadRequest('no_draft');
          if (draft.status === 'final' && body.test !== true) return json({ shift: draft });
          await spendQuota(store, limits);
          let shift = draft.shift;
          try {
            shift = await runCritic(draft.shift, await store.getProfile(), deps);
          } catch (e) {
            if (!(e instanceof MuseError)) throw e;
            shift = { ...draft.shift, critic: { cut: 0, reasons: ['the critic could not be reached: the draft is used as it is'] } };
          }
          const stored: StoredShift = { ...draft, status: 'final', shift };
          await store.saveNightShift(stored);
          return json({ shift: stored });
        }
        throw new BadRequest('bad_step');
      }
      case 'speak': {
        // Lify's voice (Orpheus on Baseten). Not configured: the phone uses its own voice, no error worth showing.
        const cfg = ttsConfigFromEnv((n) => env.get(n));
        if (!cfg) return json({ error: { code: 'tts_not_configured' } }, 501);
        const text = typeof body.text === 'string' ? speakableText(body.text) : '';
        if (!text) throw new BadRequest('bad_text');
        const wav = await synthesize(cfg, text, env.fetchImpl ?? fetch);
        return json({ audio: toBase64(wav), format: 'wav', voice: cfg.voice });
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
        // "days" (minutes per app per day) and, optionally, "nights" (phone-down times)
        const nights = parseNights(body.nights);
        const rows = body.days === undefined && nights.length > 0 ? [] : parseUsage(body);
        await store.upsertUsage(rows);
        await store.upsertNights(nights);
        return json({ saved: rows.length, ...(nights.length ? { nights: nights.length } : {}) });
      }
      case 'evening': {
        const models = modelsFor('evening', (n) => env.get(n));
        const result = await runEvening(parseEveningRequest(body), {
          cfg: spark(models),
          models,
          store,
          ...limits,
          fetchImpl: env.fetchImpl,
        });
        return json(result);
      }
      case 'plan': {
        if (!isDate(body.date)) throw new BadRequest('bad_date');
        return json({ plan: await store.getPlan(body.date) });
      }
      case 'strategy': {
        // The newest version and the ones before it (newest first), so the app can show how the strategy changed.
        const history = await store.listStrategies(30);
        return json({ strategy: history[0] ?? null, history });
      }
      case 'experiments': {
        // The phone sends finished experiment results ("log"); the app reads the totals (no "log").
        if (body.log !== undefined) await store.saveExperiments(parseExperimentLog(body.log));
        if (body.today !== undefined && !isDate(body.today)) throw new BadRequest('bad_date');
        const days = body.days === undefined ? 14 : body.days;
        if (typeof days !== 'number' || !Number.isInteger(days) || days < 1 || days > 30) throw new BadRequest('bad_days');
        const today = isDate(body.today) ? body.today : new Date().toISOString().slice(0, 10);
        const since = new Date(`${today}T00:00:00Z`);
        since.setUTCDate(since.getUTCDate() - (days - 1));
        return json({ results: summarizeExperiments(await store.getExperiments(since.toISOString().slice(0, 10))) });
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

/** YYYY-MM-DD plus [n] days. */
function addDays(day: string, n: number): string {
  const d = new Date(`${day}T00:00:00Z`);
  d.setUTCDate(d.getUTCDate() + n);
  return d.toISOString().slice(0, 10);
}
