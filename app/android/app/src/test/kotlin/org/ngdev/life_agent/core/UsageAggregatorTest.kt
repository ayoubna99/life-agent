package org.ngdev.life_agent.core

import java.util.Calendar
import java.util.TimeZone
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class UsageAggregatorTest {
    private val tz = TimeZone.getTimeZone("Europe/Paris")
    private fun at(y: Int, m: Int, d: Int, h: Int, min: Int, s: Int = 0): Long =
        Calendar.getInstance(tz).apply { clear(); set(y, m - 1, d, h, min, s) }.timeInMillis

    private fun fg(t: Long, p: String) = UsageEvent(t, p, UsageEventType.FOREGROUND)
    private fun bg(t: Long, p: String) = UsageEvent(t, p, UsageEventType.BACKGROUND)

    @Test fun oneSessionIsCounted() {
        val r = UsageAggregator.perDay(listOf(fg(at(2026, 10, 27, 9, 0), "tiktok"), bg(at(2026, 10, 27, 9, 25), "tiktok")), at(2026, 10, 27, 12, 0), tz)
        assertEquals(25 * 60_000L, r["2026-10-27"]!!["tiktok"])
    }

    @Test fun twoSessionsAdd() {
        val r = UsageAggregator.perDay(
            listOf(fg(at(2026, 10, 27, 9, 0), "a"), bg(at(2026, 10, 27, 9, 10), "a"), fg(at(2026, 10, 27, 10, 0), "a"), bg(at(2026, 10, 27, 10, 5), "a")),
            at(2026, 10, 27, 12, 0), tz,
        )
        assertEquals(15 * 60_000L, r["2026-10-27"]!!["a"])
    }

    @Test fun anotherAppComingToTheFrontEndsThePreviousOne() {
        val r = UsageAggregator.perDay(listOf(fg(at(2026, 10, 27, 9, 0), "a"), fg(at(2026, 10, 27, 9, 10), "b"), bg(at(2026, 10, 27, 9, 12), "b")), at(2026, 10, 27, 12, 0), tz)
        assertEquals(10 * 60_000L, r["2026-10-27"]!!["a"])
        assertEquals(2 * 60_000L, r["2026-10-27"]!!["b"])
    }

    @Test fun openingAnotherScreenOfTheSameAppIsNotANewSession() {
        val r = UsageAggregator.perDay(listOf(fg(at(2026, 10, 27, 9, 0), "a"), fg(at(2026, 10, 27, 9, 5), "a"), bg(at(2026, 10, 27, 9, 10), "a")), at(2026, 10, 27, 12, 0), tz)
        assertEquals(10 * 60_000L, r["2026-10-27"]!!["a"])
    }

    @Test fun aSessionStillOpenIsCountedUntilNow() {
        val r = UsageAggregator.perDay(listOf(fg(at(2026, 10, 27, 11, 30), "a")), at(2026, 10, 27, 11, 50), tz)
        assertEquals(20 * 60_000L, r["2026-10-27"]!!["a"])
    }

    @Test fun aSessionOverMidnightIsSplitBetweenTheTwoDays() {
        val r = UsageAggregator.perDay(listOf(fg(at(2026, 10, 27, 23, 50), "a"), bg(at(2026, 10, 28, 0, 20), "a")), at(2026, 10, 28, 8, 0), tz)
        assertEquals(10 * 60_000L, r["2026-10-27"]!!["a"])
        assertEquals(20 * 60_000L, r["2026-10-28"]!!["a"])
    }

    @Test fun anOrphanSessionIsCutAtSixHours() {
        val r = UsageAggregator.perDay(listOf(fg(at(2026, 10, 27, 1, 0), "a")), at(2026, 10, 27, 20, 0), tz)
        assertEquals(6 * 60 * 60_000L, r["2026-10-27"]!!["a"])
    }

    @Test fun aBackgroundEventForAnotherAppChangesNothing() {
        val r = UsageAggregator.perDay(listOf(fg(at(2026, 10, 27, 9, 0), "a"), bg(at(2026, 10, 27, 9, 5), "b"), bg(at(2026, 10, 27, 9, 10), "a")), at(2026, 10, 27, 12, 0), tz)
        assertEquals(10 * 60_000L, r["2026-10-27"]!!["a"])
    }

    @Test fun eventsOutOfOrderAreSortedFirst() {
        val r = UsageAggregator.perDay(listOf(bg(at(2026, 10, 27, 9, 10), "a"), fg(at(2026, 10, 27, 9, 0), "a")), at(2026, 10, 27, 12, 0), tz)
        assertEquals(10 * 60_000L, r["2026-10-27"]!!["a"])
    }

    @Test fun noEventsNoRows() {
        assertTrue(UsageAggregator.perDay(emptyList(), at(2026, 10, 27, 12, 0), tz).isEmpty())
    }

    @Test fun summaryRoundsToMinutesMergesPackagesWithTheSameNameAndDropsUnknownApps() {
        val perDay = mapOf(
            "2026-10-27" to mapOf("com.a" to 74 * 60_000L + 20_000, "com.a.lite" to 6 * 60_000L, "com.launcher" to 500 * 60_000L, "com.tiny" to 10_000L),
            "2026-10-26" to mapOf("com.a" to 30 * 60_000L),
        )
        val labels = mapOf("com.a" to "Instagram", "com.a.lite" to "Instagram", "com.tiny" to "Tiny")
        val rows = UsageAggregator.summary(perDay) { labels[it] }
        assertEquals(listOf(UsageRowOut("2026-10-26", "Instagram", 30), UsageRowOut("2026-10-27", "Instagram", 80)), rows)
    }

    @Test fun dayKeyAndStartOfDayUseTheGivenTimeZone() {
        val t = at(2026, 10, 27, 0, 30)
        assertEquals("2026-10-27", UsageAggregator.dayKey(t, tz))
        assertEquals(at(2026, 10, 27, 0, 0), UsageAggregator.startOfDay(t, tz))
        assertEquals("2026-10-26", UsageAggregator.dayKey(t, TimeZone.getTimeZone("UTC")))
    }

    @Test fun aDaylightSavingDayStillEndsAtMidnight() {
        // 2026-10-25 has 25 hours in Europe/Paris
        val r = UsageAggregator.perDay(listOf(fg(at(2026, 10, 25, 22, 0), "a"), bg(at(2026, 10, 26, 1, 0), "a")), at(2026, 10, 26, 8, 0), tz)
        assertEquals(120 * 60_000L, r["2026-10-25"]!!["a"])
        assertEquals(60 * 60_000L, r["2026-10-26"]!!["a"])
    }

    @Test fun theAppInFrontIsTheLastOneOpenedAndNotYetClosed() {
        assertEquals("b", UsageAggregator.appInFront(listOf(fg(1, "a"), fg(2, "b"))))
        assertEquals(null, UsageAggregator.appInFront(listOf(fg(1, "a"), bg(2, "a"))))
        assertEquals("a", UsageAggregator.appInFront(listOf(fg(1, "a"), bg(2, "b"))))
        assertEquals(null, UsageAggregator.appInFront(emptyList()))
        assertEquals("a", UsageAggregator.appInFront(listOf(fg(5, "a"), bg(2, "a"))), "events are sorted by time first")
    }
}
