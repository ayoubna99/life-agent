-- Documents can now come from a photo too, and the original file stays in the private "uploads" bucket.
alter table public.documents add column kind text not null default 'text' check (kind in ('pdf', 'text', 'image'));
alter table public.documents add column file_path text check (char_length(file_path) <= 200);
