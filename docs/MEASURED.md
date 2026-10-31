# How the "Measured" numbers are computed

Run these in the Supabase dashboard → SQL editor. Replace `USER_ID` with your account id (Settings → Check Lify →
Account shows its first characters; the full id is in Authentication → Users). Dates are the phone's local days.

**Nudges shown, from the bank vs live, left, pulled out**
```sql
select count(*)                                   as nudges,
       count(*) filter (where angle is not null)  as from_bank,
       count(*) filter (where angle is null)      as live,
       count(*) filter (where left_app)           as left_app,
       round(100.0 * count(*) filter (where left_app) / nullif(count(*), 0), 1) as left_pct,
       count(*) filter (where pulled)             as pulled_out
from experiments where user_id = 'USER_ID' and not demo;
```
(Remove `and not demo` to include demo-mode nudges, and say so in the README.)

**Best idea so far**
```sql
select angle, count(*) as tried, count(*) filter (where left_app) as left_app
from experiments where user_id = 'USER_ID' and angle is not null
group by angle order by (count(*) filter (where left_app) + 1.0) / (count(*) + 2) desc limit 3;
```

**Theory verdicts and model overruled**: open *Lify's theories about you* in the app (verdicts are recomputed by code
on every read). Count kept / rejected / testing, and the theories that show *Lify guessed … your results say …*.

**Lift vs the best single style**: the lab notebook's policy line (needs 10+ nudges with a logged chance). It shows the
estimate and its 90% interval.

**Night shift time and cost**: press Home → TEST → *Night shift (test)* and time it, or compare `created_at` and
`updated_at` of the newest row:
```sql
select day, status, created_at, updated_at, updated_at - created_at as study_to_final
from night_shifts where user_id = 'USER_ID' order by day desc limit 3;
```
Cost: Baseten dashboard → Usage, for the day of a night shift (input + output tokens of Muse Spark Open).

**Screen time before and with Life** (limited apps, minutes per day)
```sql
select day, sum(minutes) as minutes from usage_days
where user_id = 'USER_ID' and app in ('TikTok', 'Instagram')  -- your apps
group by day order by day;
```
