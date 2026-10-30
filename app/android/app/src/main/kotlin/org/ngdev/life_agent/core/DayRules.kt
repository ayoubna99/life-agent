package org.ngdev.life_agent.core

/** One event from the phone's calendar. */
data class CalEvent(val title: String, val startMs: Long, val endMs: Long, val allDay: Boolean, val busy: Boolean)

/** One task from the app's Today list, as much as the watcher needs. */
data class TaskLite(val title: String, val minutes: Int, val startTime: String?, val firstStep: String?, val done: Boolean)

object DayRules {
    /** The event going on now that should tighten limits: timed (not all day) and marked busy. */
    fun currentEvent(events: List<CalEvent>, nowMs: Long): CalEvent? =
        events.filter { !it.allDay && it.busy && nowMs >= it.startMs && nowMs < it.endMs }.minByOrNull { it.endMs }

    /** Same rule as the app's "Next:" card: the earliest one still to come, else one without a time, else the most overdue. */
    fun nextTask(tasks: List<TaskLite>, nowHHmm: String): TaskLite? {
        val pending = tasks.filter { !it.done }
        if (pending.isEmpty()) return null
        val timed = pending.filter { it.startTime != null }.sortedBy { it.startTime }
        timed.firstOrNull { it.startTime!! >= nowHHmm }?.let { return it }
        pending.firstOrNull { it.startTime == null }?.let { return it }
        return timed.first()
    }
}

/** The user's own reminder: whenever they spend [minutes] in a row on an app ([pkg] "*" = any app), remind them to [ask]. */
data class SessionRule(val label: String, val pkg: String, val minutes: Int, val ask: String)

object SessionRules {
    const val ANY = "*"

    /**
     * The rule that fires now for [pkg], whose current session started at [sinceMs]: once at [SessionRule.minutes], again at
     * twice that, and so on, never twice for the same step. A rule for this app wins over the any-app rule. Returns the rule
     * and the key to remember (it starts with [day], so old ones are forgotten with the day).
     */
    fun due(rules: List<SessionRule>, pkg: String, sinceMs: Long?, nowMs: Long, day: String, fired: Set<String>): Pair<SessionRule, String>? {
        if (sinceMs == null) return null
        val rule = rules.firstOrNull { it.pkg == pkg } ?: rules.firstOrNull { it.pkg == ANY } ?: return null
        val step = (nowMs - sinceMs) / 60_000L / rule.minutes
        if (step < 1) return null
        val key = "$day|$pkg|rule|$sinceMs|$step"
        return if (key in fired) null else rule to key
    }
}

/** The bold first line of a nudge card: what happened, in plain words ("2 hours on TikTok"). The agent writes the rest. */
object NudgeTitle {
    fun duration(minutes: Int): String {
        val h = minutes / 60
        val m = minutes % 60
        return when {
            h == 0 -> "$m min"
            m == 0 -> if (h == 1) "1 hour" else "$h hours"
            else -> "$h h $m min"
        }
    }

    fun onApp(minutes: Int, app: String): String = "${duration(minutes)} on $app"
}
