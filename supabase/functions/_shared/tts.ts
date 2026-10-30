// Lify's voice: Orpheus TTS (Canopy Labs, built on Llama) deployed on Baseten. The phone's own voice is the fallback.
//
// The deployment is made once from Baseten's model library; its predict URL goes in TTS_URL. The key is TTS_API_KEY,
// or the Baseten key already used for Muse Spark Open (OPEN_API_KEY).

import { MuseError } from './muse.ts';

export const TTS = {
  maxChars: 600,
  maxTokens: 4096,
  timeoutMs: 40_000,
  sampleRate: 24_000,
  /** Orpheus's English voices; "tara" sounds the most natural. */
  voices: ['tara', 'leah', 'jess', 'leo', 'dan', 'mia', 'zac', 'zoe'] as const,
  defaultVoice: 'tara',
};

export interface TtsConfig {
  url: string;
  apiKey: string;
  voice: string;
}

export function ttsConfigFromEnv(get: (name: string) => string | undefined): TtsConfig | null {
  const url = get('TTS_URL')?.trim();
  const apiKey = (get('TTS_API_KEY') ?? get('OPEN_API_KEY'))?.trim();
  if (!url || !apiKey) return null;
  const voice = get('TTS_VOICE')?.trim().toLowerCase();
  return { url, apiKey, voice: voice && (TTS.voices as readonly string[]).includes(voice) ? voice : TTS.defaultVoice };
}

/**
 * What is read aloud: no markdown, links or emoji; Orpheus's sound tags (<laugh>, <chuckle>, <sigh>) are kept, other
 * angle brackets are not. Cut at a sentence end within [TTS.maxChars].
 */
export function speakableText(raw: string): string {
  let t = raw
    .replace(/https?:\/\/\S+/g, '')
    .replace(/^\s*>\s?/gm, '')
    .replace(/[*_`#|~]+/g, '')
    .replace(/\[([^\]]*)\]\([^)]*\)/g, '$1')
    .replace(/<(?!\/?(laugh|chuckle|sigh|gasp|groan|yawn)>)[^>]*>/gi, '')
    .replace(/[\u{1F000}-\u{1FAFF}\u{2600}-\u{27BF}\u{FE0F}]/gu, '')
    .replace(/\s+/g, ' ')
    .trim();
  if (t.length > TTS.maxChars) {
    const cut = t.slice(0, TTS.maxChars);
    const end = Math.max(cut.lastIndexOf('. '), cut.lastIndexOf('! '), cut.lastIndexOf('? '));
    t = end > 100 ? cut.slice(0, end + 1) : cut;
  }
  return t;
}

/** A WAV header around raw 16-bit mono PCM (what Orpheus streams back). */
export function pcmToWav(pcm: Uint8Array, sampleRate = TTS.sampleRate): Uint8Array {
  const out = new Uint8Array(44 + pcm.length);
  const v = new DataView(out.buffer);
  const ascii = (at: number, s: string) => [...s].forEach((c, i) => v.setUint8(at + i, c.charCodeAt(0)));
  ascii(0, 'RIFF');
  v.setUint32(4, 36 + pcm.length, true);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  v.setUint32(16, 16, true);
  v.setUint16(20, 1, true); // PCM
  v.setUint16(22, 1, true); // mono
  v.setUint32(24, sampleRate, true);
  v.setUint32(28, sampleRate * 2, true);
  v.setUint16(32, 2, true);
  v.setUint16(34, 16, true);
  ascii(36, 'data');
  v.setUint32(40, pcm.length, true);
  out.set(pcm, 44);
  return out;
}

const isWav = (b: Uint8Array) => b.length > 12 && String.fromCharCode(...b.slice(0, 4)) === 'RIFF' && String.fromCharCode(...b.slice(8, 12)) === 'WAVE';

/** Speaks [text] with Orpheus; returns a WAV file. Errors are MuseErrors (timeout, network, upstream_status, bad_output). */
export async function synthesize(cfg: TtsConfig, text: string, fetchImpl: typeof fetch = fetch): Promise<Uint8Array> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), TTS.timeoutMs);
  try {
    let res: Response;
    try {
      res = await fetchImpl(cfg.url, {
        method: 'POST',
        headers: { Authorization: `Api-Key ${cfg.apiKey}`, 'Content-Type': 'application/json' },
        // "prompt" is what the library deployment reads; "text" for deployments that name it that way
        body: JSON.stringify({ prompt: text, text, voice: cfg.voice, max_tokens: TTS.maxTokens }),
        signal: controller.signal,
      });
    } catch (e) {
      throw new MuseError(controller.signal.aborted ? 'timeout' : 'network', undefined, `tts ${(e as Error).name}`);
    }
    if (!res.ok) throw new MuseError('upstream_status', res.status, 'tts');
    const bytes = new Uint8Array(await res.arrayBuffer());
    if (bytes.length < 1000) throw new MuseError('bad_output', undefined, 'tts no audio');
    return isWav(bytes) ? bytes : pcmToWav(bytes.length % 2 === 0 ? bytes : bytes.slice(0, -1));
  } finally {
    clearTimeout(timer);
  }
}

export function toBase64(bytes: Uint8Array): string {
  let s = '';
  for (let i = 0; i < bytes.length; i += 0x8000) s += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  return btoa(s);
}
