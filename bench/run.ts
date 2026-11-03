// npm run bench: prints the results and writes them to docs/BENCHMARK.md. Seeded, so every run gives the same numbers.
import { writeFileSync } from 'node:fs';

import { BLOCKS, DRAFTS, guards, learning, offPolicy, theories } from './bench.ts';

const PEOPLE = Number(process.env.PEOPLE ?? 300);
const NUDGES = 60;
const pct = (x: number) => `${Math.round(x * 100)}%`;
const t0 = Date.now();

const L = learning(PEOPLE);
const last = BLOCKS.length - 1;
const row = (xs: number[]) => xs.map(pct).join(' | ');
const T = theories(PEOPLE, NUDGES);
const O = offPolicy(PEOPLE, 70);
const G = guards();
const secs = ((Date.now() - t0) / 1000).toFixed(1);

const md = `# Benchmark: does Life's learning loop work?

Run it yourself: \`npm run bench\` (Node 22+, no API key, no phone, about ${Math.max(1, Math.round(Number(secs)))} s). Seeded: every run
gives these exact numbers. More people: \`PEOPLE=1000 npm run bench\`.

**The people are simulated**, so the right answer is known: each of ${PEOPLE} people has a hidden chance of leaving the app for
each of 6 nudge ideas. One idea works best on them, and it is often not the one that works for most people. For half of
them, a different idea works at night. Real people are messier; this checks that the machinery finds the truth when
there is one.

The theory judge, the off-policy estimator and the line checks are Life's real server code. The phone's picker is
mirrored from \`core/Bank.kt\` with the same formula and constants.

## 1. Does it find what works on each person?

How often each person left the app after a nudge, over 240 simulated nudges each (in real use, about 30 nudges is a week):

| Policy | ${BLOCKS.map((b) => b.label).join(' | ')} |
|---|${BLOCKS.map(() => '---').join('|')}|
| Random idea each time | ${row(L.blocks.random)} |
| Always "what works for most people" (a fixed app) | ${row(L.blocks.generic)} |
| **Life** (Thompson sampling, 3-level prior, per time of day) | **${L.blocks.life.map(pct).join('** | **')}** |
| Knowing the hidden answer (best possible) | ${row(L.blocks.oracle)} |

- **Life keeps improving; a fixed app stays flat.** By nudges 121-240, people leave after **${pct(L.blocks.life[last])}** of Life's
  nudges vs ${pct(L.blocks.generic[last])} for the fixed one: **${Math.round((L.blocks.life[last] / L.blocks.generic[last] - 1) * 100)}% more often**, and it closes
  ${pct((L.blocks.life[last] - L.blocks.generic[last]) / (L.blocks.oracle[last] - L.blocks.generic[last]))} of the gap to the best possible.
- Life names each person's best idea correctly for ${L.foundBest.map((f, i) => `**${pct(f)}** after ${BLOCKS[i].to} nudges`).join(', ')}.
- For the people whose best idea at night is different, it gets the night one right for ${pct(L.foundNightBest[1])} after 60 nudges
  and ${pct(L.foundNightBest[last])} after 240 (night is only part of their nudges, so it takes longer).
- For ${pct(L.notGeneric)} of the people, their best idea is not the one that works for most people, so a fixed app never finds it.

## 2. Are theories judged right?

Every idea, in all moments and at night, is put to Life's real \`judge()\` as a theory ("this idea works better here than
the others"), on each person's first ${NUDGES} nudges. The truth is known from the hidden rates.

| | |
|---|---|
| Theories judged | ${T.theories} |
| Kept, and actually true | **${T.keptTrue} of ${T.kept} (${pct(T.keptTrue / Math.max(1, T.kept))})** |
| Rejected, and actually false | **${T.rejectedFalse} of ${T.rejected} (${pct(T.rejectedFalse / Math.max(1, T.rejected))})** |
| Still "testing" (not enough evidence either way) | ${T.testing} |
| Clearly false (10+ points worse) but kept anyway | **${T.clearlyFalseKept} of ${T.clearlyFalse}** |

Without this check, every theory the model wrote would be shown as a fact. Here a theory is kept only when the person's results
say so, and the ones without enough evidence stay "testing" instead of being guessed.

## 3. Does the second opinion tell the truth?

Off-policy evaluation (Life's real \`evaluatePolicy()\`) estimates "what if Life had always sent style X?" from the logged
choice probabilities alone. Checked on ${O.people} simulated people with 70 nudges each (about what the author has):

| | |
|---|---|
| Average error of each style's estimate | **${(O.meanError * 100).toFixed(1)} points** |
| Picks the truly best style | **${pct(O.sameBest)}** of people |

## 4. Do the guards stop bad lines?

A hand-written set of ${DRAFTS.length} drafts of the kind a model can write (invented numbers, meter talk, health words, a line
already sent, a reminder that drifts off the user's ask), each with the right answer, through Life's real checks.

| | |
|---|---|
| Bad drafts stopped before reaching the phone | **${G.stopped} of ${G.bad}** |
| Good drafts wrongly stopped | ${G.wronglyStopped} of ${G.good} |
${G.missed.length ? `\nMissed: ${G.missed.map((d) => `"${d.text}" (${d.why})`).join('; ')}\n` : ''}
Code: [\`bench/bench.ts\`](../bench/bench.ts) · tests: [\`tests/bench.test.ts\`](../tests/bench.test.ts)
`;

writeFileSync(new URL('../docs/BENCHMARK.md', import.meta.url), md);
console.log(md);
console.log(`(${secs} s)`);
