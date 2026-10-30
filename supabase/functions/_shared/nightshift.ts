// The night shift: Lify as a scientist studying one person.
//
// Every night Muse Spark Open reads the user's WHOLE history at once (its 1M-token context, so no retrieval): every
// nudge it ever sent with what the user did next, their nights, plans and settings, and its own theories from the
// nights before. It thinks hard (reasoning_effort "medium") and
//   1. keeps, revises or rejects each theory against the new results, and proposes new ones,
//   2. designs tomorrow's experiment: a NUDGE BANK of short lines grouped by ANGLE (the idea behind them), more lines for
//      the angles that work, a few new angles to test,
// then a second pass (the CRITIC, "the user's inner skeptic", reasoning "low") cuts every line that is generic, long,
// preachy or repeated. During the day the phone picks from the bank with Thompson sampling over ANGLES (so a winning
// idea keeps coming back in NEW words, never the same sentence twice) and the card shows at once, with no model call.
// The results come back as experiments, and the next night the theories are checked against them.
//
// The model only proposes; code validates everything (lengths, no numbers about minutes, no repeats, ids).

import { ARMS, BANDS, angleResults, type Arm, type Band, type ExperimentEvent } from './experiments.ts';
import { callFirst, MuseError, sized, withEffort, type MuseConfig } from './muse.ts';
import type { PhoneNight } from './nights.ts';
import type { PlanData } from './plan.ts';
import type { Profile } from './profile.ts';
import type { Strategy } from './strategy.ts';
import { strategyForPrompt } from './strategy.ts';

export interface Theory {
  id: string;
  statement: string;
  angle: string | null;
  confidence: number; // 0..1
  status: 'testing' | 'kept' | 'rejected';
  evidence: string;
}

export interface BankLine {
  id: string;
  text: string;
}

export interface Angle {
  id: string;
  name: string;
  style: Arm;
  bands: Band[];
  apps: string[]; // empty: any app
  lines: BankLine[];
}

export interface Shift {
  theories: Theory[];
  angles: Angle[];
  notes: string;
  /** A short excerpt of the model's own visible reasoning (the lab notebook shows "how Lify thought about it"). */
  thinking: string | null;
  critic: { cut: number; reasons: string[] } | null;
}

export interface StoredShift {
  day: string;
  status: 'draft' | 'final';
  shift: Shift;
  model: string;
  updated_at?: string;
}

export const NIGHT = {
  maxTheories: 8,
  maxAngles: 8,
  maxLinesPerAngle: 6,
  maxLineChars: 90,
  maxLineWords: 14,
  historyDays: 30,
  maxEvents: 600,
  studyTokens: 16_000,
  studyTimeoutMs: 110_000,
  criticTokens: 8_000,
  criticTimeoutMs: 40_000,
  minHoursBetween: 6,
  thinkingChars: 700,
};

const SLUG = /^[a-z0-9_-]{1,40}$/;
const slug = (s: unknown, fallback: string): string => {
  const v = typeof s === 'string' ? s.toLowerCase().replace(/[^a-z0-9_-]+/g, '_').replace(/^_+|_+$/g, '').slice(0, 40) : '';
  return SLUG.test(v) ? v : fallback;
};
const str = (v: unknown, max: number): string => (typeof v === 'string' ? v.replace(/\s+/g, ' ').trim().slice(0, max) : '');
const norm = (s: string) => s.toLowerCase().replace(/[^a-z0-9]+/g, ' ').trim();

