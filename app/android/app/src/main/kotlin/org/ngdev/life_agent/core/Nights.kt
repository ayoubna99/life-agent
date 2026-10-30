package org.ngdev.life_agent.core

import java.util.Calendar
import java.util.TimeZone

/** One night of phone use: when the phone went quiet ("phone-down") and when it was first picked up again. Not sleep. */
data class PhoneNight(val night: String, val down: String, val up: String)

object PhoneNights {
    /** The night's quiet stretch, peeks included, must last at least this long to count. */
    const val MIN_GAP_MS = 3L * 60 * 60 * 1000

    /** A pause in use at least this long is "quiet". */
    const val QUIET_MS = 20L * 60 * 1000

    /** Use this short between two quiet stretches is a peek (the time, a sip of water, a snooze): the night goes on. */
    const val PEEK_MS = 10L * 60 * 1000

    /** A quiet stretch next to a peek counts as the night only if it is this long (else that use was real use). */
    const val ASLEEP_BEFORE_MS = 2L * 60 * 60 * 1000

    /** One session without an end event (the phone died, the event was lost) counts as use for at most this long. */
    const val MAX_SESSION_MS = 4L * 60 * 60 * 1000

    /** The hours most people are asleep, from 01:00 to 06:00: a quiet stretch over them weighs double. */
    const val CORE_FROM_H = 1
    const val CORE_TO_H = 6

    /** Apps that come to the front by themselves: the alarm ringing, a call coming in. That is not the person using the phone. */
    fun ignored(pkg: String): Boolean {
        val p = pkg.lowercase()
        return p.contains("clock") || p.contains("alarm") || p.contains("incallui") || p.contains("systemui") ||
            p == "com.android.server.telecom" || p.contains("dialer")
    }

    /**
     * For each of the last [nights] evenings, from 18:00 to 14:00 the next day. Use is the time an app is in front (from
     * coming to the front until it goes to the back: a long video at 2 am is use, not quiet), alarms and incoming calls
     * left out. The night is the quiet stretch (no use for 20+ minutes) that is longest, counting the hours over
     * 01:00-06:00 twice: so a quiet morning after the alarm does not beat the real night. It grows across short peeks (at
     * most 10 minutes of use: the time, a sip of water) when the quiet on the other side is 2+ hours; forward only before
     * 06:00, since a peek after that is waking up. It must
     * last 3+ hours. Phone-down is its start, pick-up its end. A night still going on, or without such a stretch, is left out.
     */
    fun detect(events: List<UsageEvent>, nowMs: Long, tz: TimeZone, nights: Int = 7): List<PhoneNight> {
        val sorted = events.filter { !ignored(it.pkg) }.sortedBy { it.timeMs }
        val out = ArrayList<PhoneNight>()
        val today = UsageAggregator.startOfDay(nowMs, tz)
        for (back in 1..nights) {
            val evening = Calendar.getInstance(tz).apply { timeInMillis = today; add(Calendar.DAY_OF_YEAR, -back); set(Calendar.HOUR_OF_DAY, 18) }.timeInMillis
            val next = Calendar.getInstance(tz).apply { timeInMillis = evening; add(Calendar.DAY_OF_YEAR, 1) }
            val end = (next.clone() as Calendar).apply { set(Calendar.HOUR_OF_DAY, 14) }.timeInMillis
            val core = (next.clone() as Calendar).apply { set(Calendar.HOUR_OF_DAY, CORE_FROM_H) }.timeInMillis to
                (next.clone() as Calendar).apply { set(Calendar.HOUR_OF_DAY, CORE_TO_H) }.timeInMillis
            val stop = minOf(end, nowMs)
            val inside = sorted.filter { it.timeMs in evening..stop }
            val busy = if (inside.any { it.type == UsageEventType.UNLOCK }) unlocked(inside, stop) else busy(inside, stop)
            val block = nightBlock(busy, core) ?: continue
            out.add(PhoneNight(UsageAggregator.dayKey(evening, tz), hhmm(block.first, tz), hhmm(block.second, tz)))
        }
        return out
    }

