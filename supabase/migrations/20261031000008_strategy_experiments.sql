-- Strategy memory: what Lify learned about how to plan for this user. One row per version, every version kept
-- (the app shows how it changed). Written by the agent in review mode with the user's own token.
create table public.strategies (
  id         bigint generated always as identity primary key,
  user_id    uuid        not null references auth.users (id) on delete cascade,
  version    integer     not null check (version > 0),
  for_date   date        not null,
  strategy   jsonb       not null,
  created_at timestamptz not null default now(),
  unique (user_id, version)
);

-- Experiments: at each limit hit the phone picks a personal nudge style with Thompson sampling (next task, what the
-- time costs, own goal) and measures what happened next. Results only (no event log of other apps).
create table public.experiments (
  id             bigint generated always as identity primary key,
  user_id        uuid        not null references auth.users (id) on delete cascade,
  event_id       text        not null check (char_length(event_id) <= 64),
  day            date        not null,
  local_time     text        not null check (local_time ~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'),
  app            text        not null check (char_length(app) <= 60),
  arm            text        not null check (arm in ('task', 'cost', 'goal')),
  explore        boolean     not null default false,
  reason         text        not null check (reason in ('approaching', 'limit', 'over', 'event', 'demo')),
  left_app       boolean     not null,
  seconds_after  integer     not null check (seconds_after between 0 and 3600),
  window_seconds integer     not null check (window_seconds between 30 and 3600),
  demo           boolean     not null default false,
  created_at     timestamptz not null default now(),
  unique (user_id, event_id)
);
create index experiments_user_day_idx on public.experiments (user_id, day);

alter table public.strategies  enable row level security;
alter table public.experiments enable row level security;
create policy "own strategies"  on public.strategies  for all using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);
create policy "own experiments" on public.experiments for all using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);
