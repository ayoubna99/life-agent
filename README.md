<p align="center">
  <img src="app/assets/branding/life-icon-1024.png" width="120" alt="Life logo" />
</p>

<h1 align="center">Life</h1>

<p align="center">
  <b>An AI agent that pulls you out of doomscrolling, and learns from your results what works on you.</b><br/>
  Powered by Meta's <b>Muse Spark</b> and <b>Muse Spark Open</b>.
</p>

<p align="center">
  <img alt="Muse Spark" src="https://img.shields.io/badge/Meta-Muse%20Spark-0866FF" />
  <img alt="Muse Spark Open" src="https://img.shields.io/badge/Meta-Muse%20Spark%20Open%20(open%20weights)-0866FF" />
  <img alt="Android" src="https://img.shields.io/badge/Android-Flutter%20%2B%20Kotlin-3DDC84" />
  <img alt="Supabase" src="https://img.shields.io/badge/Backend-Supabase%20Edge%20%2B%20Postgres-3ECF8E" />
  <a href="https://github.com/OWNER/REPO/actions/workflows/tests.yml"><img alt="Tests" src="https://github.com/OWNER/REPO/actions/workflows/tests.yml/badge.svg" /></a>
</p>

<p align="center">
  <a href="#-demo">Demo</a> ·
  <a href="#-measured-on-a-real-phone">Measured</a> ·
  <a href="#-the-night-shift-lify-is-a-scientist-and-you-are-its-only-subject">The night shift</a> ·
  <a href="#-how-life-meets-the-judging-criteria">Judging criteria</a> ·
  <a href="#-architecture">Architecture</a> ·
  <a href="#-how-judges-can-verify">Verify it</a> ·
  <a href="#-privacy">Privacy</a>
</p>

---

> It's 1 AM. You said you'd sleep at 11. You've been on TikTok for two hours.
>
> A card slides over the video: **"Gym at 6. TikTok will still be here."** One button: **Pull me out**.
>
> You've never seen that sentence before. Lify wrote it last night, after studying the last 30 nudges it sent you
> and finding the ones that actually made you put the phone down.

**Life is not a planner with a chatbot on top.** It is a closed loop that runs on your phone every day:

| | |
|---|---|
| 👀 **It watches** | Real screen time from Android's usage events: which app, for how long, and when your phone went quiet last night. |
| ✋ **It steps in** | A personal card on top of the app you're stuck in, at the right moment, with one tap to get out. |
| 📏 **It measures** | Did you leave within 20 seconds? Did you tap "Pull me out"? Code on the phone records it, not the model. |
| 🧪 **It learns** | Every night Muse Spark Open reads your whole history, keeps or rejects its **theories about you**, and writes tomorrow's experiment. |

Planning your day, alarms and study material are there too, but they serve this loop. The agent's job is to get you
off the phone and onto what you said matters.

---

## 🎬 Demo

