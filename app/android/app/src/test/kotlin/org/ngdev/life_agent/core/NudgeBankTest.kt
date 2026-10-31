package org.ngdev.life_agent.core

import java.util.Random
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

class NudgeBankTest {
    private fun angle(id: String, vararg lines: String, bands: Set<Band> = Band.values().toSet(), apps: List<String> = emptyList()) =
        BankAngle(id, id, Arm.GOAL, bands, apps, lines.mapIndexed { i, t -> BankLine("${id}_$i", t) })

    private val gym = angle("gym", "Gym at 6. {app} will still be here.", "Tomorrow-you wants that gym.", "One more scroll or one more rep?")
    private val thesis = angle("thesis", "One page. I dare you.", "The thesis won't write itself.")

    @Test fun anIdeaThatWorksComesBackInNewWordsNeverTheSameLineTwice() {
        // gym worked 6 of 6 here, thesis 0 of 6: gym wins, and each pick is the next line never shown
        val local = mapOf("gym" to ArmStat(6, 6), "thesis" to ArmStat(6, 0))
        val seen = HashSet<String>()
        val shown = ArrayList<String>()
        repeat(3) {
            val p = NudgeBank.pick(listOf(gym, thesis), Band.NIGHT, "TikTok", seen, local, local, Random(it.toLong()))!!
            assertEquals("gym", p.angle.id)
            seen.add(p.line.id)
            shown.add(p.text)
        }
        assertEquals(listOf("Gym at 6. TikTok will still be here.", "Tomorrow-you wants that gym.", "One more scroll or one more rep?"), shown)
        // gym has no fresh line left: the other angle gets its turn rather than a repeat
        assertEquals("thesis", NudgeBank.pick(listOf(gym, thesis), Band.NIGHT, "TikTok", seen, local, local, Random(9))!!.angle.id)
    }

    @Test fun onlyAnglesForThisMomentAndApp() {
        val night = angle("night_only", "Phone down, tomorrow is early.", bands = setOf(Band.NIGHT))
        val insta = angle("insta_only", "Close it.", apps = listOf("Instagram"))
        assertNull(NudgeBank.pick(listOf(night, insta), Band.MORNING, "TikTok", emptySet(), emptyMap(), emptyMap(), Random(1)))
        assertEquals("insta_only", NudgeBank.pick(listOf(night, insta), Band.MORNING, "instagram", emptySet(), emptyMap(), emptyMap(), Random(1))!!.angle.id)
    }

    @Test fun newAnglesStillGetTriedAndThePropensityIsLogged() {
        val tried = mapOf("gym" to ArmStat(3, 2))
        val picks = (0 until 300).map { NudgeBank.pick(listOf(gym, thesis), Band.NIGHT, "TikTok", emptySet(), tried, tried, Random(it.toLong()))!! }
        assertTrue(picks.any { it.angle.id == "thesis" }, "an angle with no data is explored")
        assertTrue(picks.all { it.propensity > 0 && it.propensity <= 1 })
        val explore = picks.first { it.angle.id == "thesis" }
        assertTrue(explore.explore)
        assertNotEquals(explore.angle.id, "gym")
    }

    @Test fun startingBeliefsLeadUntilYourOwnResultsTakeOver() {
        val blunt = BankAngle("blunt_task", "b", Arm.TASK, Band.values().toSet(), emptyList(), listOf(BankLine("b1", "x")), "blunt", "task")
        val question = BankAngle("question", "q", Arm.GOAL, Band.values().toSet(), emptyList(), listOf(BankLine("q1", "y")), "question", "other")
        fun share(stats: Map<String, ArmStat>) =
            (0 until 2000).count { NudgeBank.pick(listOf(blunt, question), Band.NIGHT, "TikTok", emptySet(), stats, stats, Random(it.toLong()))!!.angle.id == "blunt_task" } / 2000.0
        // no data at all: the starting assumption (concrete and blunt beats a question) gives a lead, not a lock
        val fresh = share(emptyMap())
        assertTrue(fresh > 0.5 && fresh < 0.9, "fresh: $fresh")
        // this person is different: questions worked 5 of 6, blunt 0 of 6. Their data wins.
        val theirs = share(mapOf("blunt_task" to ArmStat(6, 0), "question" to ArmStat(6, 5)))
        assertTrue(theirs < 0.1, "theirs: $theirs")
    }

    @Test fun theMomentIsDescribedForTheTheoryChecks() {
        assertEquals("weekend", Moment.dayType(java.util.Calendar.SUNDAY))
        assertEquals("weekday", Moment.dayType(java.util.Calendar.MONDAY))
        assertEquals("near", Moment.depth(25, 30))
        assertEquals("just_over", Moment.depth(55, 30))
        assertEquals("way_over", Moment.depth(61, 30))
        val tasks = listOf(TaskLite("Gym", 60, "08:00", null, false), TaskLite("Water", 5, "06:30", null, false))
        assertTrue(Moment.taskSoon(tasks, "06:15"))
        assertTrue(!Moment.taskSoon(tasks, "05:30"), "the small chore does not count, the gym is 2.5 h away")
        assertTrue(!Moment.taskSoon(listOf(TaskLite("Gym", 60, "08:00", null, true)), "07:00"), "done tasks do not count")
    }
}