/** Why a bank line is refused, or null when it is fine. [used] holds normalised lines already sent or already in the bank. */
export function lineProblem(text: string, used: Set<string>, name?: string): string | null {
  if (!text) return 'empty';
  if (text.length > NIGHT.maxLineChars) return 'too long';
  if (text.split(/\s+/).length > NIGHT.maxLineWords) return 'too many words';
  if (/\n/.test(text)) return 'more than one line';
  if (/\b\d+\s*(m|min|mins|minutes?|h|hrs?|hours?)\b/i.test(text)) return 'repeats the numbers (the card title has them)';
  if (/\b(you'?re at|past your|your limit|limit of)\b/i.test(text)) return 'reads like a meter';
  if (/\b(addict\w*|anxiety|depress\w*|mental health|therapy|diagnos\w*)\b/i.test(text)) return 'health language';
  if (name && new RegExp(`^${name.replace(/[^\w]/g, '')}\\s*,\\s*you`, 'i').test(text)) return 'the old template opening';
  if (used.has(norm(text))) return 'already used';
  return null;
}

/** The model's JSON, read leniently (code fences, text around it). */
export function readJson(text: string): Record<string, unknown> {
  const t = text.replace(/```(?:json)?/gi, '');
  const a = t.indexOf('{');
  const b = t.lastIndexOf('}');
  if (a < 0 || b <= a) throw new MuseError('bad_output');
  try {
    const v = JSON.parse(t.slice(a, b + 1));
    if (typeof v !== 'object' || v === null || Array.isArray(v)) throw new Error();
    return v as Record<string, unknown>;
  } catch {
    throw new MuseError('bad_output');
  }
}

/** Code checks what the model proposed: shapes, sizes, every line against [lineProblem]. Lines get stable ids. */
export function validateShift(raw: Record<string, unknown>, day: string, used: Set<string>, name?: string): Shift {
  const theories: Theory[] = [];
  for (const [i, t] of (Array.isArray(raw.theories) ? raw.theories : []).slice(0, NIGHT.maxTheories).entries()) {
    const r = t as Record<string, unknown>;
    const statement = str(r?.statement, 200);
    if (!statement) continue;
    const c = typeof r.confidence === 'number' && Number.isFinite(r.confidence) ? Math.min(1, Math.max(0, r.confidence)) : 0.5;
    const status = r.status === 'kept' || r.status === 'rejected' ? r.status : 'testing';
    theories.push({ id: slug(r.id, `t${i + 1}`), statement, angle: typeof r.angle === 'string' ? slug(r.angle, '') || null : null, confidence: Math.round(c * 100) / 100, status, evidence: str(r.evidence, 200) });
  }
  const seen = new Set(used);
  const angles: Angle[] = [];
  const ids = new Set<string>();
  const stamp = day.replace(/-/g, '');
  for (const [i, a] of (Array.isArray(raw.angles) ? raw.angles : []).entries()) {
    if (angles.length >= NIGHT.maxAngles) break;
    const r = a as Record<string, unknown>;
    let id = slug(r?.id, `a${i + 1}`);
    while (ids.has(id)) id = `${id.slice(0, 37)}_${i}`;
    const style: Arm = ARMS.includes(r?.style as Arm) ? (r.style as Arm) : 'goal';
    const bands = (Array.isArray(r?.bands) ? r.bands : []).filter((b): b is Band => BANDS.includes(b as Band));
    const apps = (Array.isArray(r?.apps) ? r.apps : []).map((x) => str(x, 40)).filter(Boolean).slice(0, 6);
    const lines: BankLine[] = [];
    for (const l of Array.isArray(r?.lines) ? r.lines : []) {
      if (lines.length >= NIGHT.maxLinesPerAngle) break;
      const text = str(typeof l === 'string' ? l : (l as Record<string, unknown>)?.text, 200);
      if (lineProblem(text, seen, name)) continue;
      seen.add(norm(text));
      lines.push({ id: `${id}_${stamp}_${lines.length + 1}`, text });
    }
    if (lines.length === 0) continue;
    ids.add(id);
    angles.push({ id, name: str(r.name, 60) || id.replace(/_/g, ' '), style, bands: bands.length ? [...new Set(bands)] : [...BANDS], apps, lines });
  }
  if (angles.length === 0) throw new MuseError('bad_output');
  return { theories, angles, notes: str(raw.notes, 400), thinking: null, critic: null };
}

const ago = (e: ExperimentEvent) => (e.left ? `LEFT after ${e.seconds_after}s` : 'stayed');

/** Everything Lify knows, as compact lines: the model reads all of it at once (no retrieval, no summary in between). */
export function historyText(h: {
  profile: Profile;
  strategy: Strategy | null;
  nights: PhoneNight[];
  plans: { date: string; data: PlanData }[];
  events: ExperimentEvent[];
  previous: StoredShift | null;
}): string {
  const p = h.profile;
  const out: string[] = [];
  out.push('# Person');
  out.push(`first_name: ${p.name ?? 'unknown'}; wake: ${p.wake ?? '?'}; sleep: ${p.sleep ?? '?'}; focus: ${p.focus ?? 'not said'}; apps that pull them away: ${p.apps.join(', ') || 'none'}`);
  out.push(`strategy: ${strategyForPrompt(h.strategy)}`);
  out.push('# Nights (phone down / picked up; phone use, not sleep)');
  for (const n of h.nights) out.push(`${n.night}: ${n.down} / ${n.up ?? '?'}`);
  out.push('# Plans');
  for (const pl of h.plans) out.push(`${pl.date}: ${pl.data.tasks.map((t) => `${t.start_time ?? '--:--'} ${t.title} (${t.minutes} min)`).join('; ') || 'no tasks'}`);
  out.push(`# Every nudge, oldest first (${h.events.length}): day time band app trigger angle style "words" -> what they did`);
  for (const e of h.events) {
    out.push(`${e.day} ${e.time} ${e.context ?? '-'} ${e.app} ${e.reason} ${e.angle ?? '-'} ${e.arm} "${(e.message ?? '').replace(/"/g, "'")}" -> ${ago(e)}${e.pulled ? ' (tapped Pull me out)' : ''}`);
  }
  const stats = angleResults(h.events);
  out.push('# Results per angle');
  for (const s of stats) out.push(`${s.angle}: ${s.left}/${s.tried} left, ${s.pulled} pulled out, ${s.lines} different lines`);
  out.push('# Your theories from last time');
  if (!h.previous) out.push('none: this is the first night shift');
  else for (const t of h.previous.shift.theories) out.push(`${t.id} [${t.status}, ${t.confidence}] ${t.statement} (angle ${t.angle ?? '-'}; evidence: ${t.evidence})`);
  if (h.previous) {
    out.push('# Last bank');
    for (const a of h.previous.shift.angles) out.push(`${a.id} (${a.style}; ${a.bands.join('/')}; ${a.apps.join('/') || 'any app'}): ${a.lines.map((l) => `"${l.text}"`).join(' ')}`);
  }
  return out.join('\n');
}

const STUDY_PROMPT = `You are Lify's night shift: a scientist whose only subject is this one person. Your job is to find out what actually gets them off a doomscrolling app, and to write tomorrow's experiment.

Read the whole history below. Then:
1. THEORIES. For each theory from last time decide: "kept" (the results support it), "rejected" (they contradict it) or "testing" (not enough data yet). Update its confidence (0 to 1) and give the evidence with real counts from the history ("left 4 of 6 after 22:00"). Propose new theories where the data suggests something. At most 8. A theory is about this person and nudges, never about health.
2. ANGLES. An angle is the idea behind a nudge (for example "blunt, about tomorrow's gym, at night"). Give each a short id (lowercase, underscores), a name, a style ("task" = their next important task, "cost" = what the time costs them, "goal" = their own goal or why), the time-of-day bands where it fits (morning, afternoon, evening, night) and optionally the apps. Keep the angles that work and give them MORE lines; add 1 or 2 new angles to test; drop the ones that failed. At most 8 angles.
3. LINES. For each angle up to 6 lines. Every line:
   - at most 12 words, one sentence or two very short ones;
   - no minutes, no hours, no "you're at", no limits: the card title already shows the numbers;
   - never starts with their name and a comma;
   - concrete: their real tasks, goal, plans, nights; never generic advice ("take a break", "drink water", "rest");
   - fresh: never a line from the history or the last bank; the same angle in NEW words;
   - varied: blunt, playful, curious, a dare; never preachy, never a lecture, no emoji;
   - may contain {app} for the app's name.
4. NOTES: two sentences on what you learned tonight.

Answer with JSON only:
{"theories":[{"id":"","statement":"","angle":"","confidence":0.0,"status":"testing","evidence":""}],"angles":[{"id":"","name":"","style":"goal","bands":["night"],"apps":[],"lines":[""]}],"notes":""}`;

const CRITIC_PROMPT = `You are this person's inner skeptic. Below are lines an app will show them when they are stuck scrolling. For each line ask: would this really make them close the app right now? Cut every line that is generic (could be sent to anyone), preachy, guilt-tripping, confusing, too long, or too similar to another line. Keep the sharp, personal, surprising ones. Be strict but keep at least one line per angle when it is decent.

Answer with JSON only: {"cut":[{"id":"","why":""}]}`;

export interface NightDeps {
  models: MuseConfig[];
  fetchImpl?: typeof fetch;
}

const effortFor = (models: MuseConfig[], effort: 'low' | 'medium' | 'high', want: { maxTokens: number; timeoutMs: number }) =>
  models.map((m) => sized(withEffort(m, effort), want));

/** Step 1: the study. Returns the validated draft and which model wrote it. */
export async function runStudy(history: string, day: string, used: Set<string>, name: string | undefined, deps: NightDeps): Promise<{ shift: Shift; model: string }> {
  const { step, model } = await callFirst(
    effortFor(deps.models, 'medium', { maxTokens: NIGHT.studyTokens, timeoutMs: NIGHT.studyTimeoutMs }),
    [
      { role: 'system', content: STUDY_PROMPT },
      { role: 'user', content: `Tomorrow's bank is for ${day}.\n\n${history}` },
    ],
    [],
    deps.fetchImpl ?? fetch,
  );
  if (step.kind !== 'text') throw new MuseError('bad_output');
  const shift = validateShift(readJson(step.text), day, used, name);
  if (step.reasoning) shift.thinking = step.reasoning.replace(/\s+/g, ' ').trim().slice(0, NIGHT.thinkingChars);
  return { shift, model };
}

/** Step 2: the critic cuts weak lines (never all of them: if it would leave fewer than 3, the draft stays as it is). */
export async function runCritic(shift: Shift, profile: Profile, deps: NightDeps): Promise<Shift> {
  const listing = shift.angles.flatMap((a) => a.lines.map((l) => `${l.id} [${a.name}] ${l.text}`)).join('\n');
  const about = `About them: ${profile.name ?? 'the user'}; focus: ${profile.focus ?? 'not said'}; theories: ${shift.theories.filter((t) => t.status !== 'rejected').map((t) => t.statement).join(' | ') || 'none yet'}`;
  const { step } = await callFirst(
    effortFor(deps.models, 'low', { maxTokens: NIGHT.criticTokens, timeoutMs: NIGHT.criticTimeoutMs }),
    [
      { role: 'system', content: CRITIC_PROMPT },
      { role: 'user', content: `${about}\n\nLines:\n${listing}` },
    ],
    [],
    deps.fetchImpl ?? fetch,
  );
  if (step.kind !== 'text') throw new MuseError('bad_output');
  const raw = readJson(step.text);
  const cut = new Map<string, string>();
  for (const c of Array.isArray(raw.cut) ? raw.cut : []) {
    const id = (c as Record<string, unknown>)?.id;
    if (typeof id === 'string') cut.set(id, str((c as Record<string, unknown>).why, 120));
  }
  const angles = shift.angles
    .map((a) => ({ ...a, lines: a.lines.filter((l) => !cut.has(l.id)) }))
    .filter((a) => a.lines.length > 0);
  const left = angles.reduce((n, a) => n + a.lines.length, 0);
  const removed = shift.angles.reduce((n, a) => n + a.lines.length, 0) - left;
  if (left < 3) return { ...shift, critic: { cut: 0, reasons: ['kept the draft: cutting would leave too few lines'] } };
  return { ...shift, angles, critic: { cut: removed, reasons: [...new Set(cut.values())].filter(Boolean).slice(0, 5) } };
}

/** The lines already sent or already in the last bank, normalised, so tomorrow never repeats one. */
export function usedLines(events: ExperimentEvent[], previous: StoredShift | null): Set<string> {
  const used = new Set<string>();
  for (const e of events) if (e.message) used.add(norm(e.message));
  for (const a of previous?.shift.angles ?? []) for (const l of a.lines) used.add(norm(l.text));
  return used;
}
