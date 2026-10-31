-- Step-down targets per app (the changing-criterion method, see taper.ts): the person's typical day, today's target,
-- the path so far and the "trade" Muse Spark Open wrote for the minutes won back. One row per app.
create table public.tapers (
  user_id    uuid        not null references auth.users (id) on delete cascade,
  app        text        not null check (char_length(app) <= 60),
  state      jsonb       not null,
  updated_at timestamptz not null default now(),
  primary key (user_id, app)
);
alter table public.tapers enable row level security;
create policy "own tapers" on public.tapers for all using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);
