-- Contextual Thompson sampling and off-policy evaluation: for each nudge the phone also logs the chance its policy had
-- of picking that style (propensity), the moment (time of day band), and the words Muse Spark wrote (the lab notebook).
alter table public.experiments
  add column propensity double precision check (propensity > 0 and propensity <= 1),
  add column context    text check (context in ('morning', 'afternoon', 'evening', 'night')),
  add column message    text check (char_length(message) <= 300);
