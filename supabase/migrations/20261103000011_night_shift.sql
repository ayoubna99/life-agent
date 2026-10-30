-- The night shift: every night Muse Spark Open studies the user's whole history, keeps or drops its theories about what
-- gets them off the phone, and writes tomorrow's nudge bank (short lines grouped by "angle", the idea behind them).
-- One row per night; the phone uses the newest bank during the day.
create table public.night_shifts (
  user_id    uuid        not null references auth.users (id) on delete cascade,
  day        date        not null, -- the day the bank is for
  status     text        not null check (status in ('draft', 'final')),
  shift      jsonb       not null, -- { theories, angles, notes }
  model      text        not null check (char_length(model) <= 20),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (user_id, day)
);
alter table public.night_shifts enable row level security;
create policy "own night shifts" on public.night_shifts for all using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);

-- Each nudge now records which angle and which exact line it used, and whether the user tapped "Pull me out".
alter table public.experiments
  add column angle   text check (angle ~ '^[a-z0-9_-]{1,40}$'),
  add column line_id text check (line_id ~ '^[a-z0-9_-]{1,60}$'),
  add column pulled  boolean not null default false;
