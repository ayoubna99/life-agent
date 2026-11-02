package org.ngdev.life_agent.core

import java.util.Random
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class MomentsTest {
    private val m = 60_000L
    private fun fg(min: Long, p: String) = UsageEvent(min * m, p, UsageEventType.FOREGROUND)
    private fun bg(min: Long, p: String) = UsageEvent(min * m, p, UsageEventType.BACKGROUND)
    private fun unlock(min: Long) = UsageEvent(min * m, "android", UsageEventType.UNLOCK)
    private val feeds = setOf("tiktok", "insta")
    private val skip = setOf("launcher")
    private val names = mapOf("whatsapp" to "WhatsApp", "tiktok" to "TikTok", "insta" to "Instagram")
    private fun label(p: String) = names[p] ?: p

    @Test fun lostIntentNamesWhatTheyPickedThePhoneUpForAndTheDrift() {
        val events = listOf(unlock(100), fg(100, "launcher"), fg(100, "whatsapp"), bg(102, "whatsapp"), fg(102, "insta"), bg(108, "insta"), fg(108, "tiktok"))
        val x = Moments.lostIntent(events, 114 * m, "tiktok", feeds, skip, ::label)!!
        assertEquals(MomentKind.LOST_INTENT, x.kind)
        assertEquals("You picked up your phone for WhatsApp 14 minutes ago. Since then: Instagram, then TikTok.", x.text)
        assertEquals(mapOf("opened_for" to "WhatsApp", "since_unlock" to "14 minutes ago", "since_then" to "Instagram, then TikTok"), x.facts)
        // demo mode: right away, and it reads naturally
        val quick = listOf(UsageEvent(100 * m, "android", UsageEventType.UNLOCK), UsageEvent(100 * m + 5_000, "whatsapp", UsageEventType.FOREGROUND), UsageEvent(100 * m + 15_000, "tiktok", UsageEventType.FOREGROUND))
        assertEquals("You picked up your phone for WhatsApp just now. Since then: TikTok.", Moments.lostIntent(quick, 100 * m + 30_000, "tiktok", feeds, skip, ::label, 0)!!.text)
        assertEquals(MomentAction("Back to WhatsApp", "app:whatsapp"), x.action)
        // opened TikTok on purpose: nothing was lost
        assertNull(Moments.lostIntent(listOf(unlock(100), fg(100, "tiktok")), 114 * m, "tiktok", feeds, skip, ::label))
        // why not: the first app was itself a feed on their list
        assertEquals("the first app after unlocking was TikTok, which is on your list of apps that pull you away",
            Moments.lostIntentWhyNot(listOf(unlock(100), fg(100, "tiktok")), 114 * m, "tiktok", feeds, skip, ::label))
        assertNull(Moments.lostIntentWhyNot(events, 114 * m, "tiktok", feeds, skip, ::label))
        // too soon after the unlock
        assertNull(Moments.lostIntent(events, 105 * m, "tiktok", feeds, skip, ::label))
    }

    @Test fun exitPointComparesThemWithTheirOwnUsualAndOnlyWithEnoughSessions() {
        val action = MomentAction("Open: Gym", "task:Gym")
        val past = listOf(5, 6, 6, 7, 30)
        val x = Moments.exitPoint(past, 9, "TikTok", action)!!
        assertEquals("You usually leave TikTok around minute 6. This is minute 9.", x.text)
        assertNull(Moments.exitPoint(past, 8, "TikTok", action), "not past the usual point yet")
        assertNull(Moments.exitPoint(listOf(5, 6, 7), 20, "TikTok", action), "3 sessions are too few to say usually")
        // sessions: short breaks merge, a long one splits
        val ev = listOf(fg(0, "tiktok"), bg(4, "tiktok"), fg(5, "tiktok"), bg(9, "tiktok"), fg(30, "tiktok"), bg(36, "tiktok"), fg(50, "tiktok"))
        assertEquals(listOf(9, 6), Moments.sessionLengths(ev, "tiktok"), "the session still going on is not counted")
    }

    @Test fun plannedNowAndPhoneDownUseOnlyTheirOwnPlan() {
        val tasks = listOf(TaskLite("Finish chapter 3", 60, "21:00", null, false), TaskLite("Tea", 10, "21:05", null, false))
        val p = Moments.plannedNow(tasks, "21:10")!!
        assertEquals("You planned \"Finish chapter 3\" for 21:00. It's 21:10.", p.text)
        assertEquals("task:Finish chapter 3", p.action.open)
        assertNull(Moments.plannedNow(tasks, "22:00"))
        val tomorrow = listOf(TaskLite("Gym", 60, "07:00", null, false))
        assertEquals("You said phone down at 23:00. Tomorrow starts with Gym at 07:00.", Moments.phoneDown("23:00", "23:40", tomorrow)!!.text)
        assertEquals("done", Moments.phoneDown("23:00", "00:30", tomorrow)!!.action.open, "after midnight still counts")
        assertNull(Moments.phoneDown("23:00", "20:00", tomorrow))
        assertNull(Moments.phoneDown(null, "23:40", tomorrow))
    }

    @Test fun theMomentThatWorksForThemGetsPickedMore() {
        val a = Moments.phoneDown("23:00", "23:30", emptyList())!!
        val b = Moments.plannedNow(listOf(TaskLite("Thesis", 60, "23:30", null, false)), "23:30")!!
        val stats = mapOf(MomentKind.PHONE_DOWN.key to ArmStat(8, 7), MomentKind.PLANNED_NOW.key to ArmStat(8, 1))
        val picks = (0 until 200).map { Moments.pick(listOf(a, b), stats, stats, Random(it.toLong()))!! }
        assertTrue(picks.count { it.first.kind == MomentKind.PHONE_DOWN } > 160)
        assertTrue(picks.all { it.second > 0 && it.second <= 1 })
    }

    @Test fun goingStraightBackToAFeedIsNotASuccess() {
        // nudged at minute 0 on TikTok, left at 1, opened Instagram at 4
        val events = listOf(bg(1, "tiktok"), fg(1, "whatsapp"), fg(4, "insta"))
        val o = OutcomeMeter.measure(events, "tiktok", 0, 15 * m, 2 * m, feeds)
        assertTrue(o.left)
        assertTrue(o.backToFeed)
        assertFalse(o.stayedOff)
        val clean = OutcomeMeter.measure(listOf(bg(1, "tiktok"), fg(1, "docs")), "tiktok", 0, 15 * m, 2 * m, feeds)
        assertTrue(clean.stayedOff)
    }
}
