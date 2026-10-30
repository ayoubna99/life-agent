package org.ngdev.life_agent.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class NudgePolicyTest {
    private val day = "2026-10-27"
    private val now = 1_000_000_000L
    private val long = now - NudgePolicy.COOLDOWN_MS * 10

    private fun decide(used: Int, limit: Int = 30, sent: Map<String, Long> = emptyMap(), last: Long = long, at: Long = now) =
        NudgePolicy.decide(day, "tiktok", used, limit, at, last, sent)

    @Test fun nothingBeforeEightyPercent() {
        assertNull(decide(23))
    }

    @Test fun approachingAtEightyPercentRoundedUp() {
        assertEquals(NudgeReason.APPROACHING, decide(24)?.reason)
        assertEquals(NudgeReason.APPROACHING, decide(25, limit = 31)?.reason) // 24.8 -> 25
        assertNull(decide(24, limit = 31))
    }

    @Test fun approachingOnlyOncePerDay() {
        val first = decide(25)!!
        assertNull(decide(26, sent = mapOf(first.key to first.value)))
    }

    @Test fun limitReachedOnceThenOnlyAt15_45And105MinutesOver() {
        val limit = decide(30)!!
        assertEquals(NudgeReason.LIMIT, limit.reason)
        val sent = mapOf(limit.key to limit.value)
        assertNull(decide(44, sent = sent))
        val over = decide(45, sent = sent)!!
        assertEquals(NudgeReason.OVER, over.reason)
        assertEquals(1L, over.value)
        val sent2 = sent + (over.key to over.value)
        assertNull(decide(74, sent = sent2))
        val over2 = decide(75, sent = sent2)!!
        val sent3 = sent2 + (over2.key to over2.value)
        assertNull(decide(134, sent = sent3))
        assertEquals(NudgeReason.OVER, decide(135, sent = sent3)?.reason)
        // limit + three times over = four: that is all for this app today
        assertNull(decide(500, sent = sent3 + (over.key to 3L)))
    }

    @Test fun atMostFourADayPerApp() {
        val sent = mapOf("$day|tiktok|approaching" to now, "$day|tiktok|limit" to now, "$day|tiktok|over" to 2L)
        assertNull(decide(200, sent = sent))
    }

    @Test fun jumpingStraightPastTheLimitStillGivesOneLimitNudge() {
        assertEquals(NudgeReason.LIMIT, decide(45)?.reason)
    }

    @Test fun nothingWithinTheCooldown() {
        assertNull(decide(30, last = now - NudgePolicy.COOLDOWN_MS + 1))
        assertEquals(NudgeReason.LIMIT, decide(30, last = now - NudgePolicy.COOLDOWN_MS)?.reason)
    }

    @Test fun badNumbersGiveNothing() {
        assertNull(decide(10, limit = 0))
        assertNull(decide(-1))
    }

    @Test fun anotherAppOrAnotherDayStartsFresh() {
        val sent = mapOf("$day|tiktok|limit" to now)
        assertNull(NudgePolicy.decide(day, "tiktok", 31, 30, now, long, sent))
        assertEquals(NudgeReason.LIMIT, NudgePolicy.decide(day, "insta", 31, 30, now, long, sent)?.reason)
        assertEquals(NudgeReason.LIMIT, NudgePolicy.decide("2026-10-28", "tiktok", 31, 30, now, long, sent)?.reason)
    }

    @Test fun oldDaysAreForgotten() {
        val kept = NudgePolicy.keepOnly(day, mapOf("2026-10-26|a|limit" to 1L, "$day|a|limit" to 2L))
        assertEquals(mapOf("$day|a|limit" to 2L), kept)
    }

}
