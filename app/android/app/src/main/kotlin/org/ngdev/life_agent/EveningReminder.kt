package org.ngdev.life_agent

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import org.ngdev.life_agent.core.EveningTime
import org.ngdev.life_agent.core.LogicalDay
import org.ngdev.life_agent.core.PhoneNights
import java.util.TimeZone

/**
 * One hour before the user's sleep time, a notification: "Hey Jake, let's make our plans for tomorrow", written by the agent from their
 * day. Nothing is shown if tomorrow is already planned or the agent cannot be reached. Rings every evening.
 */
object EveningReminder {
    private const val REQUEST = 4100

    private fun pending(context: Context, flags: Int): PendingIntent? =
        PendingIntent.getBroadcast(context, REQUEST, Intent(context, EveningReceiver::class.java), PendingIntent.FLAG_IMMUTABLE or flags)

    /** Sets the next evening reminder from the saved sleep time (or cancels it when there is none). */
    fun schedule(context: Context) {
        val am = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        val sleep = NativeStore(context).eveningSleep
        if (sleep == null) {
            pending(context, PendingIntent.FLAG_NO_CREATE)?.let { am.cancel(it); it.cancel() }
            return
        }
        val at = EveningTime.next(System.currentTimeMillis(), sleep, TimeZone.getDefault())
        val pi = pending(context, PendingIntent.FLAG_UPDATE_CURRENT)!!
        val exact = Build.VERSION.SDK_INT < Build.VERSION_CODES.S || am.canScheduleExactAlarms()
        if (exact) am.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, pi) else am.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, pi)
    }
}

class EveningReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val app = context.applicationContext
        val done = goAsync()
        Thread {
            try {
                val now = System.currentTimeMillis()
                val tz = TimeZone.getDefault()
                val store = NativeStore(app)
                val text = NudgeClient(store).evening(LogicalDay.today(now, tz), LogicalDay.tomorrow(now, tz), PhoneNights.hhmm(now, tz))
                // a notification (not a card): tapping it opens "Plan tomorrow"
                if (text != null) Nudger(app).notify(text, 4200, Nudger.CHANNEL_REMINDER, "Lify", Nudger.openPlanIntent(app))
            } catch (e: Exception) {
                // nothing shown tonight; tomorrow's reminder is still set below
            } finally {
                runCatching { EveningReminder.schedule(app) }
                done.finish()
            }
        }.start()
    }
}
