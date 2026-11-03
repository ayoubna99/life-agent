# Benchmark: does Life's learning loop work?

Run it yourself: `npm run bench` (Node 22+, no API key, no phone, about 18 s). Seeded: every run
gives these exact numbers. More people: `PEOPLE=1000 npm run bench`.

**The people are simulated**, so the right answer is known: each of 300 people has a hidden chance of leaving the app for
each of 6 nudge ideas. One idea works best on them, and it is often not the one that works for most people. For half of
them, a different idea works at night. Real people are messier; this checks that the machinery finds the truth when
there is one.

The theory judge, the off-policy estimator and the line checks are Life's real server code. The phone's picker is
mirrored from `core/Bank.kt` with the same formula and constants.

## 1. Does it find what works on each person?

How often each person left the app after a nudge, over 240 simulated nudges each (in real use, about 30 nudges is a week):

| Policy | Nudges 1-30 | 31-60 | 61-120 | 121-240 |
|---|---|---|---|---|
| Random idea each time | 34% | 35% | 35% | 35% |
| Always "what works for most people" (a fixed app) | 34% | 34% | 34% | 34% |
| **Life** (Thompson sampling, 3-level prior, per time of day) | **37%** | **39%** | **41%** | **43%** |
| Knowing the hidden answer (best possible) | 53% | 52% | 53% | 53% |

- **Life keeps improving; a fixed app stays flat.** By nudges 121-240, people leave after **43%** of Life's
  nudges vs 34% for the fixed one: **26% more often**, and it closes
  48% of the gap to the best possible.
- Life names each person's best idea correctly for **44%** after 30 nudges, **53%** after 60 nudges, **62%** after 120 nudges, **73%** after 240 nudges.
- For the people whose best idea at night is different, it gets the night one right for 27% after 60 nudges
  and 55% after 240 (night is only part of their nudges, so it takes longer).
- For 86% of the people, their best idea is not the one that works for most people, so a fixed app never finds it.

## 2. Are theories judged right?

Every idea, in all moments and at night, is put to Life's real `judge()` as a theory ("this idea works better here than
the others"), on each person's first 60 nudges. The truth is known from the hidden rates.

| | |
|---|---|
| Theories judged | 3521 |
| Kept, and actually true | **324 of 411 (79%)** |
| Rejected, and actually false | **213 of 230 (93%)** |
| Still "testing" (not enough evidence either way) | 2880 |
| Clearly false (10+ points worse) but kept anyway | **17 of 1096** |

Without this check, every theory the model wrote would be shown as a fact. Here a theory is kept only when the person's results
say so, and the ones without enough evidence stay "testing" instead of being guessed.

## 3. Does the second opinion tell the truth?

Off-policy evaluation (Life's real `evaluatePolicy()`) estimates "what if Life had always sent style X?" from the logged
choice probabilities alone. Checked on 300 simulated people with 70 nudges each (about what the author has):

| | |
|---|---|
| Average error of each style's estimate | **8.6 points** |
| Picks the truly best style | **61%** of people |

## 4. Do the guards stop bad lines?

A hand-written set of 26 drafts of the kind a model can write (invented numbers, meter talk, health words, a line
already sent, a reminder that drifts off the user's ask), each with the right answer, through Life's real checks.

| | |
|---|---|
| Bad drafts stopped before reaching the phone | **16 of 16** |
| Good drafts wrongly stopped | 0 of 10 |

Code: [`bench/bench.ts`](../bench/bench.ts) · tests: [`tests/bench.test.ts`](../tests/bench.test.ts)
