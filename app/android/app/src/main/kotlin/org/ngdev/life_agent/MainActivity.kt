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
import org.ngdev.life_agent.core.UsageAggregator
import java.util.TimeZone

/** The bridge for everything only Android can do. The Dart side is lib/platform/native.dart. */
class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
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
            "scheduleAlarm" -> result.success(scheduleAlarm(call.argument<String>("id")!!, call.argument<Number>("at")!!.toLong(), call.argument<String>("message")!!))
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
            "canDrawOverlay" -> result.success(Nudger(this).canOverlay())
            "openOverlaySettings" -> {
                startActivity(Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION, Uri.parse("package:$packageName")).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

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

    private fun canExact(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return true
        return (getSystemService(Context.ALARM_SERVICE) as AlarmManager).canScheduleExactAlarms()
    }

    private fun scheduleAlarm(id: String, atMs: Long, message: String): Boolean {
        if (!canExact()) return false
        val code = id.hashCode()
        val intent = Intent(this, AlarmReceiver::class.java).putExtra("message", message).putExtra("id", 3000 + (code and 0xFFF))
        val pending = PendingIntent.getBroadcast(this, code, intent, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        (getSystemService(Context.ALARM_SERVICE) as AlarmManager).setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, atMs, pending)
        return true
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

    companion object {
        const val CHANNEL = "org.ngdev.life_agent/native"
    }
}
