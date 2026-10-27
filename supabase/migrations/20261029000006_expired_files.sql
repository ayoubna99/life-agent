-- Which stored files are older than N days. Used only by the "cleanup" Edge Function (service role).
-- Deleting rows here would leave the real files behind, so this only LISTS; the function deletes through the Storage API.

create function public.expired_files(p_days integer, p_limit integer default 500)
returns table (bucket_id text, name text)
language sql security definer set search_path = ''
as $$
  select o.bucket_id, o.name
  from storage.objects o
  where o.bucket_id in ('materials', 'uploads')
    and o.name not like '%.emptyFolderPlaceholder'
    and coalesce(o.updated_at, o.created_at) < now() - make_interval(days => greatest(p_days, 1))
  order by coalesce(o.updated_at, o.created_at)
  limit least(greatest(p_limit, 1), 1000);
$$;
revoke all on function public.expired_files(integer, integer) from public, anon, authenticated;
grant execute on function public.expired_files(integer, integer) to service_role;
