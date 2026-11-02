package org.ngdev.life_agent.core

import java.util.Random

/**
 * Moments: nudges that carry one fact that is true only for this person, right now. CODE computes every fact from the
 * phone's own data (usage events, unlocks, the plan, the phone-down time); Muse Spark Open only phrases them, and the
 * server checks that every number in its line is one of these facts. If the model cannot be reached, the sentence
 * built here from the same facts is shown. Which moment to use is learned like the night shift's ideas (Thompson
 * sampling, the keys are "moment_<kind>"), and about 1 in 10 is held back on purpose to measure what happens without
 * a nudge.
 */
enum class MomentKind(val wire: String) {
    LOST_INTENT("lost_intent"), // "You picked up your phone for WhatsApp 14 minutes ago. Since then: Instagram, then TikTok."
    EXIT_POINT("exit_point"), // "You usually leave TikTok around minute 6. This is minute 9."
    PLANNED_NOW("planned_now"), // "You planned "Finish chapter 3" for 21:00. It's 21:10."
    PHONE_DOWN("phone_down"), // "You said phone down at 23:00. Tomorrow starts with Gym at 07:00."
    ;

    val key: String get() = "moment_$wire"
}

/** What the card's button does: open an app ("app:<package>"), a task ("task:<title>"), or just close ("done"). */
data class MomentAction(val label: String, val open: String)

data class MomentNudge(
    val kind: MomentKind,
    val title: String,
    val facts: Map<String, String>,
    val text: String,
    val action: MomentAction,
)

object Moments {
    /** Lost intent: at least this long since the unlock (minutes). */
    const val LOST_AFTER_MIN = 8

    /** Exit point: sessions needed before "usually" can be said. */
    const val MIN_SESSIONS = 5

    /** Planned now: a task that starts within this many minutes either side of now. */
    const val PLANNED_WINDOW_MIN = 30

    /** Phone-down: from 10 minutes before the phone-down time until 3 hours after. */
    const val PHONE_DOWN_BEFORE_MIN = 10
    const val PHONE_DOWN_AFTER_MIN = 180

    /** About 1 in 10 moments is held back (no card) to measure what the person does without a nudge. */
    const val HOLDOUT = 0.1

    private fun minutes(hhmm: String) = hhmm.substring(0, 2).toInt() * 60 + hhmm.substring(3).toInt()

    /**
     * The person unlocked the phone to use one app (not a feed) and drifted into feeds since. [events] must include
     * the unlock events; [skip] are packages that are not a choice (launcher, system UI, Life itself).
     */
    fun lostIntent(events: List<UsageEvent>, nowMs: Long, front: String, feeds: Set<String>, skip: Set<String>, label: (String) -> String, minMinutes: Int = LOST_AFTER_MIN): MomentNudge? {
        val sorted = events.sortedBy { it.timeMs }
        val unlock = sorted.lastOrNull { it.type == UsageEventType.UNLOCK && it.timeMs <= nowMs } ?: return null
        val mins = ((nowMs - unlock.timeMs) / 60_000L).toInt()
        if (mins < minMinutes || mins > 180 || front !in feeds) return null
        val seq = ArrayList<String>()
        for (e in sorted) {
            if (e.timeMs < unlock.timeMs || e.type != UsageEventType.FOREGROUND || e.pkg in skip) continue
            if (seq.lastOrNull() != e.pkg) seq.add(e.pkg)
        }
        val first = seq.firstOrNull() ?: return null
        if (first in feeds) return null // they opened the feed on purpose: no lost intent
        val drift = seq.drop(1).filter { it in feeds }.distinct()
        if (drift.isEmpty()) return null
        val start = label(first)
        val path = drift.take(3).joinToString(", then ") { label(it) }
        return MomentNudge(
            MomentKind.LOST_INTENT,
            "$mins min since you unlocked",
            mapOf("opened_for" to start, "minutes_since_unlock" to "$mins", "since_then" to path),
            "You picked up your phone for $start $mins minutes ago. Since then: $path.",
            MomentAction("Back to $start", "app:$first"),
        )
    }