    /**
     * The stretches of use when the phone reports unlocks: from unlocking to the screen going off. The screen lighting up
     * for a notification or the alarm, or a look at the time on the lock screen, is not use. Phones without a lock
     * screen report no unlocks: then [busy] reads the apps instead.
     */
    fun unlocked(events: List<UsageEvent>, endMs: Long): List<Pair<Long, Long>> {
        val out = ArrayList<Pair<Long, Long>>()
        var from: Long? = null
        for (e in events) {
            when (e.type) {
                UsageEventType.UNLOCK -> if (from == null) from = e.timeMs
                UsageEventType.LOCK -> from?.let { out.add(it to minOf(e.timeMs, it + MAX_SESSION_MS)); from = null }
                else -> Unit
            }
        }
        from?.let { out.add(it to minOf(endMs, it + MAX_SESSION_MS)) }
        return out
    }

    /** The stretches of use (sorted, joined when they touch) in one evening's events. [endMs] closes one still open. */
    fun busy(events: List<UsageEvent>, endMs: Long): List<Pair<Long, Long>> {
        val out = ArrayList<Pair<Long, Long>>()
        var open: String? = null
        var from = 0L
        var last = 0L
        fun add(a: Long, b: Long) {
            val e = minOf(b, a + MAX_SESSION_MS)
            if (out.isNotEmpty() && a <= out.last().second) out[out.size - 1] = out.last().first to maxOf(out.last().second, e)
            else out.add(a to maxOf(a, e))
        }
        for (e in events) {
            when (e.type) {
                UsageEventType.FOREGROUND -> if (open == null) { open = e.pkg; from = e.timeMs } else open = e.pkg // another app: still in use
                UsageEventType.BACKGROUND -> if (open == e.pkg) { add(from, e.timeMs); open = null }
                    else if (open == null) add(e.timeMs, e.timeMs) // the end of a session that began before the window
                else -> Unit
            }
            last = e.timeMs
        }
        if (open != null) add(from, maxOf(last, endMs))
        return out
    }

    /** The night in one evening's stretches of use, as described in [detect]; [core] is 01:00-06:00 of that night. */
    fun nightBlock(busy: List<Pair<Long, Long>>, core: Pair<Long, Long>): Pair<Long, Long>? {
        // the quiet stretches between uses, and the uses between them (peeks[i] sits between quiet[i] and quiet[i + 1])
        val quiet = (1 until busy.size).map { busy[it - 1].second to busy[it].first }
        fun len(q: Pair<Long, Long>) = q.second - q.first
        fun score(q: Pair<Long, Long>) = len(q) + maxOf(0L, minOf(q.second, core.second) - maxOf(q.first, core.first))
        val best = quiet.indices.filter { len(quiet[it]) >= QUIET_MS }.maxByOrNull { score(quiet[it]) } ?: return null
        fun peek(i: Int) = busy[i + 1].second - busy[i + 1].first // the use between quiet[i] and quiet[i + 1]
        var first = best
        while (first > 0 && peek(first - 1) <= PEEK_MS && len(quiet[first - 1]) >= ASLEEP_BEFORE_MS) first--
        var last = best
        // after a peek before 06:00 the night goes on; a peek after it is waking up (pick-up), even if the morning is quiet
        while (last < quiet.size - 1 && busy[last + 1].first < core.second && peek(last) <= PEEK_MS && len(quiet[last + 1]) >= ASLEEP_BEFORE_MS) last++
        val block = quiet[first].first to quiet[last].second
        return if (len(block) >= MIN_GAP_MS) block else null
    }

