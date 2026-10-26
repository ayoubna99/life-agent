// Speech to text with Meta's Muse Voice Transcribe (file endpoint). One short recording in, its text out.
// Spec: POST {base}/asr/transcribe, multipart: a JSON part "request" and the WAV part "audio",
// Authorization: Bearer <key>. Answer: {"sessionId","transcript","audioDurationMs","turns":[...]}.

import { MuseError } from './muse.ts';

export const ASR_MODEL = 'muse-voice-transcribe-1.0';

/** The 25 languages the model lists. languageBias takes these names. */
export const ASR_LANGUAGES = [
  'Arabic', 'Bengali', 'Dutch', 'English', 'French', 'German', 'Hebrew', 'Hindi', 'Indonesian', 'Italian', 'Japanese', 'Kannada', 'Korean',
  'Malay', 'Mandarin Chinese', 'Marathi', 'Polish', 'Portuguese', 'Spanish', 'Tagalog', 'Tamil', 'Telugu', 'Thai', 'Turkish', 'Vietnamese',
];

export interface AsrConfig {
  baseUrl: string;
  apiKey: string;
  model: string;
  timeoutMs?: number;
}

export async function transcribeWav(
  cfg: AsrConfig,
  wav: Uint8Array,
  opts: { languages?: string[]; keywords?: string[]; sessionId?: string } = {},
  fetchImpl: typeof fetch = fetch,
): Promise<{ text: string; durationMs: number }> {
  const request: Record<string, unknown> = { mode: 'PUSH_TO_TALK', model: cfg.model, audioEncoding: 'WAV' };
  if (opts.languages?.length) request.languageBias = opts.languages;
  if (opts.keywords?.length) request.keywords = opts.keywords;

  const form = new FormData();
  form.append('request', new Blob([JSON.stringify(request)], { type: 'application/json' }));
  form.append('audio', new Blob([wav], { type: 'audio/wav' }), 'audio.wav');

  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), cfg.timeoutMs ?? 60_000);
  let res: Response;
  try {
    const query = opts.sessionId ? `?sessionId=${encodeURIComponent(opts.sessionId)}` : '';
    res = await fetchImpl(`${cfg.baseUrl.replace(/\/+$/, '')}/asr/transcribe${query}`, {
      method: 'POST',
      headers: { Authorization: `Bearer ${cfg.apiKey}` }, // no Content-Type: fetch adds the multipart boundary
      body: form,
      signal: controller.signal,
    });
  } catch (e) {
    throw new MuseError((e as Error)?.name === 'AbortError' ? 'timeout' : 'network');
  } finally {
    clearTimeout(timer);
  }
  if (!res.ok) throw new MuseError('upstream_status', res.status);

  let body: { transcript?: unknown; audioDurationMs?: unknown };
  try {
    body = await res.json();
  } catch {
    throw new MuseError('bad_output');
  }
  if (typeof body?.transcript !== 'string') throw new MuseError('bad_output');
  return { text: body.transcript.trim(), durationMs: typeof body.audioDurationMs === 'number' ? body.audioDurationMs : 0 };
}

/** Names from the phone ("french", "English") to the model's spelling; anything unknown is dropped. */
export function languageBias(names: unknown): string[] {
  if (!Array.isArray(names)) return [];
  const out: string[] = [];
  for (const n of names.slice(0, 4)) {
    const hit = typeof n === 'string' ? ASR_LANGUAGES.find((l) => l.toLowerCase() === n.trim().toLowerCase()) : undefined;
    if (hit && !out.includes(hit)) out.push(hit);
  }
  return out;
}
