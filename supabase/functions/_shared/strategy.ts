// The user's strategy: what Lify has learned about how to plan for them (how many tasks they really finish, which
// limits hold, the hours they slip). Written by the agent in review mode, read in planning and execute mode.
// Every version is kept, so the app can show how it changed (day 1 against day 3).

export interface StrategyLimit {
  app: string;
  minutes: number;
  why?: string;
}

export interface PlanStyle {
  max_tasks?: number;
  buffer_pct?: number;
  best_window?: string; // HH:MM-HH:MM
}

/** What the agent writes. The version and the day are added by the server. */
export interface StrategyData {
  limits: StrategyLimit[];
  plan_style: PlanStyle;
  risk_windows: string[];
  rules: string[];
  changes: string[];
  evidence: string[];
}

export interface Strategy extends StrategyData {
  version: number;
  for_date: string;
  created_at?: string;
}

export const STRATEGY_LIMITS = { limits: 8, rules: 5, changes: 3, evidence: 5, windows: 4, text: 160 };

const WINDOW = /^([01]\d|2[0-3]):[0-5]\d-([01]\d|2[0-3]):[0-5]\d$/;

type Checked = { ok: true; strategy: StrategyData } | { ok: false; error: string };

function texts(v: unknown, what: string, max: number, maxChars = STRATEGY_LIMITS.text): string[] | string {
  if (v === undefined) return [];
  if (!Array.isArray(v) || v.length > max) return `${what} must be a list of at most ${max} short texts.`;
  const out: string[] = [];
  for (const s of v) {
    if (typeof s !== 'string' || !s.trim() || s.length > maxChars) return `each item of ${what} must be a text of 1 to ${maxChars} characters.`;
    out.push(s.trim());
  }
  return out;
}

const whole = (v: unknown, min: number, max: number) => typeof v === 'number' && Number.isInteger(v) && v >= min && v <= max;

/** Checks what the model sent. Problems come back as plain sentences the model can act on. */
export function validateStrategy(raw: unknown): Checked {
  const s = raw as Record<string, unknown> | null;
  if (!s || typeof s !== 'object' || Array.isArray(s)) return { ok: false, error: 'The strategy must be an object.' };

  const limits: StrategyLimit[] = [];
  if (s.limits !== undefined) {
    if (!Array.isArray(s.limits) || s.limits.length > STRATEGY_LIMITS.limits) return { ok: false, error: `limits must be a list of at most ${STRATEGY_LIMITS.limits}.` };
    for (const l of s.limits as Record<string, unknown>[]) {
      const app = typeof l?.app === 'string' ? l.app.trim() : '';
      if (!app || app.length > 60) return { ok: false, error: 'each limit needs an app name (at most 60 characters).' };
      if (!whole(l.minutes, 5, 720)) return { ok: false, error: 'each limit needs minutes, a whole number from 5 to 720.' };
      if (l.why !== undefined && (typeof l.why !== 'string' || l.why.length > STRATEGY_LIMITS.text)) return { ok: false, error: 'why must be a short text.' };
      limits.push({ app, minutes: l.minutes as number, ...(typeof l.why === 'string' && l.why.trim() ? { why: l.why.trim() } : {}) });
    }
  }

  const style: PlanStyle = {};
  if (s.plan_style !== undefined) {
    const p = s.plan_style as Record<string, unknown>;
    if (!p || typeof p !== 'object' || Array.isArray(p)) return { ok: false, error: 'plan_style must be an object.' };
    if (p.max_tasks !== undefined) {
      if (!whole(p.max_tasks, 1, 12)) return { ok: false, error: 'max_tasks must be a whole number from 1 to 12.' };
      style.max_tasks = p.max_tasks as number;
    }
    if (p.buffer_pct !== undefined) {
      if (!whole(p.buffer_pct, 0, 100)) return { ok: false, error: 'buffer_pct must be a whole number from 0 to 100.' };
      style.buffer_pct = p.buffer_pct as number;
    }
    if (p.best_window !== undefined) {
      if (typeof p.best_window !== 'string' || !WINDOW.test(p.best_window)) return { ok: false, error: 'best_window must look like 09:00-12:00.' };
      style.best_window = p.best_window;
    }
  }

  const windows = texts(s.risk_windows, 'risk_windows', STRATEGY_LIMITS.windows, 11);
  if (typeof windows === 'string') return { ok: false, error: windows };
  if (windows.some((w) => !WINDOW.test(w))) return { ok: false, error: 'each risk window must look like 21:00-23:00.' };
  const rules = texts(s.rules, 'rules', STRATEGY_LIMITS.rules, 100);
  if (typeof rules === 'string') return { ok: false, error: rules };
  const changes = texts(s.changes, 'changes', STRATEGY_LIMITS.changes);
  if (typeof changes === 'string') return { ok: false, error: changes };
  const evidence = texts(s.evidence, 'evidence', STRATEGY_LIMITS.evidence, 200);
  if (typeof evidence === 'string') return { ok: false, error: evidence };

  // No evidence, no change: every change cites a number, and the numbers come from the evidence.
  if (changes.length > 0 && evidence.length === 0) return { ok: false, error: 'Every change needs evidence from the data. Add the numbers to evidence, or make no change.' };
  if (changes.some((c) => !/\d/.test(c))) return { ok: false, error: 'Each change must cite a number from the data (for example "Cut Instagram limit 30 to 20").' };
  if (evidence.some((e) => !/\d/.test(e))) return { ok: false, error: 'Each evidence line must contain a number from the data.' };

  return { ok: true, strategy: { limits, plan_style: style, risk_windows: windows, rules, changes, evidence } };
}

/** The strategy as the planning and execute prompts see it: what to apply, without the history of why. */
export function strategyForPrompt(s: Strategy | null): string {
  if (!s) return 'none yet (no review has been done)';
  return JSON.stringify({ version: s.version, for_date: s.for_date, limits: s.limits, plan_style: s.plan_style, risk_windows: s.risk_windows, rules: s.rules });
}
