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
}
