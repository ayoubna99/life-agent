// The settings the user gives in the app (not in the chat). The agent receives them as known facts.

export interface Profile {
  wake?: string; // HH:MM
  sleep?: string; // HH:MM
  apps: string[]; // the apps that pull them off track
  focus?: string; // what they most want to spend time on
  name?: string; // first name, so Lify can greet them
}

const HHMM = /^([01]\d|2[0-3]):[0-5]\d$/;

export const toMinutes = (hhmm: string): number => Number(hhmm.slice(0, 2)) * 60 + Number(hhmm.slice(3));
export const toHHMM = (m: number): string => `${String(Math.floor(m / 60)).padStart(2, '0')}:${String(m % 60).padStart(2, '0')}`;

/** Only the fields that were sent are returned, so saving one setting never wipes another. */
export function validateProfile(raw: unknown): { ok: true; patch: Partial<Profile> } | { ok: false; error: string } {
  const p = raw as Record<string, unknown> | null;
  if (!p || typeof p !== 'object' || Array.isArray(p)) return { ok: false, error: 'bad_profile' };
  const patch: Partial<Profile> = {};
  for (const key of ['wake', 'sleep'] as const) {
    if (p[key] !== undefined) {
      if (typeof p[key] !== 'string' || !HHMM.test(p[key] as string)) return { ok: false, error: `bad_${key}` };
      patch[key] = p[key] as string;
    }
  }
  if (p.apps !== undefined) {
    if (!Array.isArray(p.apps) || p.apps.length > 8) return { ok: false, error: 'bad_apps' };
    const seen = new Set<string>();
    const apps: string[] = [];
    for (const a of p.apps) {
      const name = typeof a === 'string' ? a.trim() : '';
      if (!name || name.length > 60) return { ok: false, error: 'bad_apps' };
      if (!seen.has(name.toLowerCase())) {
        seen.add(name.toLowerCase());
        apps.push(name);
      }
    }
    patch.apps = apps;
  }
  if (p.focus !== undefined) {
    if (typeof p.focus !== 'string' || p.focus.length > 200) return { ok: false, error: 'bad_focus' };
    patch.focus = p.focus.trim();
  }
  if (p.name !== undefined) {
    if (typeof p.name !== 'string' || p.name.trim().length > 40) return { ok: false, error: 'bad_name' };
    patch.name = p.name.trim();
  }
  if (Object.keys(patch).length === 0) return { ok: false, error: 'bad_profile' };
  return { ok: true, patch };
}
