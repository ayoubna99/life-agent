package org.ngdev.life_agent

import android.Manifest
import android.app.AlarmManager
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.ngdev.life_agent.core.AppMatcher
import org.ngdev.life_agent.core.PhoneNights
import org.ngdev.life_agent.core.SessionRule
import org.ngdev.life_agent.core.SessionRules
import org.ngdev.life_agent.core.UsageAggregator
import java.util.TimeZone

/** The bridge for everything only Android can do. The Dart side is lib/platform/native.dart. */
class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        super.onCreate(savedInstanceState)
        remember(intent)
    }

    private var channel: MethodChannel? = null

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        remember(intent)
        // Life was already open (the user tapped the evening notification without leaving it): there is no "resumed"
        // to notice it, so tell the Flutter side now.
        if (intent.getStringExtra(EXTRA_OPEN) != null) runCatching { channel?.invokeMethod("launchAction", null) }
    }

    /** A notification asked to open a screen ("plan"): kept until the Flutter side takes it. */
    private fun remember(intent: Intent?) {
        val open = intent?.getStringExtra(EXTRA_OPEN) ?: return
        if (open.startsWith("pull:")) {
            // "Pull me out" on a nudge: the tap counts in that nudge's result, then Life shows what matters next
            NativeStore(this).markPulled(open.removePrefix("pull:"))
            pendingOpen = "pull"
        } else {
            pendingOpen = open
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        channel!!.setMethodCallHandler { call, result ->
            try {
                handle(call, result)
            } catch (e: Exception) {
                result.error("native_error", e.javaClass.simpleName, null)
            }
        }
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "hasUsageAccess" -> result.success(LimitWatcherService.hasUsageAccess(this))
            "openUsageAccessSettings" -> {
                startActivity(Intent(Settings.ACTION_USAGE_ACCESS_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                result.success(null)
            }
            "usageSummary" -> usageSummary(call.argument<Int>("days") ?: 7, result)
            "installedApps" -> result.success(Apps.launchable(this).map { it.label }.distinct())
            "canScheduleExactAlarms" -> result.success(canExact())
            "openExactAlarmSettings" -> {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                    startActivity(Intent(Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM, Uri.parse("package:$packageName")).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                }
                result.success(null)
            }
            "scheduleAlarm" -> result.success(scheduleAlarm(call.argument<String>("id")!!, call.argument<Number>("at")!!.toLong(), call.argument<String>("message")!!, call.argument<Boolean>("card") ?: false, call.argument<String>("title"), call.argument<String>("open")))
            "setPhoneAlarm" -> result.success(setPhoneAlarm(call.argument<Int>("hour")!!, call.argument<Int>("minute")!!, call.argument<String>("message")!!))
            "stopAlarmSound" -> {
                AlarmSound.stop()
                result.success(null)
            }
            "cancelAlarm" -> {
                cancelAlarm(call.argument<String>("id")!!)
                result.success(null)
            }
            "applyLimits" -> result.success(applyLimits(call.argument<Map<String, Number>>("limits") ?: emptyMap()))
            "configureNudges" -> {
                NativeStore(this).saveConfig(call.argument<String>("baseUrl")!!, call.argument<String>("apiKey")!!, call.argument<String>("locale") ?: "en")
                LimitWatcherService.sync(this)
                result.success(null)
            }
            "notificationsAllowed" -> result.success((getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager).areNotificationsEnabled())
            "requestNotifications" -> {
                if (Build.VERSION.SDK_INT >= 33) requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 1001)
                result.success(null)
            }
            "applyRules" -> result.success(applyRules(call.argument<List<Map<String, Any>>>("rules") ?: emptyList()))
            "configureExperiments" -> {
                val store = NativeStore(this)
                store.experimentsOn = call.argument<Boolean>("enabled") ?: false
                store.demoMode = call.argument<Boolean>("demo") ?: false
                LimitWatcherService.sync(this)
                result.success(null)
            }
            "watcherStatus" -> watcherStatus(result)
            "playAudio" -> {
                playWav(call.argument<ByteArray>("wav")!!)
                result.success(null)
            }
            "stopAudio" -> {
                player?.let { runCatching { it.stop(); it.release() } }
                player = null
                result.success(null)
            }
            "setNudgeBank" -> {
                NativeStore(this).saveBank(org.json.JSONObject(call.argument<String>("shift")!!))
                result.success(null)
            }
            "setNudgesAsNotifications" -> {
                NativeStore(this).nudgesAsNotifications = call.argument<Boolean>("on") == true
                result.success(null)
            }
            "takeLaunchAction" -> {
                result.success(pendingOpen)
                pendingOpen = null
            }
            "configureEvening" -> {
                NativeStore(this).eveningSleep = call.argument<String>("sleep")
                EveningReminder.schedule(this)
                result.success(null)
            }
            "phoneNights" -> phoneNights(call.argument<Int>("nights") ?: 7, result)
            "hasCalendarAccess" -> result.success(CalendarReader(this).allowed())
            "requestCalendar" -> {
                requestPermissions(arrayOf(Manifest.permission.READ_CALENDAR), 1002)
                result.success(null)
            }
            "calendarEvents" -> calendarEvents(call.argument<String>("date")!!, result)
            "canDrawOverlay" -> result.success(Nudger(this).canOverlay())
            "openBatterySettings" -> {
                val ask = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, Uri.parse("package:$packageName")).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                if (runCatching { startActivity(ask) }.isFailure) {
                    startActivity(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                }
                result.success(null)
            }
            "openPopupSettings" -> {
                // Xiaomi, Redmi and POCO hold back cards from apps in the background unless "Display pop-up windows while
                // running in the background" is allowed: their own permission screen, else the app's settings page.
                val miui = Intent("miui.intent.action.APP_PERM_EDITOR")
                    .setClassName("com.miui.securitycenter", "com.miui.permcenter.permissions.PermissionsEditorActivity")
                    .putExtra("extra_pkgname", packageName).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                if (runCatching { startActivity(miui) }.isFailure) {
                    startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:$packageName")).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                }
                result.success(null)
            }
            "openOverlaySettings" -> {
                startActivity(Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION, Uri.parse("package:$packageName")).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private var player: android.media.MediaPlayer? = null

    /** Lify's voice: plays a WAV from the agent (a new one stops the one still playing). */
    private fun playWav(wav: ByteArray) {
        player?.let { runCatching { it.stop(); it.release() } }
        val file = java.io.File(cacheDir, "lify-voice.wav").apply { writeBytes(wav) }
        player = android.media.MediaPlayer().apply {
            setAudioAttributes(
                android.media.AudioAttributes.Builder()
                    .setUsage(android.media.AudioAttributes.USAGE_ASSISTANT)
                    .setContentType(android.media.AudioAttributes.CONTENT_TYPE_SPEECH)
                    .build(),
            )
            setDataSource(file.absolutePath)
            setOnCompletionListener { it.release(); if (player === it) player = null }
            prepare()
            start()
        }
    }

    /** Settings > Check Lify. Off the main thread: it reads three nights of usage events to say what it sees. */
    private fun watcherStatus(result: MethodChannel.Result) {
        val app = applicationContext
        val main = android.os.Handler(android.os.Looper.getMainLooper())
        Thread {
            val st = NativeStore(app)
            val nudger = Nudger(app)
            val nights = runCatching {
                if (!LimitWatcherService.hasUsageAccess(app)) emptyList()
                else {
                    val now = System.currentTimeMillis()
                    val tz = TimeZone.getDefault()
                    PhoneNights.report(UsageReader(app).events(UsageAggregator.startOfDay(now, tz) - 4 * 24L * 3600 * 1000, now), now, tz, 3)
                }
            }.getOrDefault(emptyList())
            val status = mapOf(
                "running" to LimitWatcherService.alive,
                "limits" to st.limits().map { "${it.label} ${it.minutes} min" },
                "rules" to st.rules().size,
                "experiments" to st.experimentsOn,
                "demo" to st.demoMode,
                "usageAccess" to LimitWatcherService.hasUsageAccess(app),
                "overlay" to nudger.canOverlay(),
                "popupBlocked" to nudger.popupBlocked(),
                "asNotifications" to st.nudgesAsNotifications,
                "lastProblem" to st.lastProblem,
                "lastProblemAt" to st.lastProblemAt,
                "lastNudgeAt" to st.lastNudgeAt,
                "unsentResults" to st.unsent().length(),
                "eveningSleep" to st.eveningSleep,
                "lastTickAt" to st.lastTickAt,
                "lastFront" to st.lastFront,
                "log" to st.logLines(),
                "battery" to ignoresBattery(),
                "maker" to Build.MANUFACTURER.lowercase(),
                "nights" to nights,
            )
            main.post { result.success(status) }
        }.start()
    }

    private fun ignoresBattery(): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.M ||
            (getSystemService(Context.POWER_SERVICE) as android.os.PowerManager).isIgnoringBatteryOptimizations(packageName)

    /** Minutes per app per day, off the main thread (a week of events can be a lot). */
    private fun usageSummary(days: Int, result: MethodChannel.Result) {
        val app = applicationContext
        Thread {
            try {
                val tz = TimeZone.getDefault()
                val now = System.currentTimeMillis()
                val from = UsageAggregator.startOfDay(now - (days.coerceIn(1, 14) - 1) * 24L * 60 * 60 * 1000, tz)
                val events = UsageReader(app).events(from, now)
                val launchable = Apps.launchable(app)
                val rows = UsageAggregator.summary(UsageAggregator.perDay(events, now, tz)) { launchable.labelOf(it) }
                    .map { mapOf("day" to it.day, "app" to it.app, "minutes" to it.minutes) }
                runOnUiThread { result.success(rows) }
            } catch (e: Exception) {
                runOnUiThread { result.error("usage_failed", e.javaClass.simpleName, null) }
            }
        }.start()
    }

    /** When the phone went quiet each of the last nights (from its usage events), read off the main thread. */
    private fun phoneNights(nights: Int, result: MethodChannel.Result) {
        val app = applicationContext
        Thread {
            try {
                val now = System.currentTimeMillis()
                val tz = TimeZone.getDefault()
                val from = UsageAggregator.startOfDay(now, tz) - (nights.coerceIn(1, 14) + 1) * 24L * 3600 * 1000
                val rows = PhoneNights.detect(UsageReader(app).events(from, now), now, tz, nights.coerceIn(1, 14))
                    .map { mapOf("night" to it.night, "down" to it.down, "up" to it.up) }
                runOnUiThread { result.success(rows) }
            } catch (e: Exception) {
                runOnUiThread { result.error("nights_failed", e.javaClass.simpleName, null) }
            }
        }.start()
    }

    /** The events of one local day ("yyyy-MM-dd"), as times of day, read off the main thread. */
    private fun calendarEvents(date: String, result: MethodChannel.Result) {
        val reader = CalendarReader(this)
        if (!reader.allowed()) {
            result.success(null)
            return
        }
        Thread {
            try {
                val tz = TimeZone.getDefault()
                val day = java.text.SimpleDateFormat("yyyy-MM-dd", java.util.Locale.ROOT).apply { timeZone = tz }.parse(date)!!.time
                val from = UsageAggregator.startOfDay(day, tz)
                val to = from + 24L * 3600 * 1000
                val fmt = java.text.SimpleDateFormat("HH:mm", java.util.Locale.ROOT).apply { timeZone = tz }
                val rows = reader.events(from, to).map {
                    mapOf(
                        "title" to it.title,
                        "start" to if (it.allDay || it.startMs < from) "00:00" else fmt.format(java.util.Date(it.startMs)),
                        "end" to if (it.allDay || it.endMs >= to) "23:59" else fmt.format(java.util.Date(it.endMs)),
                        "all_day" to it.allDay,
                        "busy" to it.busy,
                    )
                }
                runOnUiThread { result.success(rows) }
            } catch (e: Exception) {
                runOnUiThread { result.error("calendar_failed", e.javaClass.simpleName, null) }
            }
        }.start()
    }

    private fun canExact(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return true
        return (getSystemService(Context.ALARM_SERVICE) as AlarmManager).canScheduleExactAlarms()
    }

    /** A real alarm in the phone's Clock app, without opening it. False if no Clock app takes it. */
    private fun setPhoneAlarm(hour: Int, minute: Int, message: String): Boolean {
        val intent = Intent(android.provider.AlarmClock.ACTION_SET_ALARM)
            .putExtra(android.provider.AlarmClock.EXTRA_HOUR, hour)
            .putExtra(android.provider.AlarmClock.EXTRA_MINUTES, minute)
            .putExtra(android.provider.AlarmClock.EXTRA_MESSAGE, message.take(60))
            .putExtra(android.provider.AlarmClock.EXTRA_SKIP_UI, true)
        if (intent.resolveActivity(packageManager) == null) return false
        return runCatching { startActivity(intent) }.isSuccess
    }

    private fun scheduleAlarm(id: String, atMs: Long, message: String, card: Boolean, title: String?, open: String?): Boolean {
        if (!canExact()) return false
        val code = id.hashCode()
        val intent = Intent(this, AlarmReceiver::class.java).putExtra("message", message).putExtra("card", card).putExtra("title", title).putExtra("open", open).putExtra("id", 3000 + (code and 0xFFF))
        val pending = PendingIntent.getBroadcast(this, code, intent, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        (getSystemService(Context.ALARM_SERVICE) as AlarmManager).setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, atMs, pending)
        return true
    }

    /** Cancels a reminder scheduled earlier (same request code as when it was made). Fine if it already fired. */
    private fun cancelAlarm(id: String) {
        val intent = Intent(this, AlarmReceiver::class.java)
        val pending = PendingIntent.getBroadcast(this, id.hashCode(), intent, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_NO_CREATE) ?: return
        (getSystemService(Context.ALARM_SERVICE) as AlarmManager).cancel(pending)
        pending.cancel()
    }

    /** Saves the limits for the watcher and starts it. Returns the names that are not installed on this phone. */
    private fun applyLimits(limits: Map<String, Number>): List<String> {
        val apps = Apps.launchable(this)
        val resolved = ArrayList<NativeStore.Limit>()
        val missing = ArrayList<String>()
        for ((name, minutes) in limits) {
            val app = AppMatcher.resolve(name, apps)
            if (app == null) missing.add(name) else resolved.add(NativeStore.Limit(app.label, app.pkg, minutes.toInt()))
        }
        NativeStore(this).saveLimits(resolved)
        LimitWatcherService.sync(this)
        return missing
    }

    /** Saves the user's reminder rules for the watcher and starts it. Returns the app names not found on this phone. */
    private fun applyRules(rules: List<Map<String, Any>>): List<String> {
        val apps = Apps.launchable(this)
        val resolved = ArrayList<SessionRule>()
        val missing = ArrayList<String>()
        for (r in rules) {
            val name = r["app"] as? String ?: continue
            val minutes = (r["minutes"] as? Number)?.toInt() ?: continue
            val ask = r["ask"] as? String ?: continue
            if (name.equals("any", ignoreCase = true)) {
                resolved.add(SessionRule("any app", SessionRules.ANY, minutes, ask))
                continue
            }
            val app = AppMatcher.resolve(name, apps)
            if (app == null) missing.add(name) else resolved.add(SessionRule(app.label, app.pkg, minutes, ask))
        }
        NativeStore(this).saveRules(resolved)
        LimitWatcherService.sync(this)
        return missing
    }

    companion object {
        const val EXTRA_OPEN = "open"
        @Volatile private var pendingOpen: String? = null
        const val CHANNEL = "org.ngdev.life_agent/native"
    }
}