> **[▶ Watch the 3-minute demo](DEMO_URL)** · **[⬇ Download the APK](https://github.com/OWNER/REPO/releases/latest)**

<p align="center">
  <img src="docs/media/card.png" width="230" alt="A nudge card over TikTok with the Pull me out button" />
  <img src="docs/media/theories.png" width="230" alt="Lify's theories, checked by code on the user's own results" />
  <img src="docs/media/lab.png" width="230" alt="The lab notebook: every nudge, why it was picked, what happened" />
</p>
<p align="center">
  <img src="docs/media/home.png" width="230" alt="Home: today's plan, screen time, Lify is learning" />
  <img src="docs/media/plan.png" width="230" alt="Planning tomorrow with Lify" />
  <img src="docs/media/evening.png" width="230" alt="The evening notification: let's plan tomorrow" />
</p>

---

## 📈 Measured on a real phone

One person, one Samsung phone, from FROM_DATE to TO_DATE. An early signal, not proof: every number comes with its
sample size.

| What | Result |
|---|---|
| Nudges shown | TBD (TBD from the night-shift bank, TBD written live) |
| Left the app within 20 s / 2 min | TBD of TBD (TBD%) |
| Tapped "Pull me out" | TBD |
| Best idea so far | "TBD": left TBD of TBD |
| Theories checked by code | TBD kept · TBD rejected · TBD still testing |
| Model overruled by the data | TBD theories ("Lify guessed kept, your results say rejected") |
| Life vs the best single nudge style (off-policy estimate) | lift TBD, 90% interval [TBD, TBD] |
| Night shift | TBD s for the study, TBD s for the critic, about $TBD per night on Baseten |
| Screen time on the limited apps | TBD min/day in the week before → TBD min/day with Life |

How each number is computed: [docs/MEASURED.md](docs/MEASURED.md).

---

## 🧪 The night shift: Lify is a scientist, and you are its only subject

Most "AI nudge" apps send the same kind of message forever. Life runs the scientific method on one person, every
night, and **the AI is not allowed to grade its own homework**: it proposes theories, code checks them on your data.

```
          ┌───────────── THE NIGHT SHIFT · Muse Spark Open, reasoning_effort "medium" ─────────────┐
 your     │ 1. READ      every nudge it ever sent you + what you did next, your nights, your plans   │
 whole ──►│              ONE request, 1M-token context, no retrieval, no summaries in between        │
 history  │ 2. THEORIZE  testable claims: WHEN (app, time of day, weekday/weekend, how far over the  │
          │              limit, task coming up) + WHAT (tone, topic) works better than the rest       │
          │              e.g. "TikTok, at night, way over: blunt lines about tomorrow's task"         │
          │ 2b. JUDGE    CODE, not the model: Beta posteriors for "with it" vs "without it" in those  │
          │              exact moments → P(true). ≥90% kept, ≤10% rejected. "left 5/7 vs 1/6"         │
          │ 3. DESIGN    tomorrow's NUDGE BANK: ~30 short lines grouped by ANGLE (the idea behind     │
          │              them). Winning angles get new words; 1-2 new angles to test; losers dropped  │
          │ 4. CRITIC    a second pass plays your "inner skeptic" (reasoning "low") and cuts every    │
          │              line that is generic, preachy or repeated                                   │
          │ 5. CODE      ≤12 words, no minute counts, no "you're at your limit", no health language,  │
          │              never a line you've already seen. The model proposes, code validates.        │
          └──────────────────────────────────────┬─────────────────────────────────────────────────┘
                                                 ▼  the bank goes to the phone
          ┌───────────── DURING THE DAY · on the phone, instant, works offline ───────────────────────┐
          │ stuck on TikTok → Thompson sampling over ANGLES picks the idea most likely to work on you │
          │ HERE (this app, this time of day) → shows a line from it you've never seen → measures     │
          │ whether you left. The idea that works keeps coming back, always in new words.             │
          └──────────────────────────────────────┬─────────────────────────────────────────────────┘
                                                 ▼  results go back up, and the next night checks the theories
```

In the app, **"Lify's theories about you"** shows every theory with the probability **code** computed and the counts
behind it ("Checked on your data: left 5/7 with it vs 1/6 without (TikTok, at night)"). When the data disagrees with
the model, it says so: *Lify guessed "kept"; your results say "rejected"*. You also see tomorrow's ideas with "you left 4
of 6 times", Lify's **starting assumptions** about most people, and **"How Lify thought about it"**: an excerpt of the
open model's own visible reasoning.

**Why the hour and the app matter:** TikTok at 1 AM on a weekday, 40 minutes over the limit, the night before the gym,
is not TikTok on a Sunday morning. Every nudge is logged with its moment (app, time of day, weekday or weekend, near or
way over the limit, important task within 2 hours) and the tone and topic of the line. Theories are checked only on the
moments they are about.

**Learning from "most people" without anyone's data:** before you have results, each idea starts from a small
**starting assumption** (for example, a concrete next step tends to beat general advice), worth about 3 nudges. The
learning has three levels, each borrowing from the one above until it has its own data:
**most people → you everywhere → you on this app at this time.** Your results outweigh the assumptions within a day or
two. The top level can later take anonymous totals from all Life users (opt-in).

Code: [`nightshift.ts`](supabase/functions/_shared/nightshift.ts) · [`theories.ts`](supabase/functions/_shared/theories.ts) ·
[`Bank.kt`](app/android/app/src/main/kotlin/org/ngdev/life_agent/core/Bank.kt) ·
[`LimitWatcherService.kt`](app/android/app/src/main/kotlin/org/ngdev/life_agent/LimitWatcherService.kt)

---

## 🏆 How Life meets the judging criteria

### Impact (30%)
- **The problem everyone has:** hours a day lost to scrolling, and the knowledge that it's happening doesn't stop it.
  Screen-time apps show charts or block apps; people ignore the charts and switch the blocker off.
- **Life doesn't block, it persuades, and it measures whether the persuasion worked.** You can always keep scrolling;
  Life makes it a choice.
- **It works on what you care about:** every nudge points at your own goal, tomorrow's plan, or your real phone-down
  time last night ("phone down at 03:30 last night. Tonight?"). Never a generic "take a break".
- **It respects you:** at most 4 nudges per app per day, at least 20 minutes apart, spaced further out the longer you go
  over (+15, +45, +105 minutes). Your own rules ("every 30 minutes on any app, get me out") replace them.

### Meta AI tooling (25%)
Two Meta models, each used for what it is uniquely good at:

| Model | Job in Life | Why this model |
|---|---|---|
| **Muse Spark** | The agent: planning chats with 18 tools (calendar, alarms, app limits, web search, PDFs, images, documents), voice input, photo reading | Agentic tool calling, multimodal input |
| **Muse Spark Open** | **The night shift** (theories + nudge bank + critic), live nudges, the evening "let's plan tomorrow" notification | **1M-token context:** reads your whole history at once instead of retrieval. **Controllable reasoning:** thinks hard at night (`medium`), almost not at all for live nudges (`low`). **Visible reasoning:** shown in the app as "how Lify thought about it". **Open weights:** the same pipeline can be self-hosted so your history never leaves your servers. |

- Each model is the other's fallback, so a nudge still arrives if one is down.
- Muse Voice Transcribe turns what you say into text; Muse Spark reads photos and scanned PDFs; Muse Image makes pictures.
- Code: [`muse.ts`](supabase/functions/_shared/muse.ts) (routing, failover, reasoning effort),
  [`nudge.ts`](supabase/functions/_shared/nudge.ts), [`evening.ts`](supabase/functions/_shared/evening.ts).

### Technical depth (20%)
The model writes; **code decides and measures**. Nothing below can be changed by prompting the model.

1. **Contextual Thompson sampling with a 3-level prior (phone, Kotlin):** each idea has a Beta posterior for this app at
   this time of day. Its prior comes from your other moments, and theirs from a starting assumption about most people
   (hierarchical shrinkage), so a new user and a new moment start from what is already known.
2. **Theories judged by code (server):** the model's claims must be testable (moments + property). Code compares
   "with it" vs "without it" in exactly those moments with Beta posteriors and 4000 seeded joint draws, and sets the
   status and confidence. The tests show the model's own "kept 95%" being overruled by the data.
3. **Propensity logging:** the chance of each choice is computed by Monte Carlo (400 draws) and logged with the result.
4. **Off-policy evaluation (server):** self-normalised inverse propensity scoring estimates how "always send style X"
   would have done on the same moments. Life's lift over the best fixed nudge comes with a 90% bootstrap interval. The
   tests check that the estimator recovers known rates from heavily biased logs.
5. **Strategy memory:** each evening review writes a new strategy version. The server refuses any change that doesn't
   cite a number, and every version is kept (day 1 vs. today).
6. **Real Android engineering:**
   - a foreground watcher reading `UsageStatsManager` events;
   - a custom overlay card with a "Pull me out" button. On phones that hide overlays it falls back to a heads-up notification automatically;
   - a watchdog alarm that restarts the watcher if the phone kills it;
   - exact alarms and real Clock-app alarms;
   - phone-down detection from unlock events, which ignores notification wake-ups, alarms and calls.
7. **Production basics:**
   - anonymous auth with row-level security on every table;
   - per-user and global daily caps;
   - keys only in server secrets;
   - every link checked before it is saved;
   - 402 automated tests.

Code: [`Experiment.kt`](app/android/app/src/main/kotlin/org/ngdev/life_agent/core/Experiment.kt) ·
[`experiments.ts`](supabase/functions/_shared/experiments.ts) · [`strategy.ts`](supabase/functions/_shared/strategy.ts) ·
[`Nights.kt`](app/android/app/src/main/kotlin/org/ngdev/life_agent/core/Nights.kt)

### Demo (25%)
The [demo](#-demo) follows one evening:
- doomscrolling at night;
- the "Hey Jake, let's plan tomorrow" notification;
- planning tomorrow by voice;
- a nudge card pulling him out;
- the lab notebook and Lify's theories updating from his own results.

---

## 🔬 Why nudges can work

Life is built on findings from behaviour research, not on the idea that an AI message is enough by itself:

- **A pause before scrolling cuts use.** In a field study of the one sec app, a short delay before opening a social
  media app reduced how often people opened it (Grüning, Riedel & Lorenz-Spreen, *PNAS*, 2023). Life's card is that
  pause, at the moment it matters, with a way out.
- **Much social media use is more than people want.** People spent more time on social media than they themselves
  said they wanted, and tools that helped them limit it reduced use (Allcott, Gentzkow & Song, *American Economic
  Review*, 2022). Life helps with exactly that gap.
- **"When X, I will do Y" plans work.** Implementation intentions have a medium-to-large effect on reaching goals
  (Gollwitzer & Sheeran, *Advances in Experimental Social Psychology*, 2006). Lify's evening planning and your own rules
  ("whenever I'm 30 minutes on an app, pull me out") are implementation intentions.
- **Timing and personalisation matter.** Just-in-time adaptive interventions send support at the moment of need and
  adapt to the person (Nahum-Shani et al., *Annals of Behavioral Medicine*, 2018). HeartSteps tested this kind of
  in-the-moment message with micro-randomised trials (Klasnja et al., 2019). Life's watcher, its Thompson sampling and
  its logged chances of each choice follow the same design.
- **What Life does not claim:** it gives no health advice and makes no sleep or mental-health claims, and its own
  numbers are from one person. They are shown as an early signal, with sample sizes.

---

## ✅ What Life is not

| | |
|---|---|
| ❌ **Not a medical or mental-health app** | Lify talks about phone time and your plans only. It never gives health, sleep or therapy advice. Night data is "your phone went quiet at 03:12", never a sleep claim. The night-shift validator rejects health language in nudges. |
| ❌ **Not basic RAG** | No vector store, no retrieval. Muse Spark Open reads your whole history in one 1M-token request. |
| ❌ **Not a dashboard** | The numbers exist to drive actions on the phone (cards, alarms, limits), and every number shown says how many tries it's based on. |
| ❌ **Not an education chatbot** | It can make a study sheet for a task in your plan, but it doesn't teach. It gets you to the task. |
| ❌ **Not a fixed-message notifier** | No hard-coded nudge text anywhere. If the bank is empty and the model can't be reached, no nudge is sent and nothing is measured. |

---

## ✨ Everything Life does

- **Plans tomorrow with you** (text or voice, a notification one hour before your bedtime). It checks your calendar,
  estimates task durations itself, and puts tasks and alarms on the phone the moment the plan is saved.
- **Picks the right alarm per task:** a real Clock alarm for things away from the screen (gym, prayer, leaving home),
  or an in-app alarm that opens the task's own screen with everything ready (links, PDFs, pictures, steps, chat notes).
- **Makes what you need:** study sheets as real PDFs and pictures. It reads web pages, PDFs and photos you send, and searches the web with sources.
- **Your own rules:** "whenever I'm on any app for 30 minutes straight, pull me out" becomes a rule on the phone.
- **Knows your nights:** when the phone went quiet and was picked up again, measured from unlock events.
  "Phone down at 03:30 last night. Tonight?"
- **Learns:** the night shift, the lab notebook (every nudge, why it was picked, what you did next), and the strategy
  memory with every version kept.
- **Talks:** voice in (Muse Voice Transcribe), voice out.
- **Check Lify:** a self-diagnosis screen showing the account, server, watcher, battery and pop-up permissions, your last
  nights, and a log of every nudge (shown as a card or a notification, or skipped and why), with Fix buttons.

---

## 🏗 Architecture

```
 Android phone                                              Supabase                         Meta
┌──────────────────────────────────────────┐   HTTPS   ┌─────────────────────────┐      ┌───────────────────┐
│ Flutter UI: home, chat, task screens,    │ ───────►  │ Edge Function "agent"   │ ───► │ Muse Spark        │
│ lab notebook, theories, Check Lify       │           │  agent loop + 3 modes   │      │  (chat, tools)    │
│                                          │           │  server tools           │      ├───────────────────┤
│ Device tools: create_task, set_app_limit,│ ◄──────── │  nudge · evening        │ ───► │ Muse Spark Open   │
│ schedule_alarm, get_calendar, rules      │  tool     │  NIGHT SHIFT            │      │  (Baseten)        │
│                                          │  calls    │  experiments + OPE      │      ├───────────────────┤
│ Kotlin: usage watcher (foreground),      │           ├─────────────────────────┤      │ Voice Transcribe  │
│ Thompson sampling, nudge bank, overlay   │           │ Postgres + RLS: plans,  │      └───────────────────┘
│ card, alarms, phone-down nights          │           │ messages, strategies,   │
└──────────────────────────────────────────┘           │ experiments, nights,    │
                                                       │ night_shifts · Storage  │
                                                       └─────────────────────────┘
```

- **Three agent modes, one agent:**
  - **planning** (evening): asks until it has everything, then saves the plan;
  - **execute** (morning): sets up the day on the phone through device tool calls;
  - **review** (evening): compares the plan with real usage and updates the strategy.
- **The server remembers the conversation;** the phone sends only new messages and tool results.
- **API reference:** [docs/API.md](docs/API.md).

| Path | What |
|---|---|
| `supabase/functions/_shared/` | prompts, tools, agent loop, Muse clients, night shift, experiments and evaluation |
| `supabase/migrations/` | Postgres schema with row-level security |
| `tests/` | backend tests with a scripted model and an in-memory store (no network, no keys) |
| `app/lib/` | Flutter: screens, agent client, device tools, plan applier |
| `app/android/.../kotlin/` | Kotlin: watcher, Thompson sampling, nudge bank, overlay card, alarms, nights |
| `docs/API.md` | every request and answer |

---

## 🚀 Run it

**Backend** (Node 22.6+ and the Supabase CLI):
```
npm install
npm test
npx supabase link --project-ref YOUR_PROJECT_REF
npx supabase db push
npx supabase secrets set MUSE_BASE_URL=... MUSE_API_KEY=... MUSE_MODEL=... OPEN_API_KEY=...
npx supabase functions deploy agent
```
Turn on *Anonymous sign-ins* in Supabase Authentication.

**App** (Flutter 3.41+, Android SDK):
```
cd app
flutter pub get
flutter run --release --dart-define=SUPA_KEY=sb_publishable_YOUR_KEY
```
See [app/README.md](app/README.md) for permissions and first run.

---

## 🔍 How judges can verify

1. **Install the [APK](https://github.com/OWNER/REPO/releases/latest)** on an Android phone (Android 10+).
2. Finish the 5 onboarding slides. Allow **Usage access**, **Show over other apps** and **Notifications**. In Settings
   → Check Lify, set **Battery** to unrestricted.
3. **Talk to Lify:** tap *Plan tomorrow* and plan by voice or text. Saving the plan puts tomorrow's tasks and alarms on
   the phone right away (check your Clock app).
4. **See a nudge:** Settings → Experiments → turn on *Demo mode*, then open one of the apps you chose for about 20
   seconds. A card slides in with **Pull me out**.
5. **See the night shift:** Home → TEST → **Night shift (test)** (up to 2 minutes), then open *Lify's theories about
   you*: theories with the verdict code computed, tomorrow's lines, and "How Lify thought about it".
6. **See everything that happened:** Settings → Check Lify → *What the watcher did*.
7. **Run the tests:** `npm test` (backend), `cd app && flutter test` (app). They also run on every push:
   [GitHub Actions](https://github.com/OWNER/REPO/actions/workflows/tests.yml).

The judging build uses a shared demo backend with a daily cap per user, so a judge's account works on its own.

---

## 🔒 Privacy

| What | Where it goes | Kept |
|---|---|---|
| Screen time: minutes per app per day (never what you watch) | Supabase (your private rows, row-level security) | Until deleted |
| When the phone went quiet each night (two times, no content) | Supabase | Until deleted |
| Plans, chats, your settings (name, sleep time, apps, focus) | Supabase; chats go to **Muse Spark** (Meta) to answer | Until deleted |
| Live nudges and the evening notification: your plan, settings and the last few nudge lines | **Muse Spark Open on Baseten**, to write the line | Not stored by Life outside Supabase |
| Each nudge: app name, time, the words, whether you left | Supabase | Until deleted |
| **Night shift:** the last 30 days of the rows above, sent once a night | **Muse Spark Open on Baseten** (inference only) | Not stored by Life outside Supabase; see Baseten's terms |
| Voice recordings | Transcribed by Muse Voice Transcribe, then **deleted** | Not kept |
| Photos, PDFs you send | Read, kept as text; photos deleted after reading | Files: 3 days |

- **Never collected:** the content of other apps, what you watch, messages, location, contacts. The watcher only sees which
  app is in front and for how long, from Android's usage statistics.
- **Accounts are anonymous:** no email, no phone number. The account lives on your phone.
- **Delete your data:** send the first 8 characters of your account id (Settings → Check Lify → Account) to
  CONTACT. Deleting the account removes every row about you (every table is linked to it and deleted with it) and
  your files. A one-tap "Delete my data" button is next on the list.
- **"Totals from all users"** is a design option only. Nothing is pooled today. If it is ever built, it will be
  opt-in and share only counts per kind of nudge, nothing personal.
- **Open weights:** because Muse Spark Open's weights are open, the night shift can run on servers you control, so your
  history never leaves them. The code needs only a different `OPEN_BASE_URL`.

---

## 📊 Status

- **Tested end to end on a real Android phone (Samsung):**
  - planning chats with live Muse Spark tool calls;
  - Muse Spark Open on Baseten;
  - the night shift and the nudge bank;
  - the nudge cards and "Pull me out";
  - screen time and phone-down nights;
  - the evening notification;
  - alarms and calendar;
  - voice;
  - Check Lify.
- **Automated tests:** 402 in all: 189 backend, 148 Flutter, 65 Kotlin (JVM). The Android code compiles against the real Android 15 classes.
- **Honest about the numbers:** results in the app are labelled "early signal" with sample sizes. One person over a few
  days is not proof, and Life says so.

---

## 📝 Hackathon disclosure

Before the hackathon I built an early prototype of this idea: PROTOTYPE_DESCRIPTION. It had **no agentic or AI
features**.

This repository starts at the tag [`hackathon-start`](https://github.com/OWNER/REPO/releases/tag/hackathon-start), its
first commit.

**Everything in this repository was built during the hackathon.** It is a new codebase:
- every screen, the UI and the logo are brand new;
- the stack is different;
- none of the prototype's code is reused.

The agent, the night shift, the experiments, the watcher and the evaluation did not exist before.
