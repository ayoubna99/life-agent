// Everything the agent reads and writes. The interface lets the tests use an in-memory copy;
// RestStore talks to Supabase with the CALLER'S token, so row-level security applies to every call.

import type { ChatMessage } from './muse.ts';
import type { StoredShift } from './nightshift.ts';
import type { PlanData } from './plan.ts';
import { toHHMM, toMinutes } from './profile.ts';
import type { Profile } from './profile.ts';
import type { Mode } from './prompt.ts';
import type { Strategy, StrategyData } from './strategy.ts';
import type { ExperimentEvent } from './experiments.ts';
import type { PhoneNight } from './nights.ts';

export class StoreError extends Error {
  readonly status: number;
  constructor(what: string, status: number) {
    super(`store_${what}_${status}`);
    this.status = status;
  }
}

export interface UsageRow {
  day: string; // YYYY-MM-DD
  app: string;
  minutes: number;
}

export interface SavedPlan {
  date: string;
  status: string;
  data: PlanData;
}

export interface Store {
  /** Counts one agent request for today (UTC) and returns how many there have been. */
  bumpQuota(): Promise<number>;
  /** The counter shared by every user for today (see the global_quota migration). */
  bumpGlobalQuota(): Promise<number>;
  getConversation(id: string): Promise<{ id: string; kind: Mode } | null>;
  createConversation(kind: Mode): Promise<string>;
  loadMessages(conversationId: string): Promise<ChatMessage[]>;
  appendMessages(conversationId: string, messages: ChatMessage[]): Promise<void>;
  getPlan(date: string): Promise<SavedPlan | null>;
  savePlan(date: string, data: PlanData): Promise<void>;
  /** Minutes per day for one app (any capitalisation), newest first, from `since` (YYYY-MM-DD) on. */
  getUsage(app: string, since: string): Promise<UsageRow[]>;
  upsertUsage(rows: UsageRow[]): Promise<void>;
  /** Stores a markdown file for this user and returns a link that works for 3 days (files are deleted after 3 days). */
  saveMaterial(fileName: string, markdown: string): Promise<string>;
  /** Stores a file the agent made (a PDF or a picture; same private bucket and folder as materials) and returns a link that works for 3 days (files are deleted after 3 days). */
  saveFile(fileName: string, bytes: Uint8Array, contentType: string): Promise<string>;
  getProfile(): Promise<Profile>;
  /** Saves only the fields in `patch`. */
  saveProfile(patch: Partial<Profile>): Promise<void>;
  /** The bytes of a file the user uploaded (path is "<user id>/<file>"), or null if it is not there. */
  downloadUpload(path: string, maxBytes: number): Promise<Uint8Array | null>;
  /** Removes an uploaded file once it has been read (best effort: a failure never stops the request). */
  deleteUpload(path: string): Promise<void>;
  saveDocument(doc: NewDocument): Promise<string>;
  getDocument(id: string): Promise<StoredDocument | null>;
  /** The newest strategy version, or null before the first review. */
  getStrategy(): Promise<Strategy | null>;
  /** Strategy versions, newest first. */
  listStrategies(limit: number): Promise<Strategy[]>;
  /** Stores a NEW version (the old ones stay) and returns its number. */
  saveStrategy(forDate: string, data: StrategyData): Promise<number>;
  /** Stores experiment results from the phone; an event already stored (same id) is ignored. */
  saveExperiments(events: ExperimentEvent[]): Promise<void>;
  /** Experiment results from `since` (YYYY-MM-DD) on. */
  getExperiments(since: string): Promise<ExperimentEvent[]>;
  /** Phone-down times, one per night (replacing what was there for that night). */
  upsertNights(nights: PhoneNight[]): Promise<void>;
  /** The last 7 nights up to and including `upTo` (YYYY-MM-DD), newest first. */
  getNights(upTo: string): Promise<PhoneNight[]>;
  /** The night shift for `day`, or the newest one when `day` is omitted. */
  getNightShift(day?: string): Promise<StoredShift | null>;
  saveNightShift(s: StoredShift): Promise<void>;
}

export interface NewDocument {
  name: string;
  text: string;
  pages: number;
  kind: 'pdf' | 'text' | 'image';
  /** Where the original file stays in the private "uploads" bucket, or null when it was deleted after reading. */
  filePath: string | null;
}

export interface StoredDocument {
  id: string;
  name: string;
  pages: number;
  text: string;
  kind: 'pdf' | 'text' | 'image';
}

/** Links to the agent's files last as long as the files do (the cleanup function deletes them after 3 days). */
export const LINK_SECONDS = 3 * 24 * 3600;

export interface RestConfig {
  supabaseUrl: string;
  apikey: string;
  jwt: string;
  userId: string;
  fetchImpl?: typeof fetch;
}

