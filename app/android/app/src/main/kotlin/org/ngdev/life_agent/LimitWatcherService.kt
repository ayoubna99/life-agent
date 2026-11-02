package org.ngdev.life_agent

import android.app.Service
import android.app.AppOpsManager
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.IBinder
import android.os.Process
import org.ngdev.life_agent.core.Arm
import org.ngdev.life_agent.core.Band
import org.ngdev.life_agent.core.Bandit
import org.ngdev.life_agent.core.ContextualBandit
import org.ngdev.life_agent.core.DayRules
import org.ngdev.life_agent.core.DemoPolicy
import org.ngdev.life_agent.core.ExperimentResult
import org.ngdev.life_agent.core.NudgeDecision
import org.ngdev.life_agent.core.NudgePolicy
import org.ngdev.life_agent.core.NudgeReason
import org.ngdev.life_agent.core.NudgeTitle
import org.ngdev.life_agent.core.NudgeBank
import org.ngdev.life_agent.core.LogicalDay
import org.ngdev.life_agent.core.Moment
import org.ngdev.life_agent.core.MomentAction
import org.ngdev.life_agent.core.MomentKind
import org.ngdev.life_agent.core.MomentNudge
import org.ngdev.life_agent.core.Moments
import org.ngdev.life_agent.core.SessionRules
import org.ngdev.life_agent.core.OutcomeMeter
import org.ngdev.life_agent.core.UsageAggregator
import java.util.Calendar
import java.util.Random
import java.util.TimeZone
import java.util.UUID

/**
 * Watches the apps that have a daily limit, and the user's own reminder rules. When one is in front and the limit is near, reached or passed (or it is opened
 * during a calendar event), it sends a personal nudge notification written by the agent. With experiments on, CODE picks
 * the nudge style by Thompson sampling (see Bandit), then measures what happened next and sends the result to the server. Runs as a foreground service (Android requires the small
 * "Life is watching your limits" notification) and stops by itself when no app has a limit.
 */
