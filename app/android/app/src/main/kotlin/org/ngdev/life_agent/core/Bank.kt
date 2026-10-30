package org.ngdev.life_agent.core

import java.util.Random

/** One line of the night shift's nudge bank. */
data class BankLine(val id: String, val text: String)

/** An angle: the idea behind a group of lines (for example "blunt, about tomorrow's gym, at night"). */
data class BankAngle(val id: String, val name: String, val style: Arm, val bands: Set<Band>, val apps: List<String>, val lines: List<BankLine>)

/** What the phone shows: a fresh line of the chosen angle, with the chance the policy had of choosing that angle. */
data class BankPick(val angle: BankAngle, val line: BankLine, val text: String, val propensity: Double, val explore: Boolean)

/**
 * Picks the nudge from the night shift's bank, instantly and without the network. CODE decides, never the model:
 * Thompson sampling over ANGLES, not sentences. Each angle's chance of getting the person off the app is a Beta belief,
 * for this app and time of day, with a prior borrowed from all moments (hierarchical shrinkage, as for the styles).
 * The winning angle shows its next line that was never shown before: an idea that works keeps coming back, always in
 * new words, and the night shift writes more lines for it.
 */
object NudgeBank {
    const val PRIOR_STRENGTH = 4.0
    const val PROPENSITY_DRAWS = 400

    /** The angles that fit now ([band], [app]) and still have a line not shown yet. */
    fun eligible(angles: List<BankAngle>, band: Band, app: String, seen: Set<String>): List<BankAngle> =
        angles.filter { band in it.bands && (it.apps.isEmpty() || it.apps.any { a -> a.equals(app, ignoreCase = true) }) }
            .map { it.copy(lines = it.lines.filter { l -> l.id !in seen }) }
            .filter { it.lines.isNotEmpty() }

    fun posterior(global: ArmStat?, local: ArmStat?): Pair<Double, Double> {
        val l = local ?: ArmStat(0, 0)
        val g = global ?: ArmStat(0, 0)
        val elsewhere = ArmStat(maxOf(0, g.tried - l.tried), maxOf(0, g.left - l.left))
        val p = Bandit.mean(elsewhere)
        return (1.0 + PRIOR_STRENGTH * p + l.left) to (1.0 + PRIOR_STRENGTH * (1 - p) + (l.tried - l.left))
    }

    fun pick(
        angles: List<BankAngle>, band: Band, app: String, seen: Set<String>,
        global: Map<String, ArmStat>, local: Map<String, ArmStat>, rnd: Random,
    ): BankPick? {
        val fit = eligible(angles, band, app, seen)
        if (fit.isEmpty()) return null
        val post = fit.map { posterior(global[it.id], local[it.id]) }
        fun draw(): Int = post.indices.maxByOrNull { Beta.sample(post[it].first, post[it].second, rnd) }!!
        val chosen = draw()
        var same = 0
        repeat(PROPENSITY_DRAWS) { if (draw() == chosen) same++ }
        val best = post.indices.maxByOrNull { post[it].first / (post[it].first + post[it].second) }!!
        val angle = fit[chosen]
        val line = angle.lines.first()
        return BankPick(angle, line, line.text.replace("{app}", app), maxOf(same, 1).toDouble() / PROPENSITY_DRAWS, chosen != best)
    }
}
