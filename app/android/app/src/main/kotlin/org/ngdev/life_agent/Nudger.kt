package org.ngdev.life_agent

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.graphics.PixelFormat
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.view.Gravity
import android.view.View
import android.view.WindowManager
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView

/** Shows what the agent has to say: a card on top of the app you are in, or a notification if that is not allowed. */
class Nudger(context: Context) {
    private val ctx = context.applicationContext
    private val main = Handler(Looper.getMainLooper())

    companion object {
        const val CHANNEL_NUDGE = "nudges"
        const val CHANNEL_REMINDER = "reminders"
        const val CHANNEL_WATCHER = "watcher"
        private var overlay: View? = null

        fun ensureChannels(context: Context) {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
            val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            nm.createNotificationChannel(NotificationChannel(CHANNEL_NUDGE, "Nudges", NotificationManager.IMPORTANCE_HIGH).apply { description = "The agent speaks up when a limit is near" })
            nm.createNotificationChannel(NotificationChannel(CHANNEL_REMINDER, "Reminders", NotificationManager.IMPORTANCE_HIGH).apply { description = "Reminders before your tasks" })
            nm.createNotificationChannel(NotificationChannel(CHANNEL_WATCHER, "Watching your limits", NotificationManager.IMPORTANCE_MIN).apply { description = "Shown while Life watches your app limits" })
        }

        fun builder(context: Context, channel: String): Notification.Builder =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) Notification.Builder(context, channel) else @Suppress("DEPRECATION") Notification.Builder(context)

        fun openAppIntent(context: Context): PendingIntent {
            val launch = context.packageManager.getLaunchIntentForPackage(context.packageName)!!.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            return PendingIntent.getActivity(context, 0, launch, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        }
    }

    fun canOverlay(): Boolean = Build.VERSION.SDK_INT < Build.VERSION_CODES.M || Settings.canDrawOverlays(ctx)

    fun show(text: String, id: Int) {
        if (canOverlay()) main.post { runCatching { showOverlay(text) }.onFailure { notify(text, id, CHANNEL_NUDGE) } } else notify(text, id, CHANNEL_NUDGE)
    }

    fun notify(text: String, id: Int, channel: String) {
        ensureChannels(ctx)
        val n = builder(ctx, channel)
            .setSmallIcon(ctx.applicationInfo.icon)
            .setContentTitle("Life")
            .setContentText(text)
            .setStyle(Notification.BigTextStyle().bigText(text))
            .setContentIntent(openAppIntent(ctx))
            .setAutoCancel(true)
            .apply { if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) @Suppress("DEPRECATION") setPriority(Notification.PRIORITY_HIGH) }
            .build()
        (ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager).notify(id, n)
    }

    private fun dp(v: Int) = (v * ctx.resources.displayMetrics.density).toInt()

    private fun showOverlay(text: String) {
        val wm = ctx.getSystemService(Context.WINDOW_SERVICE) as WindowManager
        overlay?.let { runCatching { wm.removeView(it) } }

        val card = LinearLayout(ctx).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(18), dp(14), dp(18), dp(10))
            background = GradientDrawable().apply { setColor(0xFF1F2A27.toInt()); cornerRadius = dp(18).toFloat() }
            elevation = dp(8).toFloat()
        }
        card.addView(TextView(ctx).apply { this.text = "Life"; setTextColor(0xFF9FD3C4.toInt()); textSize = 12f })
        card.addView(TextView(ctx).apply { this.text = text; setTextColor(0xFFFFFFFF.toInt()); textSize = 16f; setPadding(0, dp(4), 0, dp(8)) })
        val row = LinearLayout(ctx).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.END }
        fun close() { runCatching { wm.removeView(card) }; if (overlay === card) overlay = null }
        row.addView(Button(ctx).apply { this.text = "Dismiss"; setOnClickListener { close() } })
        row.addView(Button(ctx).apply {
            this.text = "Go to my task"
            setOnClickListener {
                close()
                runCatching { openAppIntent(ctx).send() }
            }
        })
        card.addView(row)

        val type = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY else @Suppress("DEPRECATION") WindowManager.LayoutParams.TYPE_PHONE
        val lp = WindowManager.LayoutParams(
            ctx.resources.displayMetrics.widthPixels - dp(24),
            WindowManager.LayoutParams.WRAP_CONTENT,
            type,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL,
            PixelFormat.TRANSLUCENT,
        ).apply { gravity = Gravity.TOP or Gravity.CENTER_HORIZONTAL; y = dp(48) }
        wm.addView(card, lp)
        overlay = card
        main.postDelayed({ close() }, 20_000)
    }
}
