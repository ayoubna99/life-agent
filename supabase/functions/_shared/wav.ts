// Muse Voice Transcribe only accepts WAV: one channel, 16-bit PCM, 16 kHz or 24 kHz, up to 10 minutes.
// The phone records raw PCM and wraps it in a WAV header; we check it here before spending a request.

export class WavError extends Error {}

export const WAV = { maxMs: 10 * 60 * 1000, rates: [16000, 24000] as const };

export function parseWav(b: Uint8Array): { sampleRate: number; durationMs: number } {
  const text = (at: number, n: number) => String.fromCharCode(...b.subarray(at, at + n));
  if (b.length < 44 || text(0, 4) !== 'RIFF' || text(8, 4) !== 'WAVE') throw new WavError('not_wav');
  const v = new DataView(b.buffer, b.byteOffset, b.byteLength);
  let fmt: { format: number; channels: number; rate: number; bits: number } | undefined;
  let dataBytes = -1;
  for (let at = 12; at + 8 <= b.length; ) {
    const id = text(at, 4);
    const size = v.getUint32(at + 4, true);
    if (id === 'fmt ' && at + 8 + 16 <= b.length) {
      fmt = { format: v.getUint16(at + 8, true), channels: v.getUint16(at + 10, true), rate: v.getUint32(at + 12, true), bits: v.getUint16(at + 22, true) };
    } else if (id === 'data') {
      // A recorder that was cut off may leave the size at 0 or too big: use what is really there.
      dataBytes = size === 0 || at + 8 + size > b.length ? b.length - (at + 8) : size;
      break;
    }
    at += 8 + size + (size % 2);
  }
  if (!fmt || dataBytes < 0) throw new WavError('not_wav');
  if (fmt.format !== 1 || fmt.bits !== 16) throw new WavError('not_16bit_pcm');
  if (fmt.channels !== 1) throw new WavError('not_mono');
  if (!(WAV.rates as readonly number[]).includes(fmt.rate)) throw new WavError('bad_sample_rate');
  const durationMs = Math.round((dataBytes / 2 / fmt.rate) * 1000);
  if (durationMs === 0) throw new WavError('empty_audio');
  if (durationMs > WAV.maxMs) throw new WavError('too_long');
  return { sampleRate: fmt.rate, durationMs };
}
