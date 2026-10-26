// Checks the links the model suggests before they reach the user. A dead or made-up link is dropped.
// The server fetches model-chosen URLs, so only plain public https hosts are allowed (no SSRF).

export function isSafePublicUrl(raw: string): URL | null {
  let u: URL;
  try {
    u = new URL(raw);
  } catch {
    return null;
  }
  if (u.protocol !== 'https:' || u.username || u.password || (u.port && u.port !== '443')) return null;
  const h = u.hostname.toLowerCase();
  if (!h.includes('.') || h === 'localhost' || h.endsWith('.localhost') || h.endsWith('.local') || h.endsWith('.internal')) return null;
  if (/^\d+(\.\d+){3}$/.test(h) || h.includes(':') || h.startsWith('[')) return null; // IP literals
  return u;
}

/** Statuses that mean "the page exists but will not let a robot in": keep the link. */
const EXISTS_BUT_GUARDED = new Set([401, 403, 405, 429]);

async function exists(u: URL, fetchImpl: typeof fetch, timeoutMs: number): Promise<boolean> {
  for (const method of ['HEAD', 'GET']) {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), timeoutMs);
    try {
      const res = await fetchImpl(u.toString(), {
        method,
        redirect: 'manual',
        signal: controller.signal,
        headers: { 'User-Agent': 'LifeLinkCheck/1.0', ...(method === 'GET' ? { Range: 'bytes=0-0' } : {}) },
      });
      if (res.status < 400) return true;
      if (method === 'HEAD' && res.status === 405) continue; // some sites refuse HEAD
      return EXISTS_BUT_GUARDED.has(res.status);
    } catch {
      return false;
    } finally {
      clearTimeout(timer);
    }
  }
  return false;
}

export async function verifyLinks(
  urls: string[],
  opts: { fetchImpl?: typeof fetch; timeoutMs?: number; trustedPrefix?: string } = {},
): Promise<{ ok: string[]; dropped: string[] }> {
  const fetchImpl = opts.fetchImpl ?? fetch;
  const results = await Promise.all(
    urls.map(async (raw) => {
      // Links we made ourselves (signed storage URLs) need no check.
      if (opts.trustedPrefix && raw.startsWith(opts.trustedPrefix)) return { raw, ok: true };
      const u = isSafePublicUrl(raw);
      return { raw, ok: u !== null && (await exists(u, fetchImpl, opts.timeoutMs ?? 4000)) };
    }),
  );
  return { ok: results.filter((r) => r.ok).map((r) => r.raw), dropped: results.filter((r) => !r.ok).map((r) => r.raw) };
}