export class RestStore implements Store {
  private readonly c: RestConfig;
  private readonly f: typeof fetch;

  constructor(config: RestConfig) {
    this.c = { ...config, supabaseUrl: config.supabaseUrl.replace(/\/+$/, '') };
    this.f = config.fetchImpl ?? fetch;
  }

  private async call(what: string, url: string, init: RequestInit & { json?: unknown } = {}): Promise<unknown> {
    const headers: Record<string, string> = {
      apikey: this.c.apikey,
      Authorization: `Bearer ${this.c.jwt}`,
      ...((init.headers as Record<string, string>) ?? {}),
    };
    let body = init.body;
    if (init.json !== undefined) {
      headers['Content-Type'] = 'application/json';
      body = JSON.stringify(init.json);
    }
    let res: Response;
    try {
      res = await this.f(url, { method: init.method ?? 'GET', headers, body });
    } catch {
      throw new StoreError(what, 0);
    }
    if (!res.ok) throw new StoreError(what, res.status);
    const type = res.headers.get('content-type') ?? '';
    return type.includes('json') ? await res.json() : null;
  }

  private rest(what: string, path: string, init: RequestInit & { json?: unknown } = {}) {
    return this.call(what, `${this.c.supabaseUrl}/rest/v1/${path}`, init);
  }

  async bumpQuota(): Promise<number> {
    const n = await this.rest('quota', 'rpc/bump_quota', { method: 'POST', json: {} });
    if (typeof n !== 'number') throw new StoreError('quota', 0);
    return n;
  }

  async bumpGlobalQuota(): Promise<number> {
    const n = await this.rest('quota', 'rpc/bump_global_quota', { method: 'POST', json: {} });
    if (typeof n !== 'number') throw new StoreError('quota', 0);
    return n;
  }

  async getConversation(id: string) {
    const rows = (await this.rest('conversation', `conversations?id=eq.${encodeURIComponent(id)}&select=id,kind&limit=1`)) as { id: string; kind: Mode }[];
    return rows[0] ?? null;
  }

  async createConversation(kind: Mode): Promise<string> {
    const rows = (await this.rest('conversation', 'conversations?select=id', {
      method: 'POST',
      json: { user_id: this.c.userId, kind },
      headers: { Prefer: 'return=representation' },
    })) as { id: string }[];
    if (!rows?.[0]?.id) throw new StoreError('conversation', 0);
    return rows[0].id;
  }

  async loadMessages(conversationId: string): Promise<ChatMessage[]> {
    const rows = (await this.rest(
      'messages',
      `messages?conversation_id=eq.${encodeURIComponent(conversationId)}&select=content&order=id.asc&limit=200`,
    )) as { content: ChatMessage }[];
    return rows.map((r) => r.content);
  }

  async appendMessages(conversationId: string, messages: ChatMessage[]): Promise<void> {
    if (messages.length === 0) return;
    await this.rest('messages', 'messages', {
      method: 'POST',
      json: messages.map((m) => ({ conversation_id: conversationId, user_id: this.c.userId, role: m.role, content: m })),
      headers: { Prefer: 'return=minimal' },
    });
  }

  async getPlan(date: string): Promise<SavedPlan | null> {
    const rows = (await this.rest('plan', `plans?for_date=eq.${encodeURIComponent(date)}&select=for_date,status,data&limit=1`)) as {
      for_date: string;
      status: string;
      data: PlanData;
    }[];
    const r = rows[0];
    return r ? { date: r.for_date, status: r.status, data: r.data } : null;
  }

  async savePlan(date: string, data: PlanData): Promise<void> {
    await this.rest('plan', 'plans?on_conflict=user_id,for_date', {
      method: 'POST',
      json: [{ user_id: this.c.userId, for_date: date, status: 'ready', data, updated_at: new Date().toISOString() }],
      headers: { Prefer: 'resolution=merge-duplicates,return=minimal' },
    });
  }

  async getUsage(app: string, since: string): Promise<UsageRow[]> {
    // ilike without wildcards is a case-insensitive exact match; wildcards typed by the model are removed.
    const clean = app.replace(/[%*_,()]/g, '');
    const rows = (await this.rest(
      'usage',
      `usage_days?app=ilike.${encodeURIComponent(clean)}&day=gte.${encodeURIComponent(since)}&select=day,app,minutes&order=day.desc&limit=60`,
    )) as UsageRow[];
    return rows;
  }

  async upsertUsage(rows: UsageRow[]): Promise<void> {
    if (rows.length === 0) return;
    await this.rest('usage', 'usage_days?on_conflict=user_id,day,app', {
      method: 'POST',
      json: rows.map((r) => ({ user_id: this.c.userId, day: r.day, app: r.app, minutes: r.minutes })),
      headers: { Prefer: 'resolution=merge-duplicates,return=minimal' },
    });
  }

