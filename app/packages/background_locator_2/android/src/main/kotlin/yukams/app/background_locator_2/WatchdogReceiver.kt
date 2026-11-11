package yukams.app.background_locator_2

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * Extra, free chances to bring tracking back: Android delivers the system
 * clock and time-zone change broadcasts to manifest receivers, and they happen
 * on their own (travelling across a time zone, the network setting the clock).
 * Each one asks [ServiceWatchdog] to restart the tracking service when it is
 * wanted but gone, and to re-arm the liveness alarm.
 *
 * Whether Android treats these two broadcasts as exempt from the background
 * foreground-service start limits is NOT verified here; a refusal is caught
 * and journalled by the watchdog.
 *
 * LOCKED_BOOT_COMPLETED is deliberately not used: it is delivered before the
 * first unlock, when the credential-protected preferences this app stores its
 * settings in cannot be read.
 */
class WatchdogReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val source = when (intent.action) {
            Intent.ACTION_TIME_CHANGED -> "time_changed"
            Intent.ACTION_TIMEZONE_CHANGED -> "timezone_changed"
            else -> return
        }
        if (PreferencesManager.isTrackingWanted(context)) HeartbeatScheduler.scheduleNext(context)
        ServiceWatchdog.onWake(context, source)
    }
}
