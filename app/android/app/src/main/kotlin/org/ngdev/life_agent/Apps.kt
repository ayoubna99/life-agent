package org.ngdev.life_agent

import android.content.Context
import android.content.Intent
import org.ngdev.life_agent.core.InstalledApp
import org.ngdev.life_agent.core.UsageEvent
import org.ngdev.life_agent.core.UsageEventType
import android.app.usage.UsageEvents
import android.app.usage.UsageStatsManager

object Apps {
    /** The apps a person can open from the launcher, with the name they see under the icon (never this app). */
    fun launchable(context: Context): List<InstalledApp> {
        val pm = context.packageManager
        val intent = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
        @Suppress("DEPRECATION")
        return pm.queryIntentActivities(intent, 0)
            .map { InstalledApp(it.loadLabel(pm).toString(), it.activityInfo.packageName) }
            .filter { it.pkg != context.packageName }
            .distinctBy { it.pkg }
            .sortedBy { it.label.lowercase() }
    }
}

/** Reads Android's usage events and hands them to the plain-Kotlin code. */
class UsageReader(context: Context) {
    private val usm = context.getSystemService(Context.USAGE_STATS_SERVICE) as UsageStatsManager

    fun events(fromMs: Long, toMs: Long): List<UsageEvent> {
        val out = ArrayList<UsageEvent>()
        val events = usm.queryEvents(fromMs, toMs) ?: return out
        val e = UsageEvents.Event()
        while (events.hasNextEvent()) {
            events.getNextEvent(e)
            // 1 = an activity came to the front (ACTIVITY_RESUMED / MOVE_TO_FOREGROUND), 2 = it went to the back.
            // 18 = KEYGUARD_HIDDEN (unlocked), 16 = SCREEN_NON_INTERACTIVE and 17 = KEYGUARD_SHOWN (locked again).
            val type = when (e.eventType) {
                1 -> UsageEventType.FOREGROUND
                2 -> UsageEventType.BACKGROUND
                18 -> UsageEventType.UNLOCK
                16, 17 -> UsageEventType.LOCK
                else -> UsageEventType.OTHER
            }
            if (type != UsageEventType.OTHER) out.add(UsageEvent(e.timeStamp, e.packageName, type))
        }
        return out
    }
}
