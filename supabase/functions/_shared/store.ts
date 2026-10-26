// Everything the agent reads and writes. The interface lets the tests use an in-memory copy;
// RestStore talks to Supabase with the CALLER'S token, so row-level security applies to every call.

import type { ChatMessage } from './muse.ts';
import type { PlanData } from './plan.ts';
import type { Mode } from './prompt.ts';

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
  getConversation(id: string): Promise<{ id: string; kind: Mode } | null>;
  createConversation(kind: Mode): Promise<string>;
  loadMessages(conversationId: string): Promise<ChatMessage[]>;
  appendMessages(conversationId: string, messages: ChatMessage[]): Promise<void>;
  getPlan(date: string): Promise<SavedPlan | null>;
  savePlan(date: string, data: PlanData): Promise<void>;
  /** Minutes per day for one app (any capitalisation), newest first, from `since` (YYYY-MM-DD) on. */
  getUsage(app: string, since: string): Promise<UsageRow[]>;
  upsertUsage(rows: UsageRow[]): Promise<void>;
  /** Stores a markdown file for this user and returns a link that works for a week. */
  saveMaterial(fileName: string, markdown: string): Promise<string>;
}

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
    const path = `${this.c.userId}/${fileName}`.split('/').map(encodeURIComponent).join('/');
    await this.call('material', `${this.c.supabaseUrl}/storage/v1/object/materials/${path}`, {
      method: 'POST',
      body: markdown,
      headers: { 'Content-Type': 'text/markdown; charset=utf-8', 'x-upsert': 'true' },
    });
    const signed = (await this.call('material', `${this.c.supabaseUrl}/storage/v1/object/sign/materials/${path}`, {
      method: 'POST',
      json: { expiresIn: 7 * 24 * 3600 },
    })) as { signedURL?: string } | null;
    if (!signed?.signedURL) throw new StoreError('material', 0);
    return `${this.c.supabaseUrl}/storage/v1${signed.signedURL}`;
  }
}
