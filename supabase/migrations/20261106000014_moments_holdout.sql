-- Moments and an honest comparison: a nudge can be a "moment" (one fact true only for this person, right now), about
-- 1 in 10 is held back on purpose (the control group: no card, only measured), and leaving only to come straight back
-- to a feed within 10 minutes is recorded, so it does not count as a success.
alter table public.experiments drop constraint if exists experiments_reason_check;
alter table public.experiments
  add constraint experiments_reason_check check (reason in ('approaching', 'limit', 'over', 'event', 'demo', 'moment')),
  add column holdout      boolean not null default false,
  add column back_to_feed boolean not null default false;
