package org.ngdev.life_agent.core

enum class NudgeReason(val wire: String) {
    APPROACHING("approaching"),
    LIMIT("limit"),
    OVER("over"),
    /** A limited app was opened during a calendar event (a lecture, a meeting): the limit is tighter then. */
    EVENT("event"),
    /** Demo mode: compressed thresholds, so experiments give results in minutes. */
    DEMO("demo"),
}

data class NudgeDecision(val reason: NudgeReason, val key: String, val value: Long)

/**
 * When the agent speaks up in the middle of a session. Quiet by design: one nudge when a limit is near (80%),
 * one when it is reached, then one every 10 more minutes, and never two within a few minutes of each other.
 * [sent] remembers what was already said today (the caller saves it).
 */
object NudgePolicy {
    const val COOLDOWN_MS = 3L * 60 * 1000
    const val OVER_STEP_MINUTES = 10L
    private const val APPROACH_PERCENT = 80

    fun decide(day: String, pkg: String, usedMinutes: Int, limitMinutes: Int, nowMs: Long, lastNudgeAtMs: Long, sent: Map<String, Long>): NudgeDecision? {
        if (limitMinutes <= 0 || usedMinutes < 0) return null
        if (nowMs - lastNudgeAtMs < COOLDOWN_MS) return null

        val approachingKey = "$day|$pkg|approaching"
        val limitKey = "$day|$pkg|limit"
        val overKey = "$day|$pkg|over"

        if (usedMinutes >= limitMinutes) {
            if (!sent.containsKey(limitKey)) return NudgeDecision(NudgeReason.LIMIT, limitKey, nowMs)
            val lastOver = sent[overKey] ?: limitMinutes.toLong()
            if (usedMinutes >= lastOver + OVER_STEP_MINUTES) return NudgeDecision(NudgeReason.OVER, overKey, usedMinutes.toLong())
            return null
        }
        val threshold = (limitMinutes * APPROACH_PERCENT + 99) / 100 // rounded up
        if (usedMinutes >= threshold && !sent.containsKey(approachingKey)) return NudgeDecision(NudgeReason.APPROACHING, approachingKey, nowMs)
        return null
    }

    /**
     * During a calendar event the limit is tighter: opening a limited app at all gets one nudge per app per event.
     * [eventStartMs] identifies the event.
     */
    fun decideEvent(day: String, pkg: String, eventStartMs: Long, nowMs: Long, lastNudgeAtMs: Long, sent: Map<String, Long>): NudgeDecision? {
        if (nowMs - lastNudgeAtMs < COOLDOWN_MS) return null
        val key = "$day|$pkg|event|$eventStartMs"
        return if (sent.containsKey(key)) null else NudgeDecision(NudgeReason.EVENT, key, nowMs)
    }

    /** Old days are forgotten so the saved state stays small. */
    fun keepOnly(day: String, sent: Map<String, Long>): Map<String, Long> = sent.filterKeys { it.startsWith("$day|") }
}
