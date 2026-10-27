package org.ngdev.life_agent

import org.json.JSONArray
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL

/** Asks the agent for the words of a nudge, with the same anonymous session the app uses. Any failure returns null. */
class NudgeClient(private val store: NativeStore) {
    data class Answer(val text: String, val task: String?)

    fun fetch(day: String, nowHHmm: String, app: String, used: Int, limit: Int, reason: String): Answer? {
        val base = store.baseUrl ?: return null
        val key = store.apiKey ?: return null
        val token = freshToken(base, key) ?: return null
        val body = JSONObject()
            .put("action", "nudge")
            .put("today", day)
            .put("now", nowHHmm)
            .put("app", app.take(60))
            .put("used_minutes", used)
            .put("limit_minutes", limit)
            .put("reason", reason)
            .put("locale", store.locale)
            .put("done", JSONArray(store.doneTitles(day).take(20)))
        return try {
            val (status, text) = post("$base/functions/v1/agent", key, token, body.toString())
            if (status != 200) return null
            val json = JSONObject(text)
            Answer(json.getString("text"), if (json.isNull("task")) null else json.optString("task"))
        } catch (e: Exception) {
            null
        }
    }

    /** The saved token, refreshed first if it is about to expire (the app and the watcher share one session). */
    private fun freshToken(base: String, key: String): String? {
        val auth = store.readAuth() ?: return null
        val access = auth.optString("a")
        val expiresAt = auth.optLong("e", 0L)
        if (access.isNotEmpty() && expiresAt - System.currentTimeMillis() > 60_000) return access
        val refresh = auth.optString("r")
        if (refresh.isEmpty()) return null
        return try {
            val (status, text) = post("$base/auth/v1/token?grant_type=refresh_token", key, null, JSONObject().put("refresh_token", refresh).toString())
            if (status != 200) return null
            val json = JSONObject(text)
            val fresh = JSONObject()
                .put("a", json.getString("access_token"))
                .put("r", json.getString("refresh_token"))
                .put("u", json.getJSONObject("user").getString("id"))
                .put("e", System.currentTimeMillis() + json.optLong("expires_in", 3600L) * 1000L)
            store.writeAuth(fresh)
            fresh.getString("a")
        } catch (e: Exception) {
            null
        }
    }

    private fun post(url: String, key: String, token: String?, body: String): Pair<Int, String> {
        val c = URL(url).openConnection() as HttpURLConnection
        try {
            c.requestMethod = "POST"
            c.connectTimeout = 6_000
            c.readTimeout = 14_000
            c.doOutput = true
            c.setRequestProperty("Content-Type", "application/json")
            c.setRequestProperty("apikey", key)
            if (token != null) c.setRequestProperty("Authorization", "Bearer $token")
            c.outputStream.use { it.write(body.toByteArray(Charsets.UTF_8)) }
            val stream = if (c.responseCode in 200..299) c.inputStream else c.errorStream
            val text = stream?.bufferedReader(Charsets.UTF_8)?.use { it.readText() } ?: ""
            return c.responseCode to text
        } finally {
            c.disconnect()
        }
    }
}
