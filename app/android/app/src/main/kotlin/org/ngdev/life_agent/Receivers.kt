package org.ngdev.life_agent

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/** A reminder the agent scheduled for today: shows a notification. */
class AlarmReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val message = intent.getStringExtra("message") ?: return
        val id = intent.getIntExtra("id", 3000)
        // card = the nudge card on top of the app in front (used by the test button); otherwise a normal reminder notification
        if (intent.getBooleanExtra("card", false)) Nudger(context).show(message, id) else Nudger(context).notify(message, id, Nudger.CHANNEL_REMINDER)
    }
}

/** After a restart the watcher has to start again by itself. */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == Intent.ACTION_BOOT_COMPLETED) runCatching { LimitWatcherService.sync(context) }
    }
}