    /** The lengths (whole minutes) of the finished sessions on [pkg], short breaks merged as in [OutcomeMeter.sessionSince]. */
    fun sessionLengths(events: List<UsageEvent>, pkg: String, gapMs: Long = OutcomeMeter.SESSION_GAP_MS): List<Int> {
        val out = ArrayList<Int>()
        var start: Long? = null
        var leftAt: Long? = null
        var inFront = false
        fun close() {
            val s = start ?: return
            val end = leftAt ?: return
            val m = ((end - s) / 60_000L).toInt()
            if (m >= 1) out.add(m)
        }
        for (e in events.sortedBy { it.timeMs }) {
            val comesIn = e.type == UsageEventType.FOREGROUND && e.pkg == pkg
            val goesOut = (e.type == UsageEventType.FOREGROUND && e.pkg != pkg) || (e.type == UsageEventType.BACKGROUND && e.pkg == pkg)
            if (comesIn && !inFront) {
                if (start == null || leftAt == null || e.timeMs - leftAt!! > gapMs) {
                    close()
                    start = e.timeMs
                }
                inFront = true
            } else if (goesOut && inFront) {
                inFront = false
                leftAt = e.timeMs
            }
        }
        if (!inFront) close() // a session still going on is not finished
        return out
    }

    /** "You usually leave TikTok around minute 6. This is minute 9.": only with enough finished sessions to say "usually". */
    fun exitPoint(pastSessions: List<Int>, currentMinutes: Int, appLabel: String, action: MomentAction, minSessions: Int = MIN_SESSIONS): MomentNudge? {
        if (pastSessions.size < minSessions) return null
        val s = pastSessions.sorted()
        val usual = s[s.size / 2]
        if (usual > 60 || currentMinutes < usual + maxOf(3, usual / 2)) return null
        return MomentNudge(
            MomentKind.EXIT_POINT,
            "Minute $currentMinutes on $appLabel",
            mapOf("app" to appLabel, "usual_minute" to "$usual", "this_minute" to "$currentMinutes", "sessions_counted" to "${s.size}"),
            "You usually leave $appLabel around minute $usual. This is minute $currentMinutes.",
            action,
        )
    }

    /** A task from today's plan starts (or started) about now, and they are on a feed instead. */
    fun plannedNow(tasks: List<TaskLite>, nowHHmm: String): MomentNudge? {
        val now = minutes(nowHHmm)
        val t = tasks.filter { !it.done && it.minutes >= 15 && it.startTime != null && Math.abs(minutes(it.startTime) - now) <= PLANNED_WINDOW_MIN }
            .minByOrNull { Math.abs(minutes(it.startTime!!) - now) } ?: return null
        return MomentNudge(
            MomentKind.PLANNED_NOW,
            "Planned for ${t.startTime}",
            mapOf("task" to t.title, "planned_time" to t.startTime!!, "time_now" to nowHHmm),
            "You planned \"${t.title}\" for ${t.startTime}. It's $nowHHmm.",
            MomentAction("Open: ${t.title}".take(40), "task:${t.title}"),
        )
    }

    /** Past the phone-down time they chose, on a feed: tomorrow's first task (no sleep advice, only their own plan). */
    fun phoneDown(sleepHHmm: String?, nowHHmm: String, tomorrow: List<TaskLite>): MomentNudge? {
        if (sleepHHmm == null) return null
        val since = (minutes(nowHHmm) - minutes(sleepHHmm) + 1440) % 1440
        val inWindow = since <= PHONE_DOWN_AFTER_MIN || since >= 1440 - PHONE_DOWN_BEFORE_MIN
        if (!inWindow) return null
        val first = tomorrow.filter { !it.done && it.startTime != null }.minByOrNull { it.startTime!! }
        val facts = linkedMapOf("phone_down_time" to sleepHHmm, "time_now" to nowHHmm)
        val text = if (first != null) {
            facts["tomorrow_first"] = first.title
            facts["tomorrow_first_time"] = first.startTime!!
            "You said phone down at $sleepHHmm. Tomorrow starts with ${first.title} at ${first.startTime}."
        } else {
            "You said phone down at $sleepHHmm. It's $nowHHmm."
        }
        return MomentNudge(MomentKind.PHONE_DOWN, "Phone-down was $sleepHHmm", facts, text, MomentAction("Done for tonight", "done"))
    }

    /** Which eligible moment to use: Thompson sampling over their results (same three-level prior as the bank's ideas). */
    fun pick(eligible: List<MomentNudge>, global: Map<String, ArmStat>, local: Map<String, ArmStat>, rnd: Random): Pair<MomentNudge, Double>? {
        if (eligible.isEmpty()) return null
        val post = eligible.map { NudgeBank.posterior(global[it.kind.key], local[it.kind.key], 0.32) }
        fun draw(): Int = post.indices.maxByOrNull { Beta.sample(post[it].first, post[it].second, rnd) }!!
        val chosen = draw()
        var same = 0
        repeat(NudgeBank.PROPENSITY_DRAWS) { if (draw() == chosen) same++ }
        return eligible[chosen] to maxOf(same, 1).toDouble() / NudgeBank.PROPENSITY_DRAWS
    }
}
