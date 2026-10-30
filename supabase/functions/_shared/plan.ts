// What a saved plan looks like, and the checks every plan passes before it is stored.

export interface PlanTask {
  title: string;
  minutes: number;
  first_step?: string;
  instructions?: string[];
  links?: string[];
  start_time?: string;
  /** What was decided in the chat about this task, so the task screen has everything when its time comes. */
  notes?: string;
  /** How its reminder rings: "phone" = a real alarm in the phone's Clock app (away from the screen: gym, prayer,
   *  leaving home), "in_app" = Life opens this task's screen with its links and material (reading, emails, study). */
  alarm?: 'in_app' | 'phone';
}
export interface PlanLimit {
  app: string;
  minutes_per_day: number;
}
export interface PlanData {
  wake?: string;
  sleep?: string;
  tasks: PlanTask[];
  limits: PlanLimit[];
  note?: string;
}

const HHMM = /^([01]\d|2[0-3]):[0-5]\d$/;
export const DATE = /^\d{4}-\d{2}-\d{2}$/;

export function isDate(s: unknown): s is string {
  if (typeof s !== 'string' || !DATE.test(s)) return false;
  const d = new Date(`${s}T00:00:00Z`);
  return !Number.isNaN(d.getTime()) && d.toISOString().startsWith(s);
}

const text = (v: unknown, max: number): string | null =>
  typeof v === 'string' && v.trim() !== '' && v.length <= max ? v.trim() : null;
const int = (v: unknown, min: number, max: number): number | null =>
  typeof v === 'number' && Number.isInteger(v) && v >= min && v <= max ? v : null;

/** Returns the clean plan, or ONE sentence for the model saying what to fix (it retries from that). */
export function validatePlan(raw: unknown): { ok: true; plan: PlanData } | { ok: false; error: string } {
  const a = raw as Record<string, unknown> | null;
  if (!a || typeof a !== 'object') return { ok: false, error: 'The plan must be an object.' };
  if (!Array.isArray(a.tasks) || a.tasks.length === 0) return { ok: false, error: 'tasks must be a non-empty list.' };
  if (a.tasks.length > 12) return { ok: false, error: 'At most 12 tasks per day.' };

  const tasks: PlanTask[] = [];
  for (const [i, t] of (a.tasks as Record<string, unknown>[]).entries()) {
    const n = `tasks[${i}]`;
    const title = text(t?.title, 120);
    if (!title) return { ok: false, error: `${n}.title is required (at most 120 characters).` };
    const minutes = int(t?.minutes, 5, 480);
    if (minutes === null) return { ok: false, error: `${n}.minutes must be a whole number from 5 to 480.` };
    const task: PlanTask = { title, minutes };
    if (t.first_step !== undefined) {
      const v = text(t.first_step, 200);
      if (!v) return { ok: false, error: `${n}.first_step must be 1 to 200 characters.` };
      task.first_step = v;
    }
    if (t.start_time !== undefined) {
      if (typeof t.start_time !== 'string' || !HHMM.test(t.start_time)) return { ok: false, error: `${n}.start_time must be HH:MM.` };
      task.start_time = t.start_time;
    }
    if (t.instructions !== undefined) {
      if (!Array.isArray(t.instructions) || t.instructions.length > 8) return { ok: false, error: `${n}.instructions must be a list of at most 8 lines.` };
      const lines = t.instructions.map((l) => text(l, 300));
      if (lines.includes(null)) return { ok: false, error: `${n}.instructions lines must be 1 to 300 characters.` };
      task.instructions = lines as string[];
    }
    if (t.links !== undefined) {
      if (!Array.isArray(t.links) || t.links.length > 6) return { ok: false, error: `${n}.links must be a list of at most 6 links.` };
      const links = t.links.map((l) => text(l, 1000)); // signed links to our own files are long
      if (links.includes(null)) return { ok: false, error: `${n}.links must be 1 to 1000 characters.` };
      task.links = links as string[];
    }
    if (t.notes !== undefined) {
      const v = text(t.notes, 600);
      if (!v) return { ok: false, error: `${n}.notes must be 1 to 600 characters.` };
      task.notes = v;
    }
    if (t.alarm !== undefined) {
      if (t.alarm !== 'in_app' && t.alarm !== 'phone') return { ok: false, error: `${n}.alarm must be "in_app" or "phone".` };
      task.alarm = t.alarm;
    }
    tasks.push(task);
  }

  const limits: PlanLimit[] = [];
  const seen = new Set<string>();
  if (a.limits !== undefined) {
    if (!Array.isArray(a.limits) || a.limits.length > 8) return { ok: false, error: 'limits must be a list of at most 8.' };
    for (const [i, l] of (a.limits as Record<string, unknown>[]).entries()) {
      const app = text(l?.app, 60);
      const m = int(l?.minutes_per_day, 5, 720);
      if (!app || m === null) return { ok: false, error: `limits[${i}] needs an app and minutes_per_day from 5 to 720.` };
      if (seen.has(app.toLowerCase())) return { ok: false, error: `limits has "${app}" twice.` };
      seen.add(app.toLowerCase());
      limits.push({ app, minutes_per_day: m });
    }
  }

  const plan: PlanData = { tasks, limits };
  for (const key of ['wake', 'sleep'] as const) {
    if (a[key] !== undefined) {
      if (typeof a[key] !== 'string' || !HHMM.test(a[key] as string)) return { ok: false, error: `${key} must be HH:MM.` };
      plan[key] = a[key] as string;
    }
  }
  if (a.note !== undefined) {
    const v = text(a.note, 300);
    if (!v) return { ok: false, error: 'note must be 1 to 300 characters.' };
    plan.note = v;
  }
  return { ok: true, plan };
}
