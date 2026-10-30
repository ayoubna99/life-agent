package org.ngdev.life_agent

import org.json.JSONArray
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL

/** Asks the agent for the words of a nudge, with the same anonymous session the app uses. Any failure returns null. */
class NudgeClient(private val store: NativeStore) {
    data class Answer(val text: String, val task: String?)

    companion object {
        /** The server gives the open model 14 s and Muse Spark 10 s: both fit. */
        const val NUDGE_WAIT_MS = 30_000

        /** The evening notification is not in a hurry: the open model may think up to 45 s. */
        const val EVENING_WAIT_MS = 60_000

        /** A failure faster than this was the connection, not the agent: worth one more try. */
        const val QUICK_FAIL_MS = 5_000L
    }

    /**
     * Asks the agent for the words. The server tries both Meta models within about 25 seconds, so the phone waits
     * [NUDGE_WAIT_MS] and asks again only after a quick failure (no connection yet): a nudge that arrives a minute late,
     * after the person left the app, is worse than none. Null means no nudge is shown at all (the app never falls back
     * to a fixed sentence: every nudge is written for this person).
     */
    fun fetch(
        day: String, nowHHmm: String, app: String, used: Int, limit: Int?, reason: String,
        eventTitle: String? = null, style: String = "task", ask: String? = null, sessionMinutes: Int? = null,
    ): Answer? {
        val started = System.currentTimeMillis()
        return fetchOnce(day, nowHHmm, app, used, limit, reason, eventTitle, style, ask, sessionMinutes)
            ?: if (System.currentTimeMillis() - started < QUICK_FAIL_MS) fetchOnce(day, nowHHmm, app, used, limit, reason, eventTitle, style, ask, sessionMinutes) else null
    }

    private fun fetchOnce(
        day: String, nowHHmm: String, app: String, used: Int, limit: Int?, reason: String,
        eventTitle: String?, style: String, ask: String?, sessionMinutes: Int?,
    ): Answer? {
        val base = store.baseUrl ?: return null.also { store.problem("not_configured") }
        val key = store.apiKey ?: return null.also { store.problem("not_configured") }
        val token = freshToken(base, key) ?: return null.also { store.problem("no_session") }
        val body = JSONObject()
            .put("action", "nudge")
            .put("today", day)
            .put("now", nowHHmm)
            .put("app", app.take(60))
            .put("used_minutes", used)
            .put("reason", reason)
            .put("style", style)
            .put("locale", store.locale)
            .put("done", JSONArray(store.doneTitles(day).take(20)))
        if (limit != null) body.put("limit_minutes", limit)
        if (eventTitle != null) body.put("event_title", eventTitle.take(120))
        if (ask != null) body.put("ask", ask.take(120))
        if (sessionMinutes != null) body.put("session_minutes", sessionMinutes)
        return try {
            val (status, text) = post("$base/functions/v1/agent", key, token, body.toString(), NUDGE_WAIT_MS)
            if (status != 200) {
                val code = runCatching { JSONObject(text).getJSONObject("error").getString("code") }.getOrNull()
                store.problem("nudge_${code ?: status}")
                return null
            }
            val json = JSONObject(text)
            Answer(json.getString("text"), if (json.isNull("task")) null else json.optString("task"))
        } catch (e: java.net.SocketTimeoutException) {
            store.problem("nudge_slow")
            null
        } catch (e: Exception) {
            store.problem("network")
            null
        }
    }

    /** The evening reminder's words: null when tomorrow is already planned or the agent cannot be reached (tried twice). */
    fun evening(today: String, tomorrow: String, nowHHmm: String): String? {
        for (attempt in 1..2) {
            val base = store.baseUrl ?: return null
            val key = store.apiKey ?: return null
            val token = freshToken(base, key) ?: return null
            val tasks = store.tasks(today)
            val body = JSONObject()
                .put("action", "evening").put("today", today).put("tomorrow", tomorrow).put("now", nowHHmm).put("locale", store.locale)
                .put("done", JSONArray(tasks.filter { it.done }.map { it.title }.take(20)))
                .put("missed", JSONArray(tasks.filter { !it.done }.map { it.title }.take(20)))
            try {
                val (status, text) = post("$base/functions/v1/agent", key, token, body.toString(), EVENING_WAIT_MS)
                if (status == 200) {
                    val json = JSONObject(text)
                    return if (json.optBoolean("planned")) null else json.optString("text").takeIf { it.isNotBlank() }
                }
            } catch (e: Exception) {
                // try once more
            }
        }
        return null
    }

    /** Sends the finished experiment results waiting on the phone (at most 50 at a time). Returns how many were stored. */
    fun sendExperiments(): Int {
        val waiting = store.unsent()
        if (waiting.length() == 0) return 0
        val base = store.baseUrl ?: return 0
        val key = store.apiKey ?: return 0
        val token = freshToken(base, key) ?: return 0
        val batch = JSONArray()
        for (i in 0 until minOf(50, waiting.length())) batch.put(waiting.get(i))
        return try {
            val (status, _) = post("$base/functions/v1/agent", key, token, JSONObject().put("action", "experiments").put("log", batch).toString())
            if (status == 200) {
                store.dropSent(batch.length())
                batch.length()
            } else if (status == 422) {
                store.dropSent(batch.length()) // refused as malformed: retrying would never work
                0
            } else 0
        } catch (e: Exception) {
            0
        }
    }

    /**
     * The saved token, refreshed first if it is about to expire (the app and the watcher share one session, and each
     * refresh token works once). If the refresh is refused, the app may have refreshed at the same moment: read what is
     * saved again and use that. Never signs up a new user (that would lose the user's plans): null instead.
     */
    private fun freshToken(base: String, key: String): String? {
        val auth = store.readAuth() ?: return null
        usable(auth)?.let { return it }
        refresh(base, key, auth.optString("r"))?.let { return it }
        val again = store.readAuth() ?: return null
        if (again.optString("r") == auth.optString("r")) return null
        return usable(again) ?: refresh(base, key, again.optString("r"))
    }

    private fun usable(auth: JSONObject): String? {
        val access = auth.optString("a")
        return if (access.isNotEmpty() && auth.optLong("e", 0L) - System.currentTimeMillis() > 60_000) access else null
    }

    private fun refresh(base: String, key: String, refresh: String): String? {
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

    private fun post(url: String, key: String, token: String?, body: String, waitMs: Int = 14_000): Pair<Int, String> {
        val c = URL(url).openConnection() as HttpURLConnection
        try {
            c.requestMethod = "POST"
            c.connectTimeout = 6_000
            c.readTimeout = waitMs
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
