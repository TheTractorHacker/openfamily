package yukams.app.background_locator_2

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * Fires on the liveness alarm. It does three things, in this order so that a
 * failure in a later step can never end the chain:
 *
 *  1. Arms the NEXT alarm (the alarm is a chain of one-shot alarms that may
 *     fire in Doze, see [HeartbeatScheduler]); skipped when the user is not
 *     sharing, which also removes the alarm.
 *  2. If tracking is wanted but the foreground service is gone, asks
 *     [ServiceWatchdog] to bring it back (journalled, never throws).
 *  3. Forwards the tick into the Dart background isolate, which POSTs a bare
 *     heartbeat. If the service is not running there is no engine and nothing
 *     is sent: a heartbeat without active tracking would be misleading (the
 *     family map shows position freshness, not bare process liveness).
 */
class HeartbeatReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Keys.ACTION_HEARTBEAT) return
        val wanted = PreferencesManager.isTrackingWanted(context)
        if (wanted) HeartbeatScheduler.scheduleNext(context)
        NativeJournal.record(context, "alarm_fired", "wanted=$wanted")
        val outcome = ServiceWatchdog.onWake(context, "heartbeat")
        if (outcome == ServiceWatchdog.OUTCOME_RUNNING) {
            IsolateHolderService.dispatchHeartbeat(context)
        }
    }
}
