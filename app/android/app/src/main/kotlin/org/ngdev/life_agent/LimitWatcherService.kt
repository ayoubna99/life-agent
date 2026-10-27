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
import org.ngdev.life_agent.core.NudgePolicy
import org.ngdev.life_agent.core.UsageAggregator
import java.util.Calendar
import java.util.TimeZone

/**
 * Watches the apps that have a daily limit. When one is in front and the limit is near, reached or passed, it asks the agent
 * for a short personal message and shows it on top of the app. Runs as a foreground service (Android requires the small
 * "Life is watching your limits" notification) and stops by itself when no app has a limit.
 */
class LimitWatcherService : Service() {
    private lateinit var thread: HandlerThread
    private lateinit var handler: Handler
    private lateinit var store: NativeStore
    private lateinit var reader: UsageReader
    private lateinit var nudger: Nudger
    @Volatile private var running = false

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        store = NativeStore(this)
        reader = UsageReader(this)
        nudger = Nudger(this)
        Nudger.ensureChannels(this)
        thread = HandlerThread("life-watcher", Process.THREAD_PRIORITY_BACKGROUND).also { it.start() }
        handler = Handler(thread.looper)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (store.limits().isEmpty()) {
            stopSelf()
            return START_NOT_STICKY
        }
        val note = Nudger.builder(this, Nudger.CHANNEL_WATCHER)
            .setSmallIcon(applicationInfo.icon)
            .setContentTitle("Life is watching your limits")
            .setContentIntent(Nudger.openAppIntent(this))
            .setOngoing(true)
            .build()
        if (Build.VERSION.SDK_INT >= 34) startForeground(1, note, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE) else startForeground(1, note)
        if (!running) {
            running = true
            handler.post { tick() }
        }
        return START_STICKY
    }

    override fun onDestroy() {
        running = false
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
        }
        if (running) handler.postDelayed({ tick() }, next)
    }

    /** One look at the phone. Returns how long to wait before the next one. */
    private fun check(): Long {
        val limits = store.limits()
        if (limits.isEmpty()) {
            running = false
            stopSelf()
            return 60_000L
        }
        if (!hasUsageAccess(this)) return 60_000L

        val now = System.currentTimeMillis()
        val tz = TimeZone.getDefault()
        val start = UsageAggregator.startOfDay(now, tz)
        val events = reader.events(start, now)
        val front = UsageAggregator.appInFront(events.filter { it.timeMs >= now - UsageAggregator.MAX_SESSION_MS }) ?: return 30_000L
        val limit = limits.firstOrNull { it.pkg == front } ?: return 30_000L

        val day = UsageAggregator.dayKey(now, tz)
        val usedMs = UsageAggregator.perDay(events, now, tz)[day]?.get(front) ?: 0L
        val used = (usedMs / 60_000L).toInt()

        val sent = NudgePolicy.keepOnly(day, store.sent())
        val decision = NudgePolicy.decide(day, front, used, limit.minutes, now, store.lastNudgeAt, sent) ?: return 20_000L

        store.saveSent(sent + (decision.key to decision.value))
        store.lastNudgeAt = now
        val cal = Calendar.getInstance(tz).apply { timeInMillis = now }
        val hhmm = "%02d:%02d".format(cal.get(Calendar.HOUR_OF_DAY), cal.get(Calendar.MINUTE))
        val answer = NudgeClient(store).fetch(day, hhmm, limit.label, used, limit.minutes, decision.reason.wire)
        val text = answer?.text ?: NudgePolicy.fallbackText(decision.reason, limit.label, used, limit.minutes)
        nudger.show(text, 2000 + (front.hashCode() and 0xFFF))
        return 20_000L
    }

    companion object {
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
            if (NativeStore(context).limits().isEmpty()) {
                context.stopService(intent)
            } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }
    }
}
