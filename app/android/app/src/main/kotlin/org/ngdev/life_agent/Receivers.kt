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
        val open = intent.getStringExtra("open")
        if (open != null && open.startsWith("task:")) {
            // an in-app alarm: it rings and Life opens on the task's screen
            Nudger(context).ringTask(intent.getStringExtra("title") ?: message, open, id)
        } else if (intent.getBooleanExtra("card", false)) {
            // Keep Life awake for a few seconds while the card is up: some phones pause an app the moment its receiver ends.
            val done = goAsync()
            val store = NativeStore(context)
            Nudger(context).card(intent.getStringExtra("title") ?: "Lify", message, null, id, open) { how -> store.log("test card shown as $how") }
            android.os.Handler(android.os.Looper.getMainLooper()).postDelayed({ done.finish() }, 8_000)
        } else {
            Nudger(context).notify(message, id, Nudger.CHANNEL_REMINDER, intent.getStringExtra("title") ?: "Life", Nudger.openPending(context, open))
        }
    }
}

/** After a restart the watcher has to start again by itself. */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == Intent.ACTION_BOOT_COMPLETED) {
            runCatching { LimitWatcherService.sync(context) }
            runCatching { EveningReminder.schedule(context) }
        }
    }
}
