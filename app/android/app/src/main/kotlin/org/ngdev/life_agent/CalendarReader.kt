package org.ngdev.life_agent

import android.Manifest
import android.content.ContentUris
import android.content.Context
import android.content.pm.PackageManager
import android.provider.CalendarContract
import org.ngdev.life_agent.core.CalEvent

/** Reads the phone's calendar (only with the user's "Calendar" permission), for planning and for tighter limits during events. */
class CalendarReader(context: Context) {
    private val ctx = context.applicationContext

    fun allowed(): Boolean = ctx.checkSelfPermission(Manifest.permission.READ_CALENDAR) == PackageManager.PERMISSION_GRANTED

    /** Every event instance overlapping [fromMs, toMs) (repeating events included), visible calendars only. */
    fun events(fromMs: Long, toMs: Long): List<CalEvent> {
        if (!allowed()) return emptyList()
        val uri = CalendarContract.Instances.CONTENT_URI.buildUpon().also {
            ContentUris.appendId(it, fromMs)
            ContentUris.appendId(it, toMs)
        }.build()
        val cols = arrayOf(
            CalendarContract.Instances.TITLE,
            CalendarContract.Instances.BEGIN,
            CalendarContract.Instances.END,
            CalendarContract.Instances.ALL_DAY,
            CalendarContract.Instances.AVAILABILITY,
            CalendarContract.Instances.VISIBLE,
        )
        val out = ArrayList<CalEvent>()
        ctx.contentResolver.query(uri, cols, null, null, "${CalendarContract.Instances.BEGIN} ASC")?.use { c ->
            while (c.moveToNext() && out.size < 50) {
                if (c.getInt(5) == 0) continue
                out.add(
                    CalEvent(
                        title = (c.getString(0) ?: "").ifBlank { "Busy" }.take(120),
                        startMs = c.getLong(1),
                        endMs = c.getLong(2),
                        allDay = c.getInt(3) == 1,
                        busy = c.getInt(4) != CalendarContract.Events.AVAILABILITY_FREE,
                    ),
                )
            }
        }
        return out
    }
}
