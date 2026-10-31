-- Theories are checked by code, so each nudge records the moment in more detail than the time of day: weekday or
-- weekend, how deep into the app the person was, whether an important task was coming up, and the tone and topic of
-- the night shift's idea that was used.
alter table public.experiments
  add column day_type  text    check (day_type in ('weekday', 'weekend')),
  add column depth     text    check (depth in ('near', 'just_over', 'way_over', 'session')),
  add column task_soon boolean,
  add column tone      text    check (tone in ('blunt', 'playful', 'question', 'dare', 'calm')),
  add column topic     text    check (topic in ('task', 'goal', 'sleep', 'cost', 'plan', 'other'));
