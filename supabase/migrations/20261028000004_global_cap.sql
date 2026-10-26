-- One shared counter for ALL users per day. Anonymous sign-ins are free, so the per-user limit alone does not
-- bound the bill; this does. Nobody can read or write the table directly: only the function below touches it.

create table public.global_quota (
  day   date    primary key,
  calls integer not null default 0
);
alter table public.global_quota enable row level security; -- no policies on purpose

create function public.bump_global_quota() returns integer
language sql security definer set search_path = ''
as $$
  insert into public.global_quota (day, calls)
  values ((now() at time zone 'utc')::date, 1)
  on conflict (day) do update set calls = public.global_quota.calls + 1
  returning calls;
$$;
revoke all on function public.bump_global_quota() from public, anon;
grant execute on function public.bump_global_quota() to authenticated;
