package org.ngdev.life_agent.core

import java.util.Calendar
import java.util.TimeZone
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class NightsTest {
    private val tz = TimeZone.getTimeZone("Europe/Paris")

    private fun at(day: Int, h: Int, m: Int): Long = Calendar.getInstance(tz).apply {
        clear(); set(2026, Calendar.OCTOBER, day, h, m)
    }.timeInMillis

    private fun use(t: Long) = listOf(UsageEvent(t, "tiktok", UsageEventType.FOREGROUND), UsageEvent(t + 60_000, "tiktok", UsageEventType.BACKGROUND))

    /** Scrolling for [minutes]: a short use every 2 minutes. */
    private fun scroll(from: Long, minutes: Int) = (0 until minutes / 2).flatMap { use(from + it * 2 * 60_000L) }

    @Test fun lastUseBeforeTheLongOvernightGapIsThePhoneDownTime() {
        val events = use(at(28, 21, 0)) + scroll(at(29, 2, 30), 42) + use(at(29, 10, 40)) + use(at(29, 12, 0))
        val nights = PhoneNights.detect(events, at(29, 15, 0), tz)
        assertEquals(PhoneNight("2026-10-28", "03:11", "10:40"), nights.first())
    }

    @Test fun anEarlyNightAndNightsWithoutAGapAreHandled() {
        val early = use(at(27, 22, 30)) + use(at(28, 7, 5))
        assertEquals(PhoneNight("2026-10-27", "22:31", "07:05"), PhoneNights.detect(early, at(29, 15, 0), tz).single())
        // scrolling on and off all night: never 20 quiet minutes in a row, no night reported
        val busy = (0..20).flatMap { scroll(at(28, 20, 0) + it * 30 * 60_000L, 16) }
        assertTrue(PhoneNights.detect(busy, at(29, 15, 0), tz).none { it.night == "2026-10-28" })
    }

    @Test fun aPeekInTheNightIsNotWhenYouWentToBed() {
        // in bed at 00:40, checked the time at 04:10 for two minutes, up at 09:00
        val events = use(at(28, 23, 0)) + use(at(29, 0, 39)) + use(at(29, 4, 10)) + use(at(29, 4, 11)) + use(at(29, 9, 0))
        assertEquals(PhoneNight("2026-10-28", "00:40", "09:00"), PhoneNights.detect(events, at(29, 15, 0), tz).first())
    }

    @Test fun realUseInTheNightSplitsIt() {
        // in bed at 00:00 but up scrolling from 03:00 to 03:40: the night that counts starts after that
        val events = use(at(29, 0, 0)) + scroll(at(29, 3, 0), 40) + use(at(29, 10, 0))
        assertEquals("03:39", PhoneNights.detect(events, at(29, 15, 0), tz).first().down)
    }


    @Test fun theAlarmAndAQuietMorningDoNotMoveTheNight() {
        // scrolling until 03:30, the alarm rings at 08:00, a look at messages 08:02-08:10, then nothing until 12:30.
        // Before, this said 08:02 (the quiet morning was the longest stretch, and the alarm counted as use).
        val alarm = listOf(UsageEvent(at(29, 8, 0), "com.google.android.deskclock", UsageEventType.FOREGROUND), UsageEvent(at(29, 8, 2), "com.google.android.deskclock", UsageEventType.BACKGROUND))
        val events = scroll(at(29, 1, 0), 150) + alarm +
            listOf(UsageEvent(at(29, 8, 2), "whatsapp", UsageEventType.FOREGROUND), UsageEvent(at(29, 8, 10), "whatsapp", UsageEventType.BACKGROUND)) +
            use(at(29, 12, 30))
        assertEquals(PhoneNight("2026-10-28", "03:29", "08:02"), PhoneNights.detect(events, at(29, 15, 0), tz).first())
    }

    @Test fun aLongVideoIsUseNotQuiet() {
        // one video from 01:00 to 03:00 has only two events; the time between them is use, not the night
        val events = use(at(28, 23, 0)) + listOf(UsageEvent(at(29, 1, 0), "youtube", UsageEventType.FOREGROUND), UsageEvent(at(29, 3, 0), "youtube", UsageEventType.BACKGROUND)) + use(at(29, 9, 30))
        assertEquals(PhoneNight("2026-10-28", "03:00", "09:30"), PhoneNights.detect(events, at(29, 15, 0), tz).first())
    }

    @Test fun aNightOwlStillGetsTheirNight() {
        // up until 05:00, asleep until 13:00; a 90 minute break at 01:00 is not the night
        val events = scroll(at(28, 23, 0), 120) + scroll(at(29, 2, 30), 150) + use(at(29, 13, 0))
        assertEquals(PhoneNight("2026-10-28", "04:59", "13:00"), PhoneNights.detect(events, at(29, 15, 0), tz).first())
    }

    private fun unlock(from: Long, minutes: Int) = listOf(
        UsageEvent(from, "android", UsageEventType.UNLOCK),
        UsageEvent(from + 30_000, "tiktok", UsageEventType.FOREGROUND),
        UsageEvent(from + minutes * 60_000L - 30_000, "tiktok", UsageEventType.BACKGROUND),
        UsageEvent(from + minutes * 60_000L, "android", UsageEventType.LOCK),
    )

    @Test fun withUnlocksTheScreenWakingUpForNotificationsIsNotUse() {
        // unlocked until 02:15; all night the screen lights up for messages and the launcher comes to the front
        // (no unlock): that used to leave no 20 quiet minutes, so no night was found at all
        val wakes = (0 until 20).flatMap { i ->
            val t = at(29, 2, 30) + i * 15 * 60_000L
            listOf(UsageEvent(t, "com.miui.home", UsageEventType.FOREGROUND), UsageEvent(t + 20_000, "com.miui.home", UsageEventType.BACKGROUND))
        }
        val events = unlock(at(28, 23, 0), 60) + unlock(at(29, 1, 30), 45) + wakes + unlock(at(29, 9, 40), 10)
        assertEquals(PhoneNight("2026-10-28", "02:15", "09:40"), PhoneNights.detect(events, at(29, 15, 0), tz).first())
        assertEquals("2026-10-28: 02:15 to 09:40", PhoneNights.report(events, at(29, 15, 0), tz, 1).single())
    }

    @Test fun theReportSaysWhyANightIsMissing() {
        val busy = (0..20).flatMap { scroll(at(28, 20, 0) + it * 30 * 60_000L, 16) }
        val line = PhoneNights.report(busy, at(29, 15, 0), tz, 1).single()
        assertTrue(line.startsWith("2026-10-28: none, the longest quiet stretch was 0 h"), line)
    }

    @Test fun theDayEndsAtFiveInTheMorning() {
        assertEquals("2026-10-28", LogicalDay.today(at(29, 1, 30), tz))
        assertEquals("2026-10-29", LogicalDay.tomorrow(at(29, 1, 30), tz))
        assertEquals("2026-10-29", LogicalDay.today(at(29, 8, 0), tz))
    }

    @Test fun theEveningReminderRingsAnHourBeforeSleep() {
        assertEquals(at(29, 22, 0), EveningTime.next(at(29, 18, 0), "23:00", tz))
        assertEquals(at(30, 22, 0), EveningTime.next(at(29, 22, 30), "23:00", tz))
        assertEquals(at(30, 0, 30), EveningTime.next(at(29, 18, 0), "01:30", tz))
    }
}
