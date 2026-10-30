// When the phone went quiet each night ("phone-down") and when it was first picked up again, measured on the phone from
// its own usage events (the longest overnight gap). This is phone use, not sleep: the app and the agent call it
// "phone-down time" and never make sleep or health claims about it.

import { isDate } from './plan.ts';
import { toMinutes } from './profile.ts';
import { BadRequest } from './loop.ts';

export interface PhoneNight {
  night: string; // the evening's date, YYYY-MM-DD (a 02:30 phone-down belongs to the evening before)
  down: string; // HH:MM, local
  up?: string; // HH:MM, local, the first pick-up after
}

const HHMM = /^([01]\d|2[0-3]):[0-5]\d$/;
export const MAX_NIGHTS = 14;

export function parseNights(raw: unknown): PhoneNight[] {
  if (raw === undefined) return [];
  if (!Array.isArray(raw) || raw.length > MAX_NIGHTS) throw new BadRequest('bad_nights');
  const seen = new Set<string>();
  return raw.map((r: Record<string, unknown>) => {
    if (!isDate(r?.night) || seen.has(r.night as string) || typeof r.down !== 'string' || !HHMM.test(r.down)) throw new BadRequest('bad_nights');
    if (r.up !== undefined && (typeof r.up !== 'string' || !HHMM.test(r.up))) throw new BadRequest('bad_nights');
    seen.add(r.night as string);
    return { night: r.night as string, down: r.down, ...(r.up !== undefined ? { up: r.up as string } : {}) };
  });
}

/** Minutes after the evening's 18:00, so 23:30 < 01:10 < 03:00 compare the way a night runs. */
export function nightMinutes(hhmm: string): number {
  return (toMinutes(hhmm) - 18 * 60 + 1440) % 1440;
}

/** How many minutes later than [sleep] the phone went down (negative = earlier). */
export function lateBy(down: string, sleep: string): number {
  return nightMinutes(down) - nightMinutes(sleep);
}

/** The facts the agent gets: last night, and the last nights' phone-down times, newest first. */
export function nightFacts(nights: PhoneNight[], sleep?: string): string[] {
  if (nights.length === 0) return [];
  const sorted = [...nights].sort((a, b) => b.night.localeCompare(a.night));
  const last = sorted[0];
  const lines = [`last_night_phone_down: ${last.down} (night of ${last.night})`];
  if (sleep) lines.push(`last_night_minutes_after_known_sleep: ${lateBy(last.down, sleep)}`);
  lines.push(`recent_phone_down_times: ${JSON.stringify(sorted.slice(0, 7).map((n) => n.down))}`);
  return lines;
}
