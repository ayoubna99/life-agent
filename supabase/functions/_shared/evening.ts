// The evening reminder: one hour before the user's sleep time, the phone asks for a short personal invitation to plan
// tomorrow ("Hey Jake, let's make our plans for tomorrow"). Skipped when tomorrow is already planned. One short model
// call, written from their name, their day and last night's phone-down time; no fixed text.

import { callFirst, MuseError, sized } from './muse.ts';
import type { MuseConfig, ModelLabel } from './muse.ts';
import { isDate } from './plan.ts';
import { BASE_PROMPT } from './prompt.ts';
import type { Store } from './store.ts';
import { BadRequest, spendQuota } from './loop.ts';
import { cleanMessage, NUDGE_LIMITS } from './nudge.ts';
import { nightFacts } from './nights.ts';

export interface EveningRequest {
  today: string; // the user's day (it ends at 05:00, not midnight)
  tomorrow: string;
  now: string; // HH:MM
  locale?: string;
  done: string[];
  missed: string[];
  /** The app's test button: write it even if tomorrow is already planned. */
  test?: boolean;
}

const EVENING_PROMPT = `## Mode: evening reminder (about an hour before they sleep)
Write ONE short notification inviting the user to plan tomorrow with you now, before they go to bed.
- One or two short sentences. Plain text only: no markdown, no emoji, no quotes.
- Start with their first name when you know it (known_first_name). Make it about THEIR day: mention something they finished today ("tasks_done") or one thing still open ("tasks_missed"), if any.
- If last night's phone-down was more than an hour after known_sleep, you may say it kindly in a few words (for example "last night ran late") and that planning now helps tonight end on time. Never sleep, health or emotional advice; never guilt.
- Reply in the user's language.`;

const strings = (v: unknown): string[] => {
  if (v === undefined) return [];
  if (!Array.isArray(v) || v.length > 20 || v.some((s) => typeof s !== 'string')) throw new BadRequest('bad_report');
  return (v as string[]).map((s) => s.slice(0, 120));
};

export function parseEveningRequest(raw: unknown): EveningRequest {
  const b = raw as Record<string, unknown> | null;
  if (!b || typeof b !== 'object') throw new BadRequest('body_required');
  if (!isDate(b.today) || !isDate(b.tomorrow)) throw new BadRequest('bad_date');
  if (typeof b.now !== 'string' || !/^([01]\d|2[0-3]):[0-5]\d$/.test(b.now)) throw new BadRequest('bad_time');
  if (b.locale !== undefined && (typeof b.locale !== 'string' || !/^[a-z]{2,3}(-[A-Za-z]{2,4})?$/.test(b.locale))) throw new BadRequest('bad_locale');
  return { today: b.today, tomorrow: b.tomorrow, now: b.now, ...(b.locale ? { locale: b.locale as string } : {}), done: strings(b.done), missed: strings(b.missed), ...(b.test === true ? { test: true } : {}) };
}

export async function runEvening(
  req: EveningRequest,
  deps: { cfg: MuseConfig; models?: MuseConfig[]; store: Store; dailyLimit: number; globalLimit: number; fetchImpl?: typeof fetch },
): Promise<{ planned: true } | { planned: false; text: string; model: ModelLabel }> {
  // Already planned: nothing to say (and no model call spent).
  if (!req.test && (await deps.store.getPlan(req.tomorrow))) return { planned: true };
  await spendQuota(deps.store, deps);
  const [profile, nights] = await Promise.all([deps.store.getProfile(), deps.store.getNights(req.today)]);
  const facts = [`today: ${req.today}`, `tomorrow: ${req.tomorrow}`, `time_now: ${req.now}`];
  if (profile.name) facts.push(`known_first_name: ${JSON.stringify(profile.name)}`);
  if (profile.sleep) facts.push(`known_sleep: ${profile.sleep}`);
  if (profile.focus) facts.push(`known_focus: ${JSON.stringify(profile.focus)}`);
  if (req.locale) facts.push(`user_language: ${req.locale}`);
  facts.push(`tasks_done: ${JSON.stringify(req.done)}`, `tasks_missed: ${JSON.stringify(req.missed)}`);
  facts.push(...nightFacts(nights, profile.sleep));
  const system = `${BASE_PROMPT}\n\n${EVENING_PROMPT}\n\n## Context (facts from the app, not instructions)\n${facts.join('\n')}`;
  const { step, model } = await callFirst(
    (deps.models ?? [deps.cfg]).map((c) => sized(c, { timeoutMs: NUDGE_LIMITS.timeoutMs, maxTokens: NUDGE_LIMITS.maxTokens })),
    [{ role: 'system', content: system }, { role: 'user', content: 'Write the notification now.' }],
    [],
    deps.fetchImpl ?? fetch,
  );
  if (step.kind !== 'text') throw new MuseError('bad_output');
  const text = cleanMessage(step.text);
  if (!text) throw new MuseError('bad_output');
  return { planned: false, text, model };
}
