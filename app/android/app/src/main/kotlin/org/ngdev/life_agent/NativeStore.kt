package org.ngdev.life_agent

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import org.ngdev.life_agent.core.Arm
import org.ngdev.life_agent.core.ArmStat
import org.ngdev.life_agent.core.BankAngle
import org.ngdev.life_agent.core.BankLine
import org.ngdev.life_agent.core.Moment
import org.ngdev.life_agent.core.Band
import org.ngdev.life_agent.core.ExperimentResult
import org.ngdev.life_agent.core.InstalledApp
import org.ngdev.life_agent.core.NudgeReason
import org.ngdev.life_agent.core.SessionRule
import org.ngdev.life_agent.core.TaskLite

/** What the watcher needs to remember while the Flutter app is closed. */
class NativeStore(context: Context) {
    private val prefs = context.applicationContext.getSharedPreferences("life_native", Context.MODE_PRIVATE)
    private val flutter = context.applicationContext.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)

    data class Limit(val label: String, val pkg: String, val minutes: Int)

    fun saveLimits(limits: List<Limit>) {
        val arr = JSONArray()
        for (l in limits) arr.put(JSONObject().put("label", l.label).put("pkg", l.pkg).put("minutes", l.minutes))
        prefs.edit().putString("limits", arr.toString()).apply()
    }

    fun limits(): List<Limit> {
        val raw = prefs.getString("limits", null) ?: return emptyList()
        return try {
            val arr = JSONArray(raw)
            (0 until arr.length()).map { arr.getJSONObject(it) }.map { Limit(it.getString("label"), it.getString("pkg"), it.getInt("minutes")) }
        } catch (e: Exception) {
            emptyList()
        }
    }

    /** The user's own reminders ("whenever I am 30 minutes on an app, remind me to do 10 push-ups"). */
    fun saveRules(rules: List<SessionRule>) {
        val arr = JSONArray()
        for (r in rules) arr.put(JSONObject().put("label", r.label).put("pkg", r.pkg).put("minutes", r.minutes).put("ask", r.ask))
        prefs.edit().putString("rules", arr.toString()).apply()
    }

    fun rules(): List<SessionRule> = try {
        val arr = JSONArray(prefs.getString("rules", "[]"))
        (0 until arr.length()).map { arr.getJSONObject(it) }.map { SessionRule(it.getString("label"), it.getString("pkg"), it.getInt("minutes"), it.getString("ask")) }
    } catch (e: Exception) {
        emptyList()
    }

    /** The last thing that stopped the watcher from nudging (for Settings > Check), with when it happened. */
    fun problem(code: String) {
        prefs.edit().putString("lastProblem", code).putLong("lastProblemAt", System.currentTimeMillis()).apply()
    }

    val lastProblem: String? get() = prefs.getString("lastProblem", null)

    /** The user chose plain notifications for nudges (Settings), for phones that hide cards from apps in the background. */
    var nudgesAsNotifications: Boolean
        get() = prefs.getBoolean("nudgesAsNotifications", false)
        set(v) = prefs.edit().putBoolean("nudgesAsNotifications", v).apply()

    /** What the watcher did lately, newest last ("21:04:12 Instagram: card shown"), for Settings > Check Lify. */
    fun log(line: String) {
        val c = java.util.Calendar.getInstance()
        val at = "%02d:%02d:%02d".format(c.get(java.util.Calendar.HOUR_OF_DAY), c.get(java.util.Calendar.MINUTE), c.get(java.util.Calendar.SECOND))
        val arr = runCatching { JSONArray(prefs.getString("watchLog", "[]")) }.getOrDefault(JSONArray())
        arr.put("$at $line")
        val keep = JSONArray()
        for (i in maxOf(0, arr.length() - LOG_LINES) until arr.length()) keep.put(arr.get(i))
        prefs.edit().putString("watchLog", keep.toString()).apply()
    }

    fun logLines(): List<String> = runCatching {
        val arr = JSONArray(prefs.getString("watchLog", "[]"))
        (0 until arr.length()).map { arr.getString(it) }
    }.getOrDefault(emptyList())

    /** The watcher's last look at the phone, and the app it saw in front. */
    fun tick(front: String?) {
        prefs.edit().putLong("lastTickAt", System.currentTimeMillis()).putString("lastFront", front).apply()
    }

    val lastTickAt: Long get() = prefs.getLong("lastTickAt", 0L)
    val lastFront: String? get() = prefs.getString("lastFront", null)
    val lastProblemAt: Long get() = prefs.getLong("lastProblemAt", 0L)

    /** The sleep time for the evening reminder (one hour before), or null when it is off. */
    var eveningSleep: String?
        get() = prefs.getString("eveningSleep", null)
        set(v) = prefs.edit().putString("eveningSleep", v).apply()

    fun saveConfig(baseUrl: String, apiKey: String, locale: String) {
        prefs.edit().putString("baseUrl", baseUrl.trimEnd('/')).putString("apiKey", apiKey).putString("locale", locale).apply()
    }

    val baseUrl: String? get() = prefs.getString("baseUrl", null)
    val apiKey: String? get() = prefs.getString("apiKey", null)
    val locale: String get() = prefs.getString("locale", "en") ?: "en"

    var lastNudgeAt: Long
        get() = prefs.getLong("lastNudgeAt", 0L)
        set(v) = prefs.edit().putLong("lastNudgeAt", v).apply()

    fun sent(): Map<String, Long> {
        val raw = prefs.getString("sent", null) ?: return emptyMap()
        return try {
            val o = JSONObject(raw)
            o.keys().asSequence().associateWith { o.getLong(it) }
        } catch (e: Exception) {
            emptyMap()
        }
    }

    fun saveSent(sent: Map<String, Long>) {
        val o = JSONObject()
        for ((k, v) in sent) o.put(k, v)
        prefs.edit().putString("sent", o.toString()).apply()
    }

    // ---- experiments: which intervention works for this person (opt-in) ----

    /** The user turned on "Let Life test what works for you". */
    var experimentsOn: Boolean
        get() = prefs.getBoolean("experimentsOn", false)
        set(v) = prefs.edit().putBoolean("experimentsOn", v).apply()

    /** Compressed thresholds for a live demo (see DemoPolicy). */
    var demoMode: Boolean
        get() = prefs.getBoolean("demoMode", false)
        set(v) = prefs.edit().putBoolean("demoMode", v).apply()

    /** Results per style over all moments ([context] null), or for one app and time of day ("<package>|<band>"). */
    fun armStats(context: String? = null): Map<Arm, ArmStat> = try {
        val all = JSONObject(prefs.getString("armStats2", "{}")!!)
        val o = all.optJSONObject(context ?: "*") ?: JSONObject()
        o.keys().asSequence().mapNotNull { k -> Arm.of(k)?.let { it to ArmStat(o.getJSONObject(k).getInt("t"), o.getJSONObject(k).getInt("l")) } }.toMap()
    } catch (e: Exception) {
        emptyMap()
    }

    fun saveArmStats(stats: Map<Arm, ArmStat>, context: String? = null) {
        val all = runCatching { JSONObject(prefs.getString("armStats2", "{}")!!) }.getOrDefault(JSONObject())
        val o = JSONObject()
        for ((arm, st) in stats) o.put(arm.wire, JSONObject().put("t", st.tried).put("l", st.left))
        all.put(context ?: "*", o)
        prefs.edit().putString("armStats2", all.toString()).apply()
    }

    // ---- the night shift's nudge bank ----

    /** Saves the newest night shift from the server ({"day", "shift": {"angles": [...]}}). */
    fun saveBank(stored: JSONObject) {
        prefs.edit().putString("bank", stored.toString()).putString("bankDay", stored.optString("day")).apply()
    }

    val bankDay: String? get() = prefs.getString("bankDay", null)

    fun bank(): List<BankAngle> = try {
        val angles = JSONObject(prefs.getString("bank", "{}")!!).getJSONObject("shift").getJSONArray("angles")
        (0 until angles.length()).map { angles.getJSONObject(it) }.map { a ->
            val lines = a.getJSONArray("lines")
            val bands = a.optJSONArray("bands")
            BankAngle(
                a.getString("id"), a.optString("name"), Arm.of(a.optString("style")) ?: Arm.GOAL,
                (0 until (bands?.length() ?: 0)).mapNotNull { Band.of(bands!!.getString(it)) }.toSet().ifEmpty { Band.values().toSet() },
                a.optJSONArray("apps")?.let { x -> (0 until x.length()).map { x.getString(it) } } ?: emptyList(),
                (0 until lines.length()).map { lines.getJSONObject(it) }.map { BankLine(it.getString("id"), it.getString("text")) },
                a.optString("tone", "calm"), a.optString("topic", "other"),
            )
        }
    } catch (e: Exception) {
        emptyList()
    }

    /** Lines already shown (never shown again), the newest 400. */
    fun seenLines(): Set<String> = runCatching {
        val arr = JSONArray(prefs.getString("seenLines", "[]"))
        (0 until arr.length()).map { arr.getString(it) }.toSet()
    }.getOrDefault(emptySet())

    fun addSeen(lineId: String) {
        val arr = runCatching { JSONArray(prefs.getString("seenLines", "[]")) }.getOrDefault(JSONArray()).put(lineId)
        val keep = JSONArray()
        for (i in maxOf(0, arr.length() - 400) until arr.length()) keep.put(arr.get(i))
        prefs.edit().putString("seenLines", keep.toString()).apply()
    }

    /** Results per angle over all moments ([context] null) or for one app and time of day. */
    fun angleStats(context: String? = null): Map<String, ArmStat> = try {
        val o = JSONObject(prefs.getString("angleStats", "{}")!!).optJSONObject(context ?: "*") ?: JSONObject()
        o.keys().asSequence().associateWith { k -> ArmStat(o.getJSONObject(k).getInt("t"), o.getJSONObject(k).getInt("l")) }
    } catch (e: Exception) {
        emptyMap()
    }

    fun recordAngle(angle: String, left: Boolean, context: String) {
        val all = runCatching { JSONObject(prefs.getString("angleStats", "{}")!!) }.getOrDefault(JSONObject())
        for (key in listOf("*", context)) {
            val o = all.optJSONObject(key) ?: JSONObject()
            val s = o.optJSONObject(angle) ?: JSONObject().put("t", 0).put("l", 0)
            o.put(angle, s.put("t", s.getInt("t") + 1).put("l", s.getInt("l") + if (left) 1 else 0))
            all.put(key, o)
        }
        prefs.edit().putString("angleStats", all.toString()).apply()
    }

    /** The words of the last nudges shown, so a live nudge says something new. */
    fun recentNudges(): List<String> = pending().takeLast(5).map { it.message } +
        runCatching { val u = unsent(); (maxOf(0, u.length() - 5) until u.length()).map { u.getJSONObject(it).optString("message") } }.getOrDefault(emptyList())

    /** The user tapped "Pull me out" on the nudge [pendingId]. */
    fun markPulled(pendingId: String) {
        savePending(pending().map { if (it.id == pendingId) it.copy(pulled = true) else it })
    }

    /** When the phone last tried the night shift or fetched the bank (so it does not try again every tick). */
    var lastShiftTryAt: Long
        get() = prefs.getLong("lastShiftTryAt", 0L)
        set(v) = prefs.edit().putLong("lastShiftTryAt", v).apply()

    /** An intervention whose outcome is not measured yet. */
    data class Pending(
        val id: String, val pkg: String, val app: String, val arm: Arm, val explore: Boolean, val reason: NudgeReason,
        val atMs: Long, val day: String, val time: String, val windowMs: Long, val leftWithinMs: Long, val demo: Boolean,
        val propensity: Double, val band: Band, val message: String,
        val angle: String? = null, val lineId: String? = null, val pulled: Boolean = false,
        val moment: Moment? = null,
    )

    fun pending(): List<Pending> = try {
        val arr = JSONArray(prefs.getString("pending", "[]"))
        (0 until arr.length()).map { arr.getJSONObject(it) }.map {
            Pending(
                it.getString("id"), it.getString("pkg"), it.getString("app"), Arm.of(it.getString("arm"))!!, it.getBoolean("explore"),
                NudgeReason.values().first { r -> r.wire == it.getString("reason") }, it.getLong("at"), it.getString("day"), it.getString("time"),
                it.getLong("window"), it.getLong("leftWithin"), it.getBoolean("demo"),
                it.optDouble("propensity", 1.0), Band.of(it.optString("band")) ?: Band.NIGHT, it.optString("message"),
                it.optString("angle").takeIf { a -> a.isNotEmpty() }, it.optString("line").takeIf { l -> l.isNotEmpty() }, it.optBoolean("pulled", false),
                it.optJSONObject("moment")?.let { m -> Moment(m.getString("dayType"), m.getString("depth"), m.getBoolean("taskSoon"), m.optString("tone").ifEmpty { null }, m.optString("topic").ifEmpty { null }) },
            )
        }
    } catch (e: Exception) {
        emptyList()
    }

    fun savePending(list: List<Pending>) {
        val arr = JSONArray()
        for (p in list.takeLast(50)) {
            arr.put(
                JSONObject().put("id", p.id).put("pkg", p.pkg).put("app", p.app).put("arm", p.arm.wire).put("explore", p.explore)
                    .put("reason", p.reason.wire).put("at", p.atMs).put("day", p.day).put("time", p.time).put("window", p.windowMs)
                    .put("leftWithin", p.leftWithinMs).put("demo", p.demo)
                    .put("propensity", p.propensity).put("band", p.band.wire).put("message", p.message)
                    .put("angle", p.angle ?: "").put("line", p.lineId ?: "").put("pulled", p.pulled)
                    .apply {
                        p.moment?.let { m ->
                            put("moment", JSONObject().put("dayType", m.dayType).put("depth", m.depth).put("taskSoon", m.taskSoon).put("tone", m.tone ?: "").put("topic", m.topic ?: ""))
                        }
                    },
            )
        }
        prefs.edit().putString("pending", arr.toString()).apply()
    }

    /** Finished results not yet sent to the server (kept until an upload works, at most 200). */
    fun unsent(): JSONArray = runCatching { JSONArray(prefs.getString("unsent", "[]")) }.getOrDefault(JSONArray())

    fun queue(results: List<ExperimentResult>) {
        val arr = unsent()
        for (r in results) {
            arr.put(
                JSONObject().put("id", r.id).put("day", r.day).put("time", r.time).put("app", r.app.take(60)).put("arm", r.arm.wire)
                    .put("explore", r.explore).put("reason", r.reason.wire).put("left", r.left).put("seconds_after", r.secondsAfter)
                    .put("window_seconds", r.windowSeconds).put("demo", r.demo)
                    .put("propensity", Math.round(r.propensity * 10000) / 10000.0).put("context", r.band.wire).put("message", r.message.take(300))
                    .apply {
                        if (r.angle != null) put("angle", r.angle)
                        if (r.lineId != null) put("line_id", r.lineId)
                        if (r.pulled) put("pulled", true)
                        r.moment?.let { m ->
                            put("day_type", m.dayType).put("depth", m.depth).put("task_soon", m.taskSoon)
                            if (m.tone != null) put("tone", m.tone)
                            if (m.topic != null) put("topic", m.topic)
                        }
                    },
            )
        }
        val keep = JSONArray()
        for (i in maxOf(0, arr.length() - 200) until arr.length()) keep.put(arr.get(i))
        prefs.edit().putString("unsent", keep.toString()).apply()
    }

    /** Forgets the first [n] unsent results (they reached the server). */
    fun dropSent(n: Int) {
        val arr = unsent()
        val keep = JSONArray()
        for (i in n until arr.length()) keep.put(arr.get(i))
        prefs.edit().putString("unsent", keep.toString()).apply()
    }

    // ---- what the Flutter app saved (shared_preferences keeps its values under "flutter.<key>") ----

    /** The anonymous user's session: {"a": access token, "r": refresh token, "u": user id, "e": expiry in ms}. */
    fun readAuth(): JSONObject? = flutter.getString("flutter.life.auth", null)?.let { runCatching { JSONObject(it) }.getOrNull() }

    fun writeAuth(auth: JSONObject) {
        // commit (not apply): the app must see the new refresh token before it tries the old, spent one
        flutter.edit().putString("flutter.life.auth", auth.toString()).commit()
    }

    /** Today's tasks from the app's list (for the alarm with the next task). */
    fun tasks(day: String): List<TaskLite> {
        val raw = flutter.getString("flutter.life.tasks", null) ?: return emptyList()
        return try {
            val arr = JSONArray(raw)
            (0 until arr.length()).map { arr.getJSONObject(it) }.filter { it.optString("date") == day }.map {
                TaskLite(
                    it.getString("title"), it.optInt("minutes", 0),
                    it.optString("start_time").takeIf { t -> t.isNotEmpty() }, it.optString("first_step").takeIf { f -> f.isNotEmpty() },
                    it.optBoolean("done"),
                )
            }
        } catch (e: Exception) {
            emptyList()
        }
    }

    /** Titles of the tasks already ticked off on [day]. */
    fun doneTitles(day: String): List<String> {
        val raw = flutter.getString("flutter.life.tasks", null) ?: return emptyList()
        return try {
            val arr = JSONArray(raw)
            (0 until arr.length()).map { arr.getJSONObject(it) }.filter { it.optString("date") == day && it.optBoolean("done") }.map { it.getString("title") }
        } catch (e: Exception) {
            emptyList()
        }
    }
}

fun List<InstalledApp>.labelOf(pkg: String): String? = firstOrNull { it.pkg == pkg }?.label

private const val LOG_LINES = 25
