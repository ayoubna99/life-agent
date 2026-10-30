package org.ngdev.life_agent

import android.content.Context
import android.media.AudioAttributes
import android.media.Ringtone
import android.media.RingtoneManager
import android.os.Build
import android.os.Handler
import android.os.Looper

/** The in-app alarm's sound: the phone's alarm tone, until the task screen opens or a minute has passed. */
object AlarmSound {
    private var ringtone: Ringtone? = null
    private val main = Handler(Looper.getMainLooper())

    fun start(context: Context) {
        stop()
        val uri = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM) ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_NOTIFICATION)
        ringtone = RingtoneManager.getRingtone(context.applicationContext, uri)?.apply {
            audioAttributes = AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_ALARM).build()
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) isLooping = true
            play()
        }
        main.postDelayed({ stop() }, 60_000)
    }

    fun stop() {
        main.removeCallbacksAndMessages(null)
        runCatching { ringtone?.stop() }
        ringtone = null
    }
}
