package yukams.app.background_locator_2

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.SystemClock

/**
 * Schedules the liveness alarm.
 *
 * The location stream alone cannot guarantee presence: while the device is
 * stationary the fused provider may deliver nothing for hours, and the OS
 * power manager defers both GPS and network further once the device is idle.
 * This alarm wakes the app every [INTERVAL_MS] so the Dart background isolate
 * can POST a lightweight heartbeat (no location row, no GPS fix) that keeps
 * the family's "last seen" fresh, and so [ServiceWatchdog] can bring a dead
 * tracking service back.
 *
 * It is a CHAIN of one-shot alarms, not a repeating alarm: every firing
 * ([HeartbeatReceiver]) arms the next one before doing anything else, and the
 * alarm is armed by every service start, so it survives the service dying (the
 * receiver is declared in the manifest and runs in a fresh process) and is
 * only removed when the user stops sharing. A repeating inexact alarm was
 * deferred to Doze maintenance windows; [AlarmManager.setAndAllowWhileIdle]
 * is allowed to fire in Doze (Android limits it to about one per nine minutes
 * per app while idle, which suits a 10 minute interval).
 *
 * The alarm is deliberately inexact: a few minutes of drift is harmless for a
 * liveness signal, and inexact alarms avoid the exact-alarm special permission
 * (SCHEDULE_EXACT_ALARM / USE_EXACT_ALARM are restricted on Google Play to
 * alarm-clock and calendar apps; this app is neither, so neither is declared).
 * ELAPSED_REALTIME_WAKEUP is used so the CPU wakes even in deep idle.
 */
object HeartbeatScheduler {
    /** How often the liveness alarm fires. 10 minutes keeps "last seen"
     *  comfortably fresher than any staleness threshold a viewer uses. */
    const val INTERVAL_MS: Long = 10 * 60 * 1000L

    private const val REQUEST_CODE = 4242

    /** Arms the first alarm of the chain (service start). */
    fun schedule(context: Context) = scheduleNext(context)

    /** Arms the next alarm of the chain. Re-arming with the same PendingIntent
     *  replaces the previous registration, so calling this repeatedly never
     *  stacks alarms. Never throws. */
    fun scheduleNext(context: Context) {
        try {
            val appContext = context.applicationContext
            val alarmManager =
                appContext.getSystemService(Context.ALARM_SERVICE) as AlarmManager
            val pendingIntent = pendingIntent(appContext)
            val triggerAt = SystemClock.elapsedRealtime() + INTERVAL_MS
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                alarmManager.setAndAllowWhileIdle(
                    AlarmManager.ELAPSED_REALTIME_WAKEUP,
                    triggerAt,
                    pendingIntent,
                )
            } else {
                alarmManager.set(AlarmManager.ELAPSED_REALTIME_WAKEUP, triggerAt, pendingIntent)
            }
        } catch (e: Throwable) {
            NativeJournal.record(context, "alarm_arm_failed", "type=${e.javaClass.simpleName}")
        }
    }

    fun cancel(context: Context) {
        val appContext = context.applicationContext
        val alarmManager =
            appContext.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        alarmManager.cancel(pendingIntent(appContext))
    }

    private fun pendingIntent(context: Context): PendingIntent {
        val intent = Intent(context, HeartbeatReceiver::class.java)
            .setAction(Keys.ACTION_HEARTBEAT)
        var flags = PendingIntent.FLAG_UPDATE_CURRENT
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            flags = flags or PendingIntent.FLAG_IMMUTABLE
        }
        return PendingIntent.getBroadcast(context, REQUEST_CODE, intent, flags)
    }
}
