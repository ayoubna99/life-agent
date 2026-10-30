package org.ngdev.life_agent

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build

/**
 * Some phones stop apps in the background to save battery, the watcher with them, and then nudges only came back when
 * Life was opened again. Every 15 minutes this alarm starts the watcher again if it is gone (an exact alarm is one of
 * the moments Android lets an app start its foreground service from the background).
 */
object Watchdog {
    private const val REQUEST = 4300
    const val EVERY_MS = 15L * 60 * 1000

    private fun pending(context: Context, flags: Int): PendingIntent? =
        PendingIntent.getBroadcast(context, REQUEST, Intent(context, WatchdogReceiver::class.java), PendingIntent.FLAG_IMMUTABLE or flags)

    fun schedule(context: Context) {
        val am = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        val at = System.currentTimeMillis() + EVERY_MS
        val pi = pending(context, PendingIntent.FLAG_UPDATE_CURRENT)!!
        val exact = Build.VERSION.SDK_INT < Build.VERSION_CODES.S || am.canScheduleExactAlarms()
        if (exact) am.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, pi) else am.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, pi)
    }

    fun cancel(context: Context) {
        val am = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        pending(context, PendingIntent.FLAG_NO_CREATE)?.let { am.cancel(it); it.cancel() }
    }
}

class WatchdogReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val store = NativeStore(context)
        if (!LimitWatcherService.alive && LimitWatcherService.hasWork(store)) store.log("watcher was stopped by the phone, started again")
        runCatching { LimitWatcherService.sync(context) }.onFailure {
            store.log("could not restart the watcher (${it.javaClass.simpleName})")
            runCatching { Watchdog.schedule(context) }
        }
    }
}
