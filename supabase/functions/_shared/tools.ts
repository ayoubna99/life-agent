// The tools that run on the server. Each returns a JSON string for the model. A problem with the model's
// input is returned AS the result (so it can fix it and retry); a broken store throws and ends the request.

import { verifyLinks } from './links.ts';
import { isDate, validatePlan } from './plan.ts';
import type { Mode } from './prompt.ts';
import type { Store } from './store.ts';

export interface ToolEnv {
  store: Store;
  mode: Mode;
  today: string;
  planDate: string;
  supabaseUrl: string;
  fetchImpl: typeof fetch;
  randomId: () => string;
}

export interface ToolOutcome {
  content: string;
  planSaved?: boolean;
}

const json = (v: unknown): string => JSON.stringify(v);
const problem = (msg: string): ToolOutcome => ({ content: json({ error: msg }) });

function addDays(date: string, n: number): string {
  const d = new Date(`${date}T00:00:00Z`);
  d.setUTCDate(d.getUTCDate() + n);
  return d.toISOString().slice(0, 10);
}

export function slug(title: string): string {
  const s = title.toLowerCase().normalize('NFKD').replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '').slice(0, 40);
  return s || 'sheet';
}

export async function runServerTool(name: string, args: Record<string, unknown>, env: ToolEnv): Promise<ToolOutcome> {
  switch (name) {
    case 'get_usage': {
      const app = typeof args.app === 'string' ? args.app.trim() : '';
      if (!app || app.length > 60) return problem('app is required (at most 60 characters).');
      const days = args.days === undefined ? 7 : args.days;
      if (typeof days !== 'number' || !Number.isInteger(days) || days < 1 || days > 14) return problem('days must be a whole number from 1 to 14.');
      const rows = await env.store.getUsage(app, addDays(env.today, -(days - 1)));
      const perDay = new Map<string, number>();
      for (const r of rows) perDay.set(r.day, (perDay.get(r.day) ?? 0) + r.minutes);
      const list = [...perDay].map(([day, minutes]) => ({ day, minutes })).sort((a, b) => b.day.localeCompare(a.day));
      if (list.length === 0) return { content: json({ app, days: [], note: 'No usage has been recorded for this app yet.' }) };
      const average = Math.round(list.reduce((s, d) => s + d.minutes, 0) / list.length);
      return { content: json({ app, days: list, average_minutes: average }) };
    }

    case 'get_plan': {
      if (!isDate(args.date)) return problem('date must be YYYY-MM-DD.');
      const plan = await env.store.getPlan(args.date);
      if (!plan) return problem(`No plan is saved for ${args.date}.`);
      return { content: json({ date: plan.date, status: plan.status, plan: plan.data }) };
    }

    case 'save_plan': {
      const checked = validatePlan(args);
      if (!checked.ok) return problem(checked.error);
      const plan = checked.plan;
      const all = plan.tasks.flatMap((t) => t.links ?? []);
      const { ok, dropped } = await verifyLinks(all, {
        fetchImpl: env.fetchImpl,
        trustedPrefix: `${env.supabaseUrl.replace(/\/+$/, '')}/storage/v1/object/sign/materials/`,
      });
      const good = new Set(ok);
      for (const t of plan.tasks) {
        if (t.links) {
          t.links = t.links.filter((l) => good.has(l));
          if (t.links.length === 0) delete t.links;
        }
      }
      // The day always comes from the app's context, never from the model.
      await env.store.savePlan(env.planDate, plan);
      return { content: json({ saved: true, date: env.planDate, tasks: plan.tasks.length, limits: plan.limits.length, dropped_links: dropped }), planSaved: true };
    }

    case 'create_material': {
      const title = typeof args.title === 'string' ? args.title.trim() : '';
      const markdown = typeof args.markdown === 'string' ? args.markdown.trim() : '';
      if (!title || title.length > 80) return problem('title is required (at most 80 characters).');
      if (!markdown || markdown.length > 6000) return problem('markdown is required (at most 6000 characters).');
      const fileName = `${env.planDate}-${slug(title)}-${env.randomId().slice(0, 8)}.md`;
      const url = await env.store.saveMaterial(fileName, `# ${title}\n\n${markdown}\n`);
      return { content: json({ title, url }) };
    }

    default:
      return problem(`Unknown tool ${name}.`);
  }
}
