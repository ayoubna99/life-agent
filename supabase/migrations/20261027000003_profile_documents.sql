-- The user's settings (asked in the app, not in the chat) and the documents they send to the agent.

alter table public.profiles
  add column distracting_apps text[] not null default '{}' check (cardinality(distracting_apps) <= 8),
  add column focus text check (char_length(focus) <= 200);

-- Text extracted once from a PDF or text file the user uploaded; the agent reads it in slices.
create table public.documents (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid        not null references auth.users (id) on delete cascade,
  name       text        not null check (char_length(name) between 1 and 120),
  pages      integer     not null default 1 check (pages >= 1),
  text       text        not null check (char_length(text) <= 300000),
  created_at timestamptz not null default now()
);
create index documents_user_idx on public.documents (user_id, created_at desc);
alter table public.documents enable row level security;
create policy "own documents" on public.documents for all
  using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);

-- Where the phone puts the files before asking the server to read them: private, one folder per user.
insert into storage.buckets (id, name, public, file_size_limit)
values ('uploads', 'uploads', false, 10485760) on conflict (id) do nothing;

create policy "own uploads (read)"   on storage.objects for select to authenticated
  using (bucket_id = 'uploads' and (storage.foldername(name))[1] = (select auth.uid())::text);
create policy "own uploads (add)"    on storage.objects for insert to authenticated
  with check (bucket_id = 'uploads' and (storage.foldername(name))[1] = (select auth.uid())::text);
create policy "own uploads (change)" on storage.objects for update to authenticated
  using (bucket_id = 'uploads' and (storage.foldername(name))[1] = (select auth.uid())::text);
create policy "own uploads (delete)" on storage.objects for delete to authenticated
  using (bucket_id = 'uploads' and (storage.foldername(name))[1] = (select auth.uid())::text);