    /**
     * For Settings > Check Lify: each of the last [nights] nights in plain words, found or why not
     * ("2026-10-28: 02:10 to 09:05", "2026-10-27: none, the longest quiet stretch was 1 h 40, a night needs 3 h").
     */
    fun report(events: List<UsageEvent>, nowMs: Long, tz: TimeZone, nights: Int = 3): List<String> {
        val found = detect(events, nowMs, tz, nights).associateBy { it.night }
        val sorted = events.filter { !ignored(it.pkg) }.sortedBy { it.timeMs }
        val today = UsageAggregator.startOfDay(nowMs, tz)
        return (1..nights).map { back ->
            val evening = Calendar.getInstance(tz).apply { timeInMillis = today; add(Calendar.DAY_OF_YEAR, -back); set(Calendar.HOUR_OF_DAY, 18) }.timeInMillis
            val day = UsageAggregator.dayKey(evening, tz)
            found[day]?.let { return@map "$day: ${it.down} to ${it.up}" }
            val end = Calendar.getInstance(tz).apply { timeInMillis = evening; add(Calendar.DAY_OF_YEAR, 1); set(Calendar.HOUR_OF_DAY, 14) }.timeInMillis
            val inside = sorted.filter { it.timeMs in evening..minOf(end, nowMs) }
            if (inside.isEmpty()) return@map "$day: none, the phone has no usage data for it"
            val unlocks = inside.any { it.type == UsageEventType.UNLOCK }
            val b = if (unlocks) unlocked(inside, minOf(end, nowMs)) else busy(inside, minOf(end, nowMs))
            val longest = (1 until b.size).maxOfOrNull { b[it].first - b[it - 1].second } ?: 0L
            "$day: none, the longest quiet stretch was ${longest / 3_600_000} h ${(longest / 60_000) % 60}, a night needs 3 h" +
                if (unlocks) "" else " (no unlocks reported, read from apps)"
        }
    }

    fun hhmm(ms: Long, tz: TimeZone): String {
        val c = Calendar.getInstance(tz).apply { timeInMillis = ms }
        return "%02d:%02d".format(c.get(Calendar.HOUR_OF_DAY), c.get(Calendar.MINUTE))
    }
}

/** The user's day ends at 05:00, not midnight: planning at 01:00 still plans the day that is about to start. */
object LogicalDay {
    const val CUTOFF_HOUR = 5

    fun startMs(nowMs: Long, tz: TimeZone): Long {
        val c = Calendar.getInstance(tz).apply { timeInMillis = nowMs }
        if (c.get(Calendar.HOUR_OF_DAY) < CUTOFF_HOUR) c.add(Calendar.DAY_OF_YEAR, -1)
        return UsageAggregator.startOfDay(c.timeInMillis, tz)
    }

    fun today(nowMs: Long, tz: TimeZone): String = UsageAggregator.dayKey(startMs(nowMs, tz), tz)

    fun tomorrow(nowMs: Long, tz: TimeZone): String =
        UsageAggregator.dayKey(Calendar.getInstance(tz).apply { timeInMillis = startMs(nowMs, tz); add(Calendar.DAY_OF_YEAR, 1) }.timeInMillis, tz)
}

/** When the evening reminder rings: one hour before the sleep time, the next time that comes. */
object EveningTime {
    const val BEFORE_SLEEP_MS = 60L * 60 * 1000

    fun next(nowMs: Long, sleepHHmm: String, tz: TimeZone): Long {
        val c = Calendar.getInstance(tz).apply {
            timeInMillis = nowMs
            set(Calendar.HOUR_OF_DAY, sleepHHmm.substring(0, 2).toInt())
            set(Calendar.MINUTE, sleepHHmm.substring(3).toInt())
            set(Calendar.SECOND, 0)
            set(Calendar.MILLISECOND, 0)
        }
        var at = c.timeInMillis - BEFORE_SLEEP_MS
        while (at <= nowMs + 60_000) at += 24L * 60 * 60 * 1000
        return at
    }
}
