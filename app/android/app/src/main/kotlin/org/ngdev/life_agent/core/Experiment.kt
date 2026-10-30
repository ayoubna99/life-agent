package org.ngdev.life_agent.core

import java.util.Random

/**
 * The three kinds of personal nudge the phone tests against each other. Muse Spark writes every one from the user's own
 * plan, numbers and words; they differ in what they lean on.
 */
enum class Arm(val wire: String) {
    TASK("task"), // the next task, how long it takes, its first step
    COST("cost"), // what the time on this app costs, in their own numbers
    GOAL("goal"), // their own goal, in their words
    ;

    companion object {
        fun of(wire: String): Arm? = values().firstOrNull { it.wire == wire }
    }
}

data class ArmStat(val tried: Int, val left: Int)

data class Pick(val arm: Arm, val explore: Boolean)

/**
 * Picks the nudge style for a limit hit with Thompson sampling. Code decides, never the model: each style's chance of
 * making the person leave the app is a Beta(left + 1, missed + 1) belief; one value is drawn from each belief and the
 * highest draw wins. A style that works gets picked more and more, a style with little data still gets tried, and the
 * testing fades by itself as the evidence grows. [Pick.explore] is true when the pick is not the style with the best
 * average so far.
 */
object Bandit {
    fun mean(s: ArmStat?): Double = ((s?.left ?: 0) + 1.0) / ((s?.tried ?: 0) + 2.0)

    fun pick(available: List<Arm>, stats: Map<Arm, ArmStat>, rnd: Random, enabled: Boolean): Pick {
        require(available.isNotEmpty())
        if (!enabled || available.size < 2) return Pick(if (Arm.TASK in available) Arm.TASK else available.first(), false)
        val draws = available.associateWith { val s = stats[it] ?: ArmStat(0, 0); Beta.sample(s.left + 1.0, (s.tried - s.left) + 1.0, rnd) }
        val chosen = draws.maxByOrNull { it.value }!!.key
        val greedy = available.maxByOrNull { mean(stats[it]) }!!
        return Pick(chosen, chosen != greedy)
    }

    fun record(stats: Map<Arm, ArmStat>, arm: Arm, left: Boolean): Map<Arm, ArmStat> {
        val s = stats[arm] ?: ArmStat(0, 0)
        return stats + (arm to ArmStat(s.tried + 1, s.left + if (left) 1 else 0))
    }
}

/** The moment, as the bandit sees it: the time of day. */
enum class Band(val wire: String) {
    MORNING("morning"), AFTERNOON("afternoon"), EVENING("evening"), NIGHT("night");

    companion object {
        fun of(hour: Int): Band = when (hour) {
            in 5..11 -> MORNING
            in 12..16 -> AFTERNOON
            in 17..20 -> EVENING
            else -> NIGHT
        }

        fun of(wire: String): Band? = values().firstOrNull { it.wire == wire }
    }
}

/** What the bandit chose, and the chance it had of choosing it (logged for off-policy evaluation). */
data class Decision(val arm: Arm, val explore: Boolean, val propensity: Double)

/**
 * Contextual Thompson sampling. The best nudge can depend on the moment (TikTok at night is not Instagram after lunch),
 * so every app and time-of-day band has its own results. A new moment has little data, so it borrows: each style's
 * prior there is its rate in ALL OTHER moments, worth [PRIOR_STRENGTH] tries (hierarchical Beta-Binomial shrinkage).
 * The chosen style's propensity (its chance of winning the draw) is estimated with [PROPENSITY_DRAWS] extra draws, so
 * the server can evaluate other policies from the same log without bias.
 */
object ContextualBandit {
    const val PRIOR_STRENGTH = 4.0
    const val PROPENSITY_DRAWS = 400

    /** Beta(a, b) for [arm] here: the shrunk prior from the other moments, plus this moment's own results. */
    fun posterior(arm: Arm, global: Map<Arm, ArmStat>, local: Map<Arm, ArmStat>): Pair<Double, Double> {
        val l = local[arm] ?: ArmStat(0, 0)
        val g = global[arm] ?: ArmStat(0, 0)
        val elsewhere = ArmStat(maxOf(0, g.tried - l.tried), maxOf(0, g.left - l.left))
        val p = Bandit.mean(elsewhere)
        return (1.0 + PRIOR_STRENGTH * p + l.left) to (1.0 + PRIOR_STRENGTH * (1 - p) + (l.tried - l.left))
    }

