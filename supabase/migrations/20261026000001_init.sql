-- Life agent: day-1 schema. Every row belongs to one (anonymous) Supabase user and is only
-- visible to that user (row-level security). The Edge Function uses the caller's JWT, so the same rules apply.

create table public.profiles (
  user_id      uuid primary key references auth.users (id) on delete cascade,
  locale       text        not null default 'en',
  wake_minute  smallint    check (wake_minute  between 0 and 1439),
  sleep_minute smallint    check (sleep_minute between 0 and 1439),
  created_at   timestamptz not null default now()
);

create table public.conversations (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid        not null references auth.users (id) on delete cascade,
  kind       text        not null default 'planning' check (kind in ('planning', 'review')),
  created_at timestamptz not null default now()
);
create index conversations_user_idx on public.conversations (user_id, created_at desc);

create table public.messages (
  id              bigint generated always as identity primary key,
  conversation_id uuid        not null references public.conversations (id) on delete cascade,
  user_id         uuid        not null references auth.users (id) on delete cascade,
  role            text        not null check (role in ('user', 'assistant', 'tool')),
  content         jsonb       not null,
  created_at      timestamptz not null default now()
);
create index messages_conversation_idx on public.messages (conversation_id, id);

-- One plan per user per day. `data` is the agent's plan: tasks (with minutes, first step, instructions, links) and limits.
create table public.plans (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid        not null references auth.users (id) on delete cascade,
  for_date   date        not null,
  status     text        not null default 'draft' check (status in ('draft', 'ready', 'done')),
  data       jsonb       not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (user_id, for_date)
);

-- What really happened, summarised on the phone (minutes per app per day). Never the raw event log.
create table public.usage_days (
  user_id uuid     not null references auth.users (id) on delete cascade,
  day     date     not null,
  app     text     not null,
  minutes integer  not null check (minutes between 0 and 1440),
  primary key (user_id, day, app)
);

alter table public.profiles      enable row level security;
alter table public.conversations enable row level security;
alter table public.messages      enable row level security;
alter table public.plans         enable row level security;
alter table public.usage_days    enable row level security;

create policy "own profile"       on public.profiles      for all using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);
create policy "own conversations" on public.conversations for all using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);
create policy "own messages"      on public.messages      for all using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);
create policy "own plans"         on public.plans         for all using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);
create policy "own usage"         on public.usage_days    for all using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);