class LimitWatcherService : Service() {
    private lateinit var thread: HandlerThread
    private lateinit var handler: Handler
    private lateinit var store: NativeStore
    private lateinit var reader: UsageReader
    private lateinit var nudger: Nudger
    private lateinit var calendar: CalendarReader
    private val rnd = Random()
    @Volatile private var running = false

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        store = NativeStore(this)
        reader = UsageReader(this)
        nudger = Nudger(this)
        calendar = CalendarReader(this)
        Nudger.ensureChannels(this)
        thread = HandlerThread("life-watcher", Process.THREAD_PRIORITY_BACKGROUND).also { it.start() }
        handler = Handler(thread.looper)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // Foreground first, always: Android stops an app that was asked to start a foreground service and did not. While
        // in the foreground the phone keeps Life running when you leave it; without it Life is paused in the background
        // and the nudges waited until you came back.
        // Android requires a notification while the watcher runs: as quiet as allowed (no sound, lowest importance, no text)
        val note = Nudger.builder(this, Nudger.CHANNEL_WATCHER)
            .setSmallIcon(Nudger.smallIcon(this))
            .setContentTitle("Life")
            .setShowWhen(false)
            .setContentIntent(Nudger.openAppIntent(this))
            .setOngoing(true)
            .build()
        try {
            if (Build.VERSION.SDK_INT >= 34) startForeground(1, note, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE) else startForeground(1, note)
        } catch (e: Exception) {
            store.problem("watcher_not_allowed")
            store.log("the phone did not let the watcher run (${e.javaClass.simpleName})")
            stopSelf()
            return START_NOT_STICKY
        }
        if (!hasWork(store)) {
            stopSelf()
            return START_NOT_STICKY
        }
        if (!running) {
            running = true
            alive = true
            store.log("watcher started")
            handler.post { tick() }
        }
        return START_STICKY
    }

    override fun onDestroy() {
        running = false
        alive = false
        handler.removeCallbacksAndMessages(null)
        thread.quitSafely()
        super.onDestroy()
    }

    private fun tick() {
        if (!running) return
        var next = 30_000L
        try {
            next = check()
        } catch (e: Exception) {
            // never let one bad reading stop the watcher
            runCatching { store.log("error: ${e.javaClass.simpleName}") }
        }
        if (running) handler.postDelayed({ tick() }, next)
    }

    /** One look at the phone. Returns how long to wait before the next one. */
    private fun check(): Long {
        val limits = store.limits()
        val rules = store.rules()
        if (limits.isEmpty() && rules.isEmpty()) {
            running = false
            stopSelf()
            return 60_000L
        }
        if (!hasUsageAccess(this)) {
            store.problem("no_usage_access")
            store.tick(null)
            return 60_000L
        }

        val now = System.currentTimeMillis()
        val tz = TimeZone.getDefault()
        finishExperiments(now)
        maybeNightShift(now, tz)

        val start = UsageAggregator.startOfDay(now, tz)
        val events = reader.events(start, now)
        val demo = store.demoMode
        val idle = if (demo) 10_000L else 30_000L
        val front = UsageAggregator.appInFront(events.filter { it.timeMs >= now - UsageAggregator.MAX_SESSION_MS })
        store.tick(front)
        if (front == null || front == packageName) return idle
        val day = UsageAggregator.dayKey(now, tz)
        val sent = NudgePolicy.keepOnly(day, store.sent())
        val cal = Calendar.getInstance(tz).apply { timeInMillis = now }
        val hhmm = "%02d:%02d".format(cal.get(Calendar.HOUR_OF_DAY), cal.get(Calendar.MINUTE))
        val usedMs = UsageAggregator.perDay(events, now, tz)[day]?.get(front) ?: 0L
        val used = (usedMs / 60_000L).toInt()

        // 1. The user's own reminders ("whenever I am 30 minutes on an app, remind me to do 10 push-ups").
        val since = OutcomeMeter.sessionSince(events, front)
        SessionRules.due(rules, front, since, now, day, sent.keys)?.let { (rule, key) ->
            store.saveSent(sent + (key to now)) // once per step, even if the agent cannot be reached
            val label = if (rule.pkg == SessionRules.ANY) appLabel(front) else rule.label
            val minutes = ((now - since!!) / 60_000L).toInt()
            store.log("$label: ${minutes} min, your reminder is due, asking Lify")
            val answer = NudgeClient(store).fetch(day, hhmm, label, used, null, "session", ask = rule.ask, sessionMinutes = minutes)
            if (answer == null) {
                store.log("$label: Lify did not answer (${store.lastProblem ?: "?"}), skipped")
            } else if (stillInFront(front)) {
                store.lastNudgeAt = now
                nudger.card(
                    NudgeTitle.onApp(minutes, label), answer.text, front, 2500 + (front.hashCode() and 0xFFF),
                    pull = "rule", actionLabel = "Done", actionOpen = "done",
                ) { how -> store.log("$label: reminder shown as $how") }
            } else {
                store.log("$label: you left before it was ready, not shown")
            }
            return 20_000L
        }

        // 2. Moments: a nudge carrying one fact true only for this person, right now (core/Moments.kt).
        if (rules.none { it.pkg == front }) {
            val limitMin = limits.firstOrNull { it.pkg == front }?.minutes ?: 0
            momentNudge(front, events, now, tz, day, hhmm, used, limitMin, sent, limits.map { it.pkg }.toSet(), demo, cal)?.let { return it }
        }

        // 3. Daily limits. A rule the user made for THIS app replaces its limit nudges (one voice, not two). A rule for
        // any app does not: it counts time in a row, and hours of short sessions would never get a nudge.
        if (rules.any { it.pkg == front }) return idle
        val limit = limits.firstOrNull { it.pkg == front } ?: return idle
        val event = runCatching { DayRules.currentEvent(calendar.events(now - 12 * 3600_000L, now + 60_000L), now) }.getOrNull()
        val decision: NudgeDecision = when {
            event != null -> NudgePolicy.decideEvent(day, front, event.startMs, now, store.lastNudgeAt, sent)
            demo -> if (DemoPolicy.due(OutcomeMeter.frontSince(events, front), now, store.lastNudgeAt)) NudgeDecision(NudgeReason.DEMO, "$day|$front|demo|$now", now) else null
            else -> NudgePolicy.decide(day, front, used, limit.minutes, now, store.lastNudgeAt, sent)
        } ?: return if (demo) 5_000L else 20_000L

        if (decision.reason != NudgeReason.DEMO) store.saveSent(sent + (decision.key to decision.value))
        store.lastNudgeAt = now

        val band = Band.of(cal.get(Calendar.HOUR_OF_DAY))
        val context = "$front|${band.wire}"
        // First choice: tonight's nudge bank from the night shift. Code picks the ANGLE by contextual Thompson sampling
        // and shows its next unseen line at once (no waiting, no network). Without a bank (first day, or every line
        // used): the style bandit, and the agent writes the line live.
        val nextTask = DayRules.importantNext(store.tasks(LogicalDay.today(now, tz)), hhmm)?.title
        // about 1 in 10 is held back on purpose (no card): what happens without a nudge, for an honest comparison
        val holdout = !demo && rnd.nextDouble() < Moments.HOLDOUT
        val fromBank = NudgeBank.pick(store.bank(), band, limit.label, store.seenLines(), store.angleStats(), store.angleStats(context), rnd, nextTask)
        val arm: Arm
        val explore: Boolean
        val propensity: Double
        val text: String
        if (fromBank != null) {
            arm = fromBank.angle.style
            explore = fromBank.explore
            propensity = fromBank.propensity
            text = fromBank.text
            store.addSeen(fromBank.line.id)
            store.log("${limit.label}: $used/${limit.minutes} min, ${decision.reason.wire}, bank angle ${fromBank.angle.id}")
        } else if (holdout) {
            val pick = ContextualBandit.decide(Arm.values().toList(), store.armStats(), store.armStats(context), rnd, true)
            arm = pick.arm
            explore = pick.explore
            propensity = pick.propensity
            text = ""
        } else {
            val pick = ContextualBandit.decide(Arm.values().toList(), store.armStats(), store.armStats(context), rnd, true)
            val wire = if (decision.reason == NudgeReason.DEMO) NudgeReason.LIMIT.wire else decision.reason.wire
            store.log("${limit.label}: $used/${limit.minutes} min, ${decision.reason.wire}, no bank line left, asking Lify (${pick.arm.wire})")
            val answer = NudgeClient(store).fetch(day, hhmm, limit.label, used, limit.minutes, wire, event?.title, pick.arm.wire)
            // Never a fixed sentence: if the agent cannot be reached, this nudge is skipped and not measured.
            if (answer == null) {
                store.log("${limit.label}: Lify did not answer (${store.lastProblem ?: "?"}), skipped")
                return if (demo) 5_000L else 20_000L
            }
            // The person may have left while the words were written: a card on another app would make no sense.
            if (!stillInFront(front)) {
                store.log("${limit.label}: you left before it was ready, not shown")
                return if (demo) 5_000L else 20_000L
            }
            arm = pick.arm
            explore = pick.explore
            propensity = pick.propensity
            text = answer.text
        }
        val title = if (event != null) "During ${event.title}" else NudgeTitle.onApp(used, limit.label)
        val shownAt = System.currentTimeMillis()
        val pendingId = UUID.randomUUID().toString()
        if (holdout) {
            store.log("${limit.label}: held back on purpose (control group): no card this time")
        } else {
            nudger.card(title, text, front, 2000 + (front.hashCode() and 0xFFF), pull = pendingId) { how -> store.log("${limit.label}: nudge shown as $how") }
        }
        // Always measured on the phone (that is how Lify learns what works); sent to the server only with experiments on.
        store.savePending(
            store.pending() + NativeStore.Pending(
                id = pendingId, pkg = front, app = limit.label, arm = arm, explore = explore,
                reason = decision.reason, atMs = shownAt, day = day, time = hhmm,
                windowMs = if (demo) DemoPolicy.WINDOW_MS else OutcomeMeter.WINDOW_MS,
                leftWithinMs = if (demo) DemoPolicy.LEFT_WITHIN_MS else OutcomeMeter.LEFT_WITHIN_MS,
                demo = demo, propensity = propensity, band = band, message = text,
                angle = fromBank?.angle?.id, lineId = fromBank?.line?.id, task = nextTask, holdout = holdout,
                moment = Moment(
                    Moment.dayType(cal.get(Calendar.DAY_OF_WEEK)), Moment.depth(used, limit.minutes),
                    Moment.taskSoon(store.tasks(LogicalDay.today(now, tz)), hhmm), fromBank?.angle?.tone, fromBank?.angle?.topic,
                ),
            ),
        )
        return if (demo) 5_000L else 20_000L
    }

    /**
     * The night shift runs on the server; the watcher only asks for it. In the evening (from 20:00 to 04:00) when there
     * is no bank for tomorrow yet: "study" then "critic" (the study may think for two minutes, so on its own thread).
     * During the day when the bank is older than today: fetch the newest one. At most one try per hour.
     */
    private fun maybeNightShift(now: Long, tz: TimeZone) {
        if (now - store.lastShiftTryAt < 60 * 60_000L) return
        val hour = Calendar.getInstance(tz).apply { timeInMillis = now }.get(Calendar.HOUR_OF_DAY)
        val today = LogicalDay.today(now, tz)
        val tomorrow = LogicalDay.tomorrow(now, tz)
        val have = store.bankDay
        val evening = hour >= 20 || hour < 4
        val step = when {
            evening && have != tomorrow -> "study"
            have == null || have < today -> "get"
            else -> return
        }
        store.lastShiftTryAt = now
        Thread {
            val client = NudgeClient(store)
            val shift = if (step == "study") client.nightShift("study", tomorrow)?.let { client.nightShift("critic", tomorrow) ?: it } else client.nightShift("get", null)
            if (shift != null && shift.optJSONObject("shift") != null) {
                store.saveBank(shift)
                store.log("night shift: bank for ${shift.optString("day")} ready (${shift.optString("status")})")
            } else if (step == "study") {
                store.log("night shift: could not run (${store.lastProblem ?: "no answer"}), next try in an hour")
            }
        }.start()
    }

    /** Measures the interventions whose window is over, updates the scores and sends the results (best effort). */
    private fun finishExperiments(now: Long) {
        val pending = store.pending()
        if (pending.isNotEmpty()) {
            val (due, waiting) = pending.partition { now >= it.atMs + it.windowMs }
            val feeds = store.limits().map { it.pkg }.toSet()
            if (due.isNotEmpty()) {
                var stats = store.armStats()
                val results = due.map { p ->
                    val o = OutcomeMeter.measure(reader.events(p.atMs - 1000, p.atMs + p.windowMs), p.pkg, p.atMs, p.windowMs, p.leftWithinMs, feeds)
                    // success = left AND stayed off the feeds (straight back to TikTok is not a success), or tapped the button
                    val success = o.stayedOff || p.pulled
                    val context = "${p.pkg}|${p.band.wire}"
                    if (!p.holdout) { // the control group only measures; it teaches no idea anything
                        if (p.angle?.startsWith("moment_") != true) {
                            stats = Bandit.record(stats, p.arm, success)
                            store.saveArmStats(Bandit.record(store.armStats(context), p.arm, success), context)
                        }
                        if (p.angle != null) store.recordAngle(p.angle, success, context)
                    }
                    ExperimentResult(
                        p.id, p.day, p.time, p.app, p.arm, p.explore, p.reason, o.left || p.pulled, o.secondsAfter, (p.windowMs / 1000).toInt(), p.demo,
                        p.propensity, p.band, p.message, p.angle, p.lineId, p.pulled, p.moment, p.holdout, o.backToFeed,
                    )
                }
                store.saveArmStats(stats)
                if (store.experimentsOn) store.queue(results)
                store.savePending(waiting)
            }
        }
        if (store.unsent().length() > 0) NudgeClient(store).sendExperiments()
    }

    private val sessionCache = HashMap<String, Pair<Long, List<Int>>>()

    /** The finished sessions on [pkg] in the last 14 days (minutes), worked out at most once an hour. */
    private fun pastSessions(pkg: String, now: Long): List<Int> {
        sessionCache[pkg]?.let { (at, list) -> if (now - at < 60 * 60_000L) return list }
        val list = runCatching { Moments.sessionLengths(reader.events(now - 14L * 24 * 3600_000L, now), pkg) }.getOrDefault(emptyList())
        sessionCache[pkg] = now to list
        return list
    }

    private var skip: Set<String>? = null

    /** Apps that are not a choice in the "what did you pick the phone up for" sequence: home screens, system UI, Life. */
    private fun skipPkgs(): Set<String> = skip ?: runCatching {
        val home = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_HOME)
        packageManager.queryIntentActivities(home, 0).map { it.activityInfo.packageName }.toSet() + setOf(packageName, "com.android.systemui")
    }.getOrDefault(setOf(packageName, "com.android.systemui")).also { skip = it }

    /** One moment a day per kind and app (the phone-down one once a night): never the same fact twice. */
    private fun gateKey(m: MomentNudge, day: String, logicalDay: String, pkg: String) =
        if (m.kind == MomentKind.PHONE_DOWN) "$day|*|m|phone_down|$logicalDay" else "$day|$pkg|m|${m.kind.wire}"

    /**
     * Moments (core/Moments.kt). Code works out every fact; Thompson sampling picks which moment; about 1 in 10 is held
     * back; Muse Spark Open phrases the rest (the server keeps its line only if every number in it is one of the facts).
     */
    private fun momentNudge(
        front: String, events: List<org.ngdev.life_agent.core.UsageEvent>, now: Long, tz: TimeZone, day: String, hhmm: String,
        used: Int, limitMin: Int, sent: Map<String, Long>, feeds: Set<String>, demo: Boolean, cal: Calendar,
    ): Long? {
        if (front !in feeds) return null
        if (now - store.lastNudgeAt < (if (demo) DemoPolicy.COOLDOWN_MS else NudgePolicy.COOLDOWN_MS)) return null
        val label = appLabel(front)
        val today = LogicalDay.today(now, tz)
        val tasks = store.tasks(today)
        val next = DayRules.importantNext(tasks, hhmm)
        val nextAction = next?.let { MomentAction("Open: ${it.title}".take(40), "task:${it.title}") } ?: MomentAction("Pull me out", "pull")
        val since = OutcomeMeter.sessionSince(events, front)
        val current = if (since == null) 0 else ((now - since) / 60_000L).toInt()
        val candidates = listOfNotNull(
            Moments.lostIntent(events, now, front, feeds, skipPkgs(), ::appLabel, if (demo) 1 else Moments.LOST_AFTER_MIN),
            Moments.exitPoint(pastSessions(front, now), current, label, nextAction, if (demo) 2 else Moments.MIN_SESSIONS),
            Moments.plannedNow(tasks, hhmm),
            Moments.phoneDown(store.eveningSleep, hhmm, store.tasks(LogicalDay.tomorrow(now, tz))),
        ).filter { demo || gateKey(it, day, today, front) !in sent } // demo mode: as many takes as needed
        if (candidates.isEmpty()) return null
        val band = Band.of(cal.get(Calendar.HOUR_OF_DAY))
        val context = "$front|${band.wire}"
        val (m, propensity) = Moments.pick(candidates, store.angleStats(), store.angleStats(context), rnd) ?: return null
        store.saveSent(sent + (gateKey(m, day, today, front) to now))
        store.lastNudgeAt = now
        val holdout = !demo && rnd.nextDouble() < Moments.HOLDOUT
        val pendingId = UUID.randomUUID().toString()
        var text = m.text
        if (holdout) {
            store.log("$label: moment ${m.kind.wire}, held back on purpose (control group)")
        } else {
            store.log("$label: moment ${m.kind.wire}: ${m.text}")
            text = NudgeClient(store).moment(day, hhmm, label, used, m.kind.wire, m.facts, m.text)
            if (!stillInFront(front)) {
                store.log("$label: you left before it was ready, not shown")
                return if (demo) 5_000L else 20_000L
            }
            val direct = m.action.open.startsWith("app:") || m.action.open == "done"
            nudger.card(
                m.title, text, front, 2700 + (front.hashCode() and 0xFFF), pull = pendingId,
                actionLabel = m.action.label, actionOpen = if (direct) m.action.open else null,
            ) { how -> store.log("$label: moment ${m.kind.wire} shown as $how") }
        }
        store.savePending(
            store.pending() + NativeStore.Pending(
                id = pendingId, pkg = front, app = label, arm = Arm.GOAL, explore = false,
                reason = NudgeReason.MOMENT, atMs = System.currentTimeMillis(), day = day, time = hhmm,
                windowMs = if (demo) DemoPolicy.WINDOW_MS else OutcomeMeter.WINDOW_MS,
                leftWithinMs = if (demo) DemoPolicy.LEFT_WITHIN_MS else OutcomeMeter.LEFT_WITHIN_MS,
                demo = demo, propensity = propensity, band = band, message = text, angle = m.kind.key,
                task = if (m.action.open.startsWith("task:")) m.action.open.removePrefix("task:") else null, holdout = holdout,
                moment = Moment(Moment.dayType(cal.get(Calendar.DAY_OF_WEEK)), Moment.depth(used, maxOf(limitMin, 1)), next != null, null, null),
            ),
        )
        return if (demo) 5_000L else 20_000L
    }

    /** Whether [pkg] is still the app in front (checked again after waiting for the agent). */
    private fun stillInFront(pkg: String): Boolean {
        val now = System.currentTimeMillis()
        return UsageAggregator.appInFront(reader.events(now - UsageAggregator.MAX_SESSION_MS, now)) == pkg
    }

    private var labels: Map<String, String>? = null

    /** The name under the app's icon (for the any-app reminder), looked up once per watcher run. */
    private fun appLabel(pkg: String): String {
        val known = labels ?: Apps.launchable(this).associate { it.pkg to it.label }.also { labels = it }
        return known[pkg] ?: "this app"
    }

    companion object {
        /** Whether the watcher is running right now (for Settings > Check). */
        @Volatile var alive = false

        /** Anything to watch: a daily limit or a reminder rule. */
        fun hasWork(store: NativeStore): Boolean = store.limits().isNotEmpty() || store.rules().isNotEmpty()

        fun hasUsageAccess(context: Context): Boolean {
            val ops = context.getSystemService(Context.APP_OPS_SERVICE) as AppOpsManager
            val mode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                ops.unsafeCheckOpNoThrow(AppOpsManager.OPSTR_GET_USAGE_STATS, Process.myUid(), context.packageName)
            } else {
                @Suppress("DEPRECATION") ops.checkOpNoThrow(AppOpsManager.OPSTR_GET_USAGE_STATS, Process.myUid(), context.packageName)
            }
            return mode == AppOpsManager.MODE_ALLOWED
        }

        /** Starts the watcher if any app has a limit, stops it if none has. */
        fun sync(context: Context) {
            val intent = Intent(context, LimitWatcherService::class.java)
            if (!hasWork(NativeStore(context))) {
                context.stopService(intent)
                Watchdog.cancel(context)
                return
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
            Watchdog.schedule(context)
        }
    }
}