    fun decide(available: List<Arm>, global: Map<Arm, ArmStat>, local: Map<Arm, ArmStat>, rnd: Random, enabled: Boolean): Decision {
        require(available.isNotEmpty())
        if (!enabled || available.size < 2) return Decision(if (Arm.TASK in available) Arm.TASK else available.first(), false, 1.0)
        val post = available.associateWith { posterior(it, global, local) }
        fun draw(): Arm = post.entries.maxByOrNull { Beta.sample(it.value.first, it.value.second, rnd) }!!.key
        val chosen = draw()
        val wins = (1..PROPENSITY_DRAWS).count { draw() == chosen }
        val propensity = maxOf(wins, 1).toDouble() / PROPENSITY_DRAWS
        val greedy = post.entries.maxByOrNull { it.value.first / (it.value.first + it.value.second) }!!.key
        return Decision(chosen, chosen != greedy, propensity)
    }
}

/** Beta draws from two Gamma draws (Marsaglia and Tsang; shapes here are always at least 1). */
object Beta {
    fun sample(a: Double, b: Double, rnd: Random): Double {
        val x = gamma(a, rnd)
        return x / (x + gamma(b, rnd))
    }

    fun gamma(shape: Double, rnd: Random): Double {
        require(shape >= 1.0)
        val d = shape - 1.0 / 3.0
        val c = 1.0 / Math.sqrt(9.0 * d)
        while (true) {
            var x: Double
            var v: Double
            do {
                x = rnd.nextGaussian()
                v = 1.0 + c * x
            } while (v <= 0.0)
            v = v * v * v
            val u = rnd.nextDouble()
            if (u < 1.0 - 0.0331 * x * x * x * x || Math.log(u) < 0.5 * x * x + d * (1.0 - v + Math.log(v))) return d * v
        }
    }
}

/** What happened after an intervention. */
data class Outcome(val left: Boolean, val secondsAfter: Int)

object OutcomeMeter {
    /** Normal windows: did they leave within 2 minutes, and how long were they in the app in the next 15. */
    const val WINDOW_MS = 15L * 60 * 1000
    const val LEFT_WITHIN_MS = 2L * 60 * 1000

    /**
     * [pkg] was in front at [atMs] (that is when the limit was hit). Counts its foreground time in [atMs, atMs + windowMs]
     * from the usage events, and whether it left the front within [leftWithinMs].
     */
    fun measure(events: List<UsageEvent>, pkg: String, atMs: Long, windowMs: Long, leftWithinMs: Long): Outcome {
        val end = atMs + windowMs
        var inFront = true
        var since = atMs
        var total = 0L
        var firstLeave: Long? = null
        for (e in events.filter { it.timeMs in (atMs + 1)..end }.sortedBy { it.timeMs }) {
            when (e.type) {
                UsageEventType.FOREGROUND -> if (e.pkg == pkg) {
                    if (!inFront) { inFront = true; since = e.timeMs }
                } else if (inFront) {
                    total += e.timeMs - since
                    inFront = false
                    if (firstLeave == null) firstLeave = e.timeMs
                }
                UsageEventType.BACKGROUND -> if (e.pkg == pkg && inFront) {
                    total += e.timeMs - since
                    inFront = false
                    if (firstLeave == null) firstLeave = e.timeMs
                }
                else -> Unit
            }
        }
        if (inFront) total += end - since
        val left = firstLeave != null && firstLeave!! - atMs <= leftWithinMs
        return Outcome(left, (total / 1000).toInt().coerceIn(0, (windowMs / 1000).toInt()))
    }

    /** When [pkg] came to the front for the session that is still going on, or null if it is not in front. */
    fun frontSince(events: List<UsageEvent>, pkg: String): Long? {
        var since: Long? = null
        for (e in events.sortedBy { it.timeMs }) {
            when (e.type) {
                UsageEventType.FOREGROUND -> if (e.pkg == pkg) { if (since == null) since = e.timeMs } else since = null
                UsageEventType.BACKGROUND -> if (e.pkg == pkg) since = null
                else -> Unit
            }
        }
        return since
    }
}

/**
 * Demo mode: compressed thresholds so a live demo gives real results in minutes. A "limit hit" is 15 seconds in a
 * limited app, at most one a minute; the outcome is measured over that minute (left = within 20 seconds), so two
 * measurements never overlap.
 */
object DemoPolicy {
    const val SESSION_MS = 15_000L
    const val COOLDOWN_MS = 60_000L
    const val WINDOW_MS = 60_000L
    const val LEFT_WITHIN_MS = 20_000L

    fun due(frontSinceMs: Long?, nowMs: Long, lastInterventionMs: Long): Boolean =
        frontSinceMs != null && nowMs - frontSinceMs >= SESSION_MS && nowMs - lastInterventionMs >= COOLDOWN_MS
}

/** A finished experiment, in the shape the server stores (see docs/API.md, action "experiments"). */
data class ExperimentResult(
    val id: String,
    val day: String,
    val time: String,
    val app: String,
    val arm: Arm,
    val explore: Boolean,
    val reason: NudgeReason,
    val left: Boolean,
    val secondsAfter: Int,
    val windowSeconds: Int,
    val demo: Boolean,
    val propensity: Double,
    val band: Band,
    val message: String,
)