  async saveMaterial(fileName: string, markdown: string): Promise<string> {
    return this.putMaterial(fileName, markdown, 'text/markdown; charset=utf-8');
  }

  async saveFile(fileName: string, bytes: Uint8Array, contentType: string): Promise<string> {
    return this.putMaterial(fileName, bytes, contentType);
  }

  private async putMaterial(fileName: string, body: string | Uint8Array, contentType: string): Promise<string> {
    const path = `${this.c.userId}/${fileName}`.split('/').map(encodeURIComponent).join('/');
    await this.call('material', `${this.c.supabaseUrl}/storage/v1/object/materials/${path}`, {
      method: 'POST',
      body,
      headers: { 'Content-Type': contentType, 'x-upsert': 'true' },
    });
    const signed = (await this.call('material', `${this.c.supabaseUrl}/storage/v1/object/sign/materials/${path}`, {
      method: 'POST',
      json: { expiresIn: LINK_SECONDS },
    })) as { signedURL?: string } | null;
    if (!signed?.signedURL) throw new StoreError('material', 0);
    return `${this.c.supabaseUrl}/storage/v1${signed.signedURL}`;
  }

  async getProfile(): Promise<Profile> {
    const rows = (await this.rest('profile', 'profiles?select=wake_minute,sleep_minute,distracting_apps,focus,first_name&limit=1')) as {
      wake_minute: number | null;
      sleep_minute: number | null;
      distracting_apps: string[] | null;
      focus: string | null;
      first_name: string | null;
    }[];
    const r = rows[0];
    const profile: Profile = { apps: r?.distracting_apps ?? [] };
    if (typeof r?.wake_minute === 'number') profile.wake = toHHMM(r.wake_minute);
    if (typeof r?.sleep_minute === 'number') profile.sleep = toHHMM(r.sleep_minute);
    if (r?.focus) profile.focus = r.focus;
    if (r?.first_name) profile.name = r.first_name;
    return profile;
  }

  async saveProfile(patch: Partial<Profile>): Promise<void> {
    const row: Record<string, unknown> = { user_id: this.c.userId };
    if (patch.wake !== undefined) row.wake_minute = toMinutes(patch.wake);
    if (patch.sleep !== undefined) row.sleep_minute = toMinutes(patch.sleep);
    if (patch.apps !== undefined) row.distracting_apps = patch.apps;
    if (patch.focus !== undefined) row.focus = patch.focus;
    if (patch.name !== undefined) row.first_name = patch.name;
    await this.rest('profile', 'profiles?on_conflict=user_id', {
      method: 'POST',
      json: row,
      headers: { Prefer: 'resolution=merge-duplicates,return=minimal' },
    });
  }

  async downloadUpload(path: string, maxBytes: number): Promise<Uint8Array | null> {
    const safe = path.split('/').map(encodeURIComponent).join('/');
    let res: Response;
    try {
      res = await this.f(`${this.c.supabaseUrl}/storage/v1/object/uploads/${safe}`, {
        headers: { apikey: this.c.apikey, Authorization: `Bearer ${this.c.jwt}` },
      });
    } catch {
      throw new StoreError('upload', 0);
    }
    if (res.status === 400 || res.status === 404) return null;
    if (!res.ok) throw new StoreError('upload', res.status);
    const bytes = new Uint8Array(await res.arrayBuffer());
    return bytes.length > maxBytes ? null : bytes;
  }

  async deleteUpload(path: string): Promise<void> {
    const safe = path.split('/').map(encodeURIComponent).join('/');
    try {
      await this.f(`${this.c.supabaseUrl}/storage/v1/object/uploads/${safe}`, {
        method: 'DELETE',
        headers: { apikey: this.c.apikey, Authorization: `Bearer ${this.c.jwt}` },
      });
    } catch {
      // The file stays until the user's data is deleted; nothing else depends on it.
    }
  }

  async saveDocument(doc: NewDocument): Promise<string> {
    const rows = (await this.rest('document', 'documents?select=id', {
      method: 'POST',
      json: { user_id: this.c.userId, name: doc.name, text: doc.text, pages: doc.pages, kind: doc.kind, file_path: doc.filePath },
      headers: { Prefer: 'return=representation' },
    })) as { id: string }[];
    if (!rows?.[0]?.id) throw new StoreError('document', 0);
    return rows[0].id;
  }

  async getDocument(id: string): Promise<StoredDocument | null> {
    const rows = (await this.rest('document', `documents?id=eq.${encodeURIComponent(id)}&select=id,name,pages,text,kind&limit=1`)) as StoredDocument[];
    return rows[0] ?? null;
  }

  async getStrategy(): Promise<Strategy | null> {
    return (await this.listStrategies(1))[0] ?? null;
  }

