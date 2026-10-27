-- The first name asked during onboarding, so Lify can greet the user by name.
alter table public.profiles
  add column first_name text check (char_length(first_name) <= 40);
