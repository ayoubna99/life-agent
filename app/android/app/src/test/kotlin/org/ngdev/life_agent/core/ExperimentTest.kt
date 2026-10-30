package org.ngdev.life_agent.core

import java.util.Random
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class ExperimentTest {
    private val all = listOf(Arm.TASK, Arm.COST, Arm.GOAL)

    @Test fun offOrOnlyOneArmMeansTheTaskNudgeAndNoTest() {
        assertEquals(Pick(Arm.TASK, false), Bandit.pick(all, emptyMap(), Random(1), enabled = false))
        assertEquals(Pick(Arm.COST, false), Bandit.pick(listOf(Arm.COST), emptyMap(), Random(1), enabled = true))
    }

    @Test fun withNoDataEveryStyleIsEquallyLikely() {
        val rnd = Random(3)
        val counts = (1..3000).map { Bandit.pick(all, emptyMap(), rnd, enabled = true).arm }.groupingBy { it }.eachCount()
        assertTrue(all.all { (counts[it] ?: 0) in 850..1150 }, counts.toString())
    }

    @Test fun thompsonMostlyPicksTheBestAndStillTriesTheOthers() {
        val stats = mapOf(Arm.COST to ArmStat(8, 3), Arm.TASK to ArmStat(9, 7), Arm.GOAL to ArmStat(3, 1))
        val rnd = Random(42)
        val picks = (1..2000).map { Bandit.pick(all, stats, rnd, enabled = true) }
        val best = picks.count { it.arm == Arm.TASK }
        assertTrue(best in 1500..1900, "best picked $best times")
        assertTrue(picks.filter { it.arm == Arm.TASK }.none { it.explore })
        assertTrue(picks.filter { it.arm != Arm.TASK }.all { it.explore })
        assertTrue(picks.count { it.arm == Arm.GOAL } > 50, "a style with little data is still tried")
    }

    @Test fun moreEvidenceMeansLessTesting() {
        val rnd = Random(5)
        fun share(stats: Map<Arm, ArmStat>) = (1..2000).count { Bandit.pick(all, stats, rnd, true).arm == Arm.TASK } / 2000.0
        val early = share(mapOf(Arm.TASK to ArmStat(4, 3), Arm.COST to ArmStat(4, 1), Arm.GOAL to ArmStat(4, 1)))
        val late = share(mapOf(Arm.TASK to ArmStat(40, 30), Arm.COST to ArmStat(40, 10), Arm.GOAL to ArmStat(40, 10)))
        assertTrue(late > early && late > 0.99, "early $early late $late")
    }

    @Test fun bandsCoverTheDay() {
        assertEquals(Band.NIGHT, Band.of(23))
        assertEquals(Band.NIGHT, Band.of(2))
        assertEquals(Band.MORNING, Band.of(5))
        assertEquals(Band.AFTERNOON, Band.of(14))
        assertEquals(Band.EVENING, Band.of(20))
    }

    @Test fun contextualLearnsADifferentBestStylePerMoment() {
        // At night "cost" works, in the afternoon "task" does; overall they look the same.
        val night = mapOf(Arm.TASK to ArmStat(10, 2), Arm.COST to ArmStat(10, 8), Arm.GOAL to ArmStat(4, 1))
        val afternoon = mapOf(Arm.TASK to ArmStat(10, 8), Arm.COST to ArmStat(10, 2), Arm.GOAL to ArmStat(4, 1))
        val global = mapOf(Arm.TASK to ArmStat(20, 10), Arm.COST to ArmStat(20, 10), Arm.GOAL to ArmStat(8, 2))
        val rnd = Random(4)
        fun share(local: Map<Arm, ArmStat>, arm: Arm) = (1..500).count { ContextualBandit.decide(all, global, local, rnd, true).arm == arm } / 500.0
        assertTrue(share(night, Arm.COST) > 0.75)
        assertTrue(share(afternoon, Arm.TASK) > 0.75)
    }

    @Test fun aNewMomentBorrowsFromTheOthers() {
        val global = mapOf(Arm.TASK to ArmStat(30, 24), Arm.COST to ArmStat(30, 6), Arm.GOAL to ArmStat(30, 6))
        val (a, b) = ContextualBandit.posterior(Arm.TASK, global, emptyMap())
        assertTrue(a / (a + b) > 0.6, "prior follows the other moments")
        val (c, d) = ContextualBandit.posterior(Arm.TASK, global, mapOf(Arm.TASK to ArmStat(30, 24)))
        // all data is from this moment: nothing to borrow, so the prior is 4 tries at 50%, plus the 24 of 30 seen here
        assertEquals(1.0 + 2.0 + 24.0, c, 1e-9)
        assertEquals(1.0 + 2.0 + 6.0, d, 1e-9)
    }

    @Test fun propensityIsTheChanceOfTheChoiceAndIsLogged() {
        val stats = mapOf(Arm.TASK to ArmStat(20, 16), Arm.COST to ArmStat(20, 4), Arm.GOAL to ArmStat(20, 4))
        val d = (1..50).map { ContextualBandit.decide(all, stats, stats, Random(it.toLong()), true) }
        val taskP = d.filter { it.arm == Arm.TASK }.map { it.propensity }
        assertTrue(taskP.isNotEmpty() && taskP.all { it > 0.85 }, taskP.toString())
        assertTrue(d.filter { it.arm != Arm.TASK }.all { it.propensity < 0.15 && it.explore })
        assertEquals(Decision(Arm.TASK, false, 1.0), ContextualBandit.decide(all, stats, stats, Random(1), enabled = false))
    }

    @Test fun betaDrawsHaveTheRightMean() {
        val rnd = Random(9)
        val m = (1..20000).sumOf { Beta.sample(8.0, 3.0, rnd) } / 20000
        assertTrue(Math.abs(m - 8.0 / 11.0) < 0.01, "mean $m")
    }

    private fun fg(t: Long, p: String) = UsageEvent(t, p, UsageEventType.FOREGROUND)
    private fun bg(t: Long, p: String) = UsageEvent(t, p, UsageEventType.BACKGROUND)
    private val s = 1000L

    @Test fun leavingQuicklyCountsAsLeftAndTheTimeAfterIsMeasured() {
        val at = 1_000_000L
        val events = listOf(fg(at - 300 * s, "insta"), bg(at + 20 * s, "insta"), fg(at + 20 * s, "launcher"), fg(at + 600 * s, "insta"), bg(at + 660 * s, "insta"))
        val o = OutcomeMeter.measure(events, "insta", at, OutcomeMeter.WINDOW_MS, OutcomeMeter.LEFT_WITHIN_MS)
        assertTrue(o.left)
        assertEquals(80, o.secondsAfter) // 20 s, then 60 s when they came back
    }

    @Test fun stayingIsNotLeftAndCountsTheWholeWindow() {
        val at = 1_000_000L
        val o = OutcomeMeter.measure(listOf(fg(at - 10 * s, "insta")), "insta", at, 120 * s, 30 * s)
        assertFalse(o.left)
        assertEquals(120, o.secondsAfter)
        val late = OutcomeMeter.measure(listOf(fg(at + 200 * s, "chrome")), "insta", at, 900 * s, 120 * s)
        assertFalse(late.left, "left after 200 s, the window for leaving is 120 s")
        assertEquals(200, late.secondsAfter)
    }

    @Test fun frontSinceFindsTheCurrentSession() {
        val events = listOf(fg(1 * s, "insta"), fg(5 * s, "insta"), bg(10 * s, "insta"), fg(20 * s, "insta"), fg(25 * s, "insta"))
        assertEquals(20 * s, OutcomeMeter.frontSince(events, "insta"))
        assertNull(OutcomeMeter.frontSince(events + fg(30 * s, "chrome"), "insta"))
    }

    @Test fun demoHitsAfterFifteenSecondsAtMostOnceAMinute() {
        val now = 1_000_000L
        assertFalse(DemoPolicy.due(now - 10 * s, now, 0))
        assertTrue(DemoPolicy.due(now - 16 * s, now, 0))
        assertFalse(DemoPolicy.due(now - 25 * s, now, now - 50 * s))
        assertTrue(DemoPolicy.WINDOW_MS <= DemoPolicy.COOLDOWN_MS, "measurements never overlap")
        assertFalse(DemoPolicy.due(null, now, 0))
    }

    @Test fun calendarEventsTightenOncePerEventAndApp() {
        val day = "2026-10-29"
        val now = 10_000_000L
        val d = NudgePolicy.decideEvent(day, "insta", 9_000_000L, now, 0, emptyMap())!!
        assertEquals(NudgeReason.EVENT, d.reason)
        assertNull(NudgePolicy.decideEvent(day, "insta", 9_000_000L, now + 600_000, 0, mapOf(d.key to d.value)))
        assertNull(NudgePolicy.decideEvent(day, "insta", 9_500_000L, now, now - 1000, emptyMap()), "cooldown")
    }

    @Test fun onlyTimedBusyEventsCount() {
        val now = 5_000L
        val events = listOf(
            CalEvent("Holiday", 0, 100_000, allDay = true, busy = true),
            CalEvent("Coffee", 0, 10_000, allDay = false, busy = false),
            CalEvent("Lecture", 1_000, 9_000, allDay = false, busy = true),
        )
        assertEquals("Lecture", DayRules.currentEvent(events, now)?.title)
        assertNull(DayRules.currentEvent(events, 9_000))
    }

    @Test fun nextTask() {
        val tasks = listOf(
            TaskLite("Gym", 60, "17:00", null, false),
            TaskLite("German", 40, "10:00", "Open the sheet", false),
            TaskLite("Read", 30, null, null, true),
        )
        assertEquals("German", DayRules.nextTask(tasks, "09:00")?.title)
        assertEquals("Gym", DayRules.nextTask(tasks, "12:00")?.title)
    }

    @Test fun sessionRuleFiresAtEachStepOnce() {
        val day = "2026-10-29"
        val since = 1_000_000L
        val rules = listOf(SessionRule("any app", SessionRules.ANY, 30, "do 10 push-ups"))
        assertNull(SessionRules.due(rules, "tiktok", since, since + 29 * 60_000L, day, emptySet()))
        val (rule, key) = SessionRules.due(rules, "tiktok", since, since + 30 * 60_000L, day, emptySet())!!
        assertEquals("do 10 push-ups", rule.ask)
        assertTrue(key.startsWith("$day|"))
        assertNull(SessionRules.due(rules, "tiktok", since, since + 45 * 60_000L, day, setOf(key)), "once per step")
        assertTrue(SessionRules.due(rules, "tiktok", since, since + 60 * 60_000L, day, setOf(key)) != null, "again at 60")
        assertNull(SessionRules.due(rules, "tiktok", null, since + 60 * 60_000L, day, emptySet()), "not in front")
    }

    @Test fun aRuleForThisAppWinsOverTheAnyAppRule() {
        val rules = listOf(SessionRule("any app", SessionRules.ANY, 30, "stretch"), SessionRule("TikTok", "tiktok", 10, "drink water"))
        assertEquals("drink water", SessionRules.due(rules, "tiktok", 0, 10 * 60_000L, "d", emptySet())!!.first.ask)
        assertNull(SessionRules.due(rules, "insta", 0, 10 * 60_000L, "d", emptySet()))
        assertEquals("stretch", SessionRules.due(rules, "insta", 0, 30 * 60_000L, "d", emptySet())!!.first.ask)
    }

    @Test fun cardTitles() {
        assertEquals("2 hours on TikTok", NudgeTitle.onApp(120, "TikTok"))
        assertEquals("1 hour on TikTok", NudgeTitle.onApp(60, "TikTok"))
        assertEquals("1 h 20 min on TikTok", NudgeTitle.onApp(80, "TikTok"))
        assertEquals("45 min on TikTok", NudgeTitle.onApp(45, "TikTok"))
    }
}
