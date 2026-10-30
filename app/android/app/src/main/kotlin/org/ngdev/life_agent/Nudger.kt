package org.ngdev.life_agent

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.animation.ValueAnimator
import android.graphics.Outline
import android.graphics.PixelFormat
import android.graphics.Typeface
import android.graphics.drawable.ClipDrawable
import android.graphics.drawable.GradientDrawable
import android.graphics.drawable.LayerDrawable
import android.view.MotionEvent
import android.view.ViewOutlineProvider
import android.view.animation.DecelerateInterpolator
import android.view.animation.LinearInterpolator
import android.widget.ImageView
import android.widget.ProgressBar
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.view.Gravity
import android.view.View
import android.view.WindowManager
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

        /** How long a card may take to appear before it is sent as a notification instead. */
        const val DRAW_WAIT_MS = 1_500L

        /** The small white sunrise for the status bar (falls back to the app icon if it is missing). */
        fun smallIcon(context: Context): Int =
            context.resources.getIdentifier("ic_stat_life", "drawable", context.packageName).takeIf { it != 0 } ?: context.applicationInfo.icon

        fun ensureChannels(context: Context) {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
            val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            nm.createNotificationChannel(NotificationChannel(CHANNEL_NUDGE, "Nudges", NotificationManager.IMPORTANCE_HIGH).apply { description = "The agent speaks up when a limit is near" })
            nm.createNotificationChannel(NotificationChannel(CHANNEL_REMINDER, "Reminders", NotificationManager.IMPORTANCE_HIGH).apply { description = "Reminders before your tasks" })
            nm.createNotificationChannel(NotificationChannel(CHANNEL_WATCHER, "Life running", NotificationManager.IMPORTANCE_MIN).apply { description = "Android needs this while Life is on. You can turn this category off."; setShowBadge(false) })
        }

        fun builder(context: Context, channel: String): Notification.Builder =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) Notification.Builder(context, channel) else @Suppress("DEPRECATION") Notification.Builder(context)

        /** Opens the app on a screen: "plan" (the evening reminder) or "task:<id>" (a task's own screen). */
        fun openIntent(context: Context, open: String): Intent =
            context.packageManager.getLaunchIntentForPackage(context.packageName)!!
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
                .putExtra(MainActivity.EXTRA_OPEN, open)

        fun openPending(context: Context, open: String?): PendingIntent =
            if (open == null) openAppIntent(context)
            else PendingIntent.getActivity(context, open.hashCode(), openIntent(context, open), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)

        fun openPlanIntent(context: Context): PendingIntent = openPending(context, "plan")

        fun openAppIntent(context: Context): PendingIntent {
            val launch = context.packageManager.getLaunchIntentForPackage(context.packageName)!!.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            return PendingIntent.getActivity(context, 0, launch, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        }
    }

    fun canOverlay(): Boolean = Build.VERSION.SDK_INT < Build.VERSION_CODES.M || Settings.canDrawOverlays(ctx)

    /**
     * Xiaomi, Redmi and POCO have their own switch, "Display pop-up windows while running in the background" (app op
     * 10021). When it is off the card is drawn but kept hidden until Life is opened again, so it must go as a notification.
     * Other phones: false.
     */
    fun popupBlocked(): Boolean {
        if (Build.MANUFACTURER.lowercase() !in setOf("xiaomi", "redmi", "poco")) return false
        return runCatching {
            val ops = ctx.getSystemService(Context.APP_OPS_SERVICE) as android.app.AppOpsManager
            val m = ops.javaClass.getMethod("checkOpNoThrow", Int::class.javaPrimitiveType, Int::class.javaPrimitiveType, String::class.java)
            m.invoke(ops, 10021, android.os.Process.myUid(), ctx.packageName) as Int != android.app.AppOpsManager.MODE_ALLOWED
        }.getOrDefault(false)
    }

    /** A card is possible: allowed over other apps, not held back by the phone, and the user did not choose notifications. */
    fun cardsWork(): Boolean = canOverlay() && !popupBlocked() && !NativeStore(ctx).nudgesAsNotifications

    /** The test button's card (no app behind it): same look, Life's icon. */
    fun show(text: String, id: Int) = card("Lify", text, null, id)

    /**
     * A nudge: a dark card that slides in at the top of the app you are in, with that app's icon, a bold line saying what
     * happened ([title], from the phone's numbers) and the agent's personal words ([text]). A thin bar counts down and the
     * card leaves by itself; tap it to open Life, swipe it up to dismiss. Without the overlay permission, or when the
     * phone does not draw it within [DRAW_WAIT_MS] (some phones hold back windows from apps in the background), it
     * becomes a heads-up notification instead, so the words always arrive. [done] hears "card" or "notification".
     */
    fun card(title: String, text: String, appPkg: String?, id: Int, open: String? = null, pull: String? = null, done: ((String) -> Unit)? = null) {
        val fallback = {
            notify(text, id, CHANNEL_NUDGE, title, openPending(ctx, open), pull)
            done?.invoke("notification")
        }
        if (!cardsWork()) {
            fallback()
            return
        }
        main.post {
            val view = runCatching { showCard(title, text, appPkg, open, pull) }.getOrNull()
            if (view == null) {
                fallback()
                return@post
            }
            var drawn = false
            val listener = android.view.ViewTreeObserver.OnDrawListener { drawn = true }
            runCatching { view.viewTreeObserver.addOnDrawListener(listener) }
            main.postDelayed({
                runCatching { view.viewTreeObserver.removeOnDrawListener(listener) }
                if (drawn && view.isShown) {
                    done?.invoke("card")
                } else {
                    val wm = ctx.getSystemService(Context.WINDOW_SERVICE) as WindowManager
                    runCatching { wm.removeView(view) }
                    if (overlay === view) overlay = null
                    fallback()
                }
            }, DRAW_WAIT_MS)
        }
    }

    /**
     * An in-app alarm: it rings (the phone's alarm sound, up to a minute) and Life opens on the task's screen. Apps allowed
     * to show over other apps may open a screen from the background; without that permission, a notification opens it.
     */
    fun ringTask(title: String, open: String, id: Int) {
        AlarmSound.start(ctx)
        if (canOverlay()) {
            val started = runCatching { ctx.startActivity(openIntent(ctx, open)) }.isSuccess
            if (started) return
        }
        notify("It's time: $title", id, CHANNEL_REMINDER, "Lify", openPending(ctx, open))
    }

    /** [pull]: adds the "Pull me out" button (it opens Life, which counts as leaving the app, and records the tap). */
    fun notify(text: String, id: Int, channel: String, title: String = "Life", open: PendingIntent? = null, pull: String? = null) {
        ensureChannels(ctx)
        val n = builder(ctx, channel)
            .setSmallIcon(smallIcon(ctx))
            .setContentTitle(title)
            .setContentText(text)
            .setStyle(Notification.BigTextStyle().bigText(text))
            .setContentIntent(open ?: openAppIntent(ctx))
            .setAutoCancel(true)
            .apply { if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) @Suppress("DEPRECATION") setPriority(Notification.PRIORITY_HIGH) }
            .apply {
                if (pull != null) {
                    @Suppress("DEPRECATION")
                    addAction(Notification.Action.Builder(0, "Pull me out", openPending(ctx, "pull:$pull")).build())
                }
            }
            .build()
        (ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager).notify(id, n)
    }

    private fun dp(v: Int) = (v * ctx.resources.displayMetrics.density).toInt()

    private fun showCard(title: String, text: String, appPkg: String?, open: String?, pull: String?): View {
        val wm = ctx.getSystemService(Context.WINDOW_SERVICE) as WindowManager
        overlay?.let { runCatching { wm.removeView(it) } }

        val card = LinearLayout(ctx).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(16), dp(16), dp(18), dp(16))
            background = GradientDrawable().apply {
                setColor(0xF52B2240.toInt())
                cornerRadius = dp(26).toFloat()
                setStroke(dp(1), 0xFF3F355A.toInt())
            }
            elevation = dp(10).toFloat()
        }
        val icon = ImageView(ctx).apply {
            val drawable = appPkg?.let { runCatching { ctx.packageManager.getApplicationIcon(it) }.getOrNull() } ?: ctx.applicationInfo.loadIcon(ctx.packageManager)
            setImageDrawable(drawable)
            scaleType = ImageView.ScaleType.CENTER_CROP
            outlineProvider = object : ViewOutlineProvider() {
                override fun getOutline(view: View, outline: Outline) = outline.setRoundRect(0, 0, view.width, view.height, dp(14).toFloat())
            }
            clipToOutline = true
        }
        card.addView(icon, LinearLayout.LayoutParams(dp(52), dp(52)).apply { marginEnd = dp(14) })

        val words = LinearLayout(ctx).apply { orientation = LinearLayout.VERTICAL }
        words.addView(TextView(ctx).apply {
            this.text = title
            setTextColor(0xFFFFFFFF.toInt())
            textSize = 17f
            typeface = Typeface.create("sans-serif-medium", Typeface.BOLD)
            maxLines = 1
        })
        words.addView(TextView(ctx).apply {
            this.text = text
            setTextColor(0xFFDCD5E8.toInt())
            textSize = 15f
            setLineSpacing(0f, 1.1f)
            setPadding(0, dp(3), 0, dp(10))
        })
        // the countdown: a thin rounded bar that empties while the card is up
        val track = GradientDrawable().apply { setColor(0x33FFFFFF); cornerRadius = dp(3).toFloat() }
        val fill = ClipDrawable(GradientDrawable().apply { setColor(0xAAFFFFFF.toInt()); cornerRadius = dp(3).toFloat() }, Gravity.START, ClipDrawable.HORIZONTAL)
        val bar = ProgressBar(ctx, null, android.R.attr.progressBarStyleHorizontal).apply {
            max = 1000
            progress = 1000
            progressDrawable = LayerDrawable(arrayOf(track, fill)).apply {
                setId(0, android.R.id.background)
                setId(1, android.R.id.progress)
            }
        }
        words.addView(bar, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, dp(5)))
        // "Pull me out": one tap leaves the app (Life opens on what matters next); the tap is part of the measurement
        var pullButton: TextView? = null
        if (pull != null) {
            pullButton = TextView(ctx).apply {
                this.text = "Pull me out"
                setTextColor(0xFF1B1530.toInt())
                textSize = 14f
                typeface = Typeface.create("sans-serif-medium", Typeface.BOLD)
                setPadding(dp(16), dp(8), dp(16), dp(8))
                background = GradientDrawable().apply { setColor(0xFFFF8A65.toInt()); cornerRadius = dp(18).toFloat() }
            }
            words.addView(pullButton, LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply { topMargin = dp(10) })
        }
        card.addView(words, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))

        val type = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY else @Suppress("DEPRECATION") WindowManager.LayoutParams.TYPE_PHONE
        val lp = WindowManager.LayoutParams(
            ctx.resources.displayMetrics.widthPixels - dp(24),
            WindowManager.LayoutParams.WRAP_CONTENT,
            type,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL,
            PixelFormat.TRANSLUCENT,
        ).apply {
            gravity = Gravity.TOP or Gravity.CENTER_HORIZONTAL
            y = dp(44)
            // the system runs this animation, not Life: the card appears even if the phone pauses Life right after
            windowAnimations = android.R.style.Animation_Toast
        }

        var closed = false
        val countdown = ValueAnimator.ofInt(1000, 0).apply {
            duration = if (pull != null) 15_000 else 12_000
            interpolator = LinearInterpolator()
            addUpdateListener { bar.progress = it.animatedValue as Int }
        }
        fun close(up: Boolean = true) {
            if (closed) return
            closed = true
            countdown.cancel()
            card.animate().translationY(if (up) -card.height.toFloat() - dp(60) else 0f).alpha(0f).setDuration(220)
                .withEndAction { runCatching { wm.removeView(card) }; if (overlay === card) overlay = null }.start()
        }
        pullButton?.setOnClickListener {
            close()
            runCatching { openPending(ctx, "pull:$pull").send() }
        }
        countdown.addListener(object : android.animation.AnimatorListenerAdapter() {
            override fun onAnimationEnd(animation: android.animation.Animator) = close()
        })

        var downY = 0f
        card.setOnTouchListener { v, e ->
            when (e.actionMasked) {
                MotionEvent.ACTION_DOWN -> { downY = e.rawY; true }
                MotionEvent.ACTION_MOVE -> { v.translationY = minOf(0f, e.rawY - downY); true }
                MotionEvent.ACTION_UP -> {
                    if (e.rawY - downY < -dp(30)) close() // swiped up
                    else if (Math.abs(e.rawY - downY) < dp(8)) { close(); runCatching { openPending(ctx, open).send() } } // tapped
                    else v.animate().translationY(0f).setDuration(150).start()
                    true
                }
                else -> false
            }
        }

        wm.addView(card, lp)
        overlay = card
        // Visible from its first frame (it used to fade in from invisible: on a phone that pauses apps in the background,
        // Samsung with battery "Restricted" for one, it stayed invisible until Life was opened again).
        countdown.start()
        return card
    }
}