  async listStrategies(limit: number): Promise<Strategy[]> {
    const rows = (await this.rest(
      'strategy',
      `strategies?select=version,for_date,strategy,created_at&order=version.desc&limit=${Math.max(1, Math.min(limit, 60))}`,
    )) as { version: number; for_date: string; strategy: StrategyData; created_at: string }[];
    return rows.map((r) => ({ ...r.strategy, version: r.version, for_date: r.for_date, created_at: r.created_at }));
  }

  async saveStrategy(forDate: string, data: StrategyData): Promise<number> {
    // The next number after the newest; the unique (user_id, version) key refuses a second writer with the same number.
    const version = ((await this.getStrategy())?.version ?? 0) + 1;
    await this.rest('strategy', 'strategies', {
      method: 'POST',
      json: { user_id: this.c.userId, version, for_date: forDate, strategy: data },
      headers: { Prefer: 'return=minimal' },
    });
    return version;
  }

  async saveExperiments(events: ExperimentEvent[]): Promise<void> {
    if (events.length === 0) return;
    await this.rest('experiments', 'experiments?on_conflict=user_id,event_id', {
      method: 'POST',
      json: events.map((e) => ({
        user_id: this.c.userId,
        event_id: e.id,
        day: e.day,
        local_time: e.time,
        app: e.app,
        arm: e.arm,
        explore: e.explore,
        reason: e.reason,
        left_app: e.left,
        seconds_after: e.seconds_after,
        window_seconds: e.window_seconds,
        demo: e.demo,
        propensity: e.propensity ?? null,
        context: e.context ?? null,
        message: e.message ?? null,
        angle: e.angle ?? null,
        line_id: e.line_id ?? null,
        pulled: e.pulled === true,
      })),
      headers: { Prefer: 'resolution=ignore-duplicates,return=minimal' },
    });
  }

  async getExperiments(since: string): Promise<ExperimentEvent[]> {
    const rows = (await this.rest(
      'experiments',
      `experiments?day=gte.${encodeURIComponent(since)}&select=event_id,day,local_time,app,arm,explore,reason,left_app,seconds_after,window_seconds,demo,propensity,context,message,angle,line_id,pulled&order=id.asc&limit=1000`,
    )) as Record<string, unknown>[];
    return rows.map((r) => ({
      id: r.event_id as string,
      day: r.day as string,
      time: r.local_time as string,
      app: r.app as string,
      arm: r.arm as ExperimentEvent['arm'],
      explore: r.explore as boolean,
      reason: r.reason as ExperimentEvent['reason'],
      left: r.left_app as boolean,
      seconds_after: r.seconds_after as number,
      window_seconds: r.window_seconds as number,
      demo: r.demo as boolean,
      ...(typeof r.propensity === 'number' ? { propensity: r.propensity } : {}),
      ...(typeof r.context === 'string' ? { context: r.context as ExperimentEvent['context'] } : {}),
      ...(typeof r.message === 'string' ? { message: r.message } : {}),
      ...(typeof r.angle === 'string' ? { angle: r.angle } : {}),
      ...(typeof r.line_id === 'string' ? { line_id: r.line_id } : {}),
      ...(r.pulled === true ? { pulled: true } : {}),
    }));
  }

  async upsertNights(nights: PhoneNight[]): Promise<void> {
    if (nights.length === 0) return;
    await this.rest('nights', 'phone_nights?on_conflict=user_id,night', {
      method: 'POST',
      json: nights.map((n) => ({ user_id: this.c.userId, night: n.night, down_at: n.down, up_at: n.up ?? null })),
      headers: { Prefer: 'resolution=merge-duplicates,return=minimal' },
    });
  }

  async getNights(upTo: string): Promise<PhoneNight[]> {
    const rows = (await this.rest(
      'nights',
      `phone_nights?night=lte.${encodeURIComponent(upTo)}&select=night,down_at,up_at&order=night.desc&limit=7`,
    )) as { night: string; down_at: string; up_at: string | null }[];
    return rows.map((r) => ({ night: r.night, down: r.down_at, ...(r.up_at ? { up: r.up_at } : {}) }));
  }

  async getNightShift(day?: string): Promise<StoredShift | null> {
    const where = day ? `day=eq.${encodeURIComponent(day)}&` : '';
    const rows = (await this.rest('night_shift', `night_shifts?${where}select=day,status,shift,model,updated_at&order=day.desc&limit=1`)) as StoredShift[];
    return rows[0] ?? null;
  }

  async saveNightShift(s: StoredShift): Promise<void> {
    await this.rest('night_shift', 'night_shifts?on_conflict=user_id,day', {
      method: 'POST',
      json: { user_id: this.c.userId, day: s.day, status: s.status, shift: s.shift, model: s.model, updated_at: new Date().toISOString() },
      headers: { Prefer: 'resolution=merge-duplicates,return=minimal' },
    });
  }
}
