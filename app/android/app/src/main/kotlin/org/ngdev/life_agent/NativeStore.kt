package org.ngdev.life_agent

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import org.ngdev.life_agent.core.InstalledApp

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

    // ---- what the Flutter app saved (shared_preferences keeps its values under "flutter.<key>") ----

    /** The anonymous user's session: {"a": access token, "r": refresh token, "u": user id, "e": expiry in ms}. */
    fun readAuth(): JSONObject? = flutter.getString("flutter.life.auth", null)?.let { runCatching { JSONObject(it) }.getOrNull() }

    fun writeAuth(auth: JSONObject) {
        flutter.edit().putString("flutter.life.auth", auth.toString()).apply()
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
