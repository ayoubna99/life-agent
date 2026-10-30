-- When the phone went quiet each night and was first picked up again, measured on the phone (the longest overnight
-- gap in its own usage events). Phone use, not sleep: used for the evening reminder and the planning chat.
create table public.phone_nights (
  user_id uuid not null references auth.users (id) on delete cascade,
  night   date not null, -- the evening's date (a 02:30 phone-down belongs to the evening before)
  down_at text not null check (down_at ~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'),
  up_at   text          check (up_at   ~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'),
  primary key (user_id, night)
);
alter table public.phone_nights enable row level security;
create policy "own nights" on public.phone_nights for all using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);
