-- Day 1b: everything the full agent needs on top of the first schema.
--  * conversations can be "execute" (the morning run that applies the plan on the phone)
--  * a per-user daily call counter the user cannot reset (written only by a security-definer function)
--  * a private storage bucket for the study material the agent prepares, one folder per user

alter table public.conversations drop constraint conversations_kind_check;
alter table public.conversations add constraint conversations_kind_check check (kind in ('planning', 'execute', 'review'));

create table public.agent_quota (
  user_id uuid    not null references auth.users (id) on delete cascade,
  day     date    not null,
  calls   integer not null default 0,
  primary key (user_id, day)
);
alter table public.agent_quota enable row level security;
-- Read-only for the user: only bump_quota() below can change it.
create policy "own quota (read)" on public.agent_quota for select using ((select auth.uid()) = user_id);

create function public.bump_quota() returns integer
language sql security definer set search_path = ''
as $$
  insert into public.agent_quota (user_id, day, calls)
  values ((select auth.uid()), (now() at time zone 'utc')::date, 1)
  on conflict (user_id, day) do update set calls = public.agent_quota.calls + 1
  returning calls;
$$;
revoke all on function public.bump_quota() from public, anon;
grant execute on function public.bump_quota() to authenticated;

insert into storage.buckets (id, name, public) values ('materials', 'materials', false) on conflict (id) do nothing;

create policy "own materials (read)"   on storage.objects for select to authenticated
  using (bucket_id = 'materials' and (storage.foldername(name))[1] = (select auth.uid())::text);
create policy "own materials (add)"    on storage.objects for insert to authenticated
  with check (bucket_id = 'materials' and (storage.foldername(name))[1] = (select auth.uid())::text);
create policy "own materials (change)" on storage.objects for update to authenticated
  using (bucket_id = 'materials' and (storage.foldername(name))[1] = (select auth.uid())::text);
