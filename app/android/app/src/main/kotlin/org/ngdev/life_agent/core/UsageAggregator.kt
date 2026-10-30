package org.ngdev.life_agent.core

import java.util.Calendar
import java.util.TimeZone

/** FOREGROUND/BACKGROUND: an app's screen came to the front / went to the back. UNLOCK: the person unlocked the phone.
 *  LOCK: the screen went off or the lock screen came back. */
enum class UsageEventType { FOREGROUND, BACKGROUND, UNLOCK, LOCK, OTHER }

data class UsageEvent(val timeMs: Long, val pkg: String, val type: UsageEventType)

data class UsageRowOut(val day: String, val app: String, val minutes: Int)

/**
 * Turns Android's usage events (an app came to the front / went to the back) into minutes per app per day.
 * Plain Kotlin on purpose: no Android classes, so it is unit tested on a normal JVM.
 */
object UsageAggregator {
    /** A session longer than this is an orphan (the phone was off, the app was killed): it is cut here. */
    const val MAX_SESSION_MS = 6L * 60 * 60 * 1000

    /** day ("yyyy-MM-dd") -> package -> milliseconds in the foreground. [endMs] closes a session that is still open (now). */
    fun perDay(events: List<UsageEvent>, endMs: Long, tz: TimeZone): Map<String, Map<String, Long>> {
        val out = HashMap<String, MutableMap<String, Long>>()
        var openPkg: String? = null
        var openAt = 0L

        fun close(at: Long) {
            val p = openPkg ?: return
            val end = minOf(at, openAt + MAX_SESSION_MS)
            if (end > openAt) addSession(out, p, openAt, end, tz)
            openPkg = null
        }

        for (e in events.sortedBy { it.timeMs }) {
            when (e.type) {
                UsageEventType.FOREGROUND -> {
                    if (openPkg == e.pkg) continue // the same app opened another screen: still the same session
                    close(e.timeMs) // another app came to the front, so the previous one is over
                    openPkg = e.pkg
                    openAt = e.timeMs
                }
                UsageEventType.BACKGROUND -> if (openPkg == e.pkg) close(e.timeMs)
                else -> Unit
            }
        }
        close(endMs)
        return out
    }

    /** The app that is in front right now according to the events (or null if none is), using the same rules as [perDay]. */
    fun appInFront(events: List<UsageEvent>): String? {
        var open: String? = null
        for (e in events.sortedBy { it.timeMs }) {
            when (e.type) {
                UsageEventType.FOREGROUND -> open = e.pkg
                UsageEventType.BACKGROUND -> if (open == e.pkg) open = null
                else -> Unit
            }
        }
        return open
    }

    /** Rows for the server: whole minutes, one per day and app name, only apps with at least a minute. */
    fun summary(
        perDay: Map<String, Map<String, Long>>,
        labelOf: (String) -> String?,
    ): List<UsageRowOut> {
        val rows = ArrayList<UsageRowOut>()
        for ((day, apps) in perDay.toSortedMap()) {
            val byLabel = HashMap<String, Long>()
            for ((pkg, ms) in apps) {
                val label = labelOf(pkg) ?: continue
                byLabel[label] = (byLabel[label] ?: 0L) + ms
            }
            for ((label, ms) in byLabel.toSortedMap()) {
                val minutes = ((ms + 30_000) / 60_000).toInt()
                if (minutes >= 1) rows.add(UsageRowOut(day, label, minutes))
            }
        }
        return rows
    }

    fun dayKey(ms: Long, tz: TimeZone): String {
        val c = Calendar.getInstance(tz).apply { timeInMillis = ms }
        return "%04d-%02d-%02d".format(c.get(Calendar.YEAR), c.get(Calendar.MONTH) + 1, c.get(Calendar.DAY_OF_MONTH))
    }

    fun startOfDay(ms: Long, tz: TimeZone): Long {
        val c = Calendar.getInstance(tz).apply { timeInMillis = ms }
        c.set(Calendar.HOUR_OF_DAY, 0)
        c.set(Calendar.MINUTE, 0)
        c.set(Calendar.SECOND, 0)
        c.set(Calendar.MILLISECOND, 0)
        return c.timeInMillis
    }

    private fun startOfNextDay(ms: Long, tz: TimeZone): Long {
        val c = Calendar.getInstance(tz).apply { timeInMillis = startOfDay(ms, tz) }
        c.add(Calendar.DAY_OF_YEAR, 1)
        return c.timeInMillis
    }

    private fun addSession(out: MutableMap<String, MutableMap<String, Long>>, pkg: String, from: Long, to: Long, tz: TimeZone) {
        var cur = from
        while (cur < to) {
            val next = minOf(to, startOfNextDay(cur, tz))
            val day = out.getOrPut(dayKey(cur, tz)) { HashMap() }
            day[pkg] = (day[pkg] ?: 0L) + (next - cur)
            cur = next
        }
    }
}
