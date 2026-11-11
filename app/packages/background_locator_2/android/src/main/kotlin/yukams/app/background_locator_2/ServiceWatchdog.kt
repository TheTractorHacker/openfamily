package yukams.app.background_locator_2

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.SystemClock

/**
 * Brings the tracking foreground service back when tracking is wanted but the
 * service is not running.
 *
 * Before this, nothing restarted a dead service except START_STICKY, the
 * boot broadcast and the app being opened: the 10 minute alarm found no
 * engine, wrote "heartbeat_dropped" and did nothing else, and an
 * activity-recognition transition on a dead service was a no-op. A phone whose
 * service Android had ended therefore stayed silent until its owner opened the
 * app.
 *
 * What this can and cannot do (Android 12+ forbids starting a foreground
 * service from the background, with documented exceptions):
 *  - It is called only from contexts Android treats as exempt or likely to be
 *    exempt: an activity-recognition transition receiver (documented
 *    exemption), the alarm receiver (exempt when the user has taken the app
 *    off battery optimisation, "Unrestricted"), a time or time-zone change
 *    broadcast, and a push wake-up.
 *  - It never claims success it cannot prove: the start is REQUESTED here; the
 *    service's own "service_created" journal line follows only if Android
 *    really started it. A refusal (ForegroundServiceStartNotAllowedException,
 *    SecurityException, anything else) is caught and journalled as
 *    "watchdog_refused" with the exception TYPE only. It can never crash the
 *    app.
 *  - It does not try at all without "Allow all the time" (background
 *    location): Android 14+ throws from inside the service for a location
 *    foreground service started without it, and that throw cannot be caught
 *    here.
 *  - A force-stopped app (Samsung "sleeping" or "deep sleeping" apps, the
 *    user's own Force stop) receives no broadcast at all until it is opened,
 *    so none of this runs then. Only the user's own settings prevent that.
 *
 * Every outcome is a short code (see the constants) that the push path hands
 * back to Dart.
 */
object ServiceWatchdog {
    const val OUTCOME_NOT_WANTED = "not_wanted"
    const val OUTCOME_RUNNING = "running"
    const val OUTCOME_DEBOUNCED = "debounced"
    const val OUTCOME_RESTARTED = "restarted"
    const val OUTCOME_REFUSED = "refused"

    /** A second request inside this window is dropped: several exempt events
     *  (an alarm and a transition) can arrive together. */
    private const val MIN_SPACING_MS = 30_000L

    @Volatile
    private var lastAttemptAt = 0L

    /**
     * Entry point of every exempt wake-up. [source] is a short code for the
     * journal ("heartbeat", "activity_transition", "time_changed", "push").
     * Never throws. Returns one of the OUTCOME_* codes.
     */
    @JvmStatic
    fun onWake(context: Context?, source: String): String {
        val app = context?.applicationContext ?: return OUTCOME_REFUSED
        try {
            if (!PreferencesManager.isTrackingWanted(app)) {
                // The user switched sharing off while the service was not
                // running, so nothing cancelled the alarm and the motion
                // registration. Do it now; a wake-up must never revive them.
                releaseWhenNotWanted(app, source)
                return OUTCOME_NOT_WANTED
            }
            if (IsolateHolderService.isServiceRunning) return OUTCOME_RUNNING

            val now = SystemClock.elapsedRealtime()
            if (lastAttemptAt != 0L && now - lastAttemptAt in 0 until MIN_SPACING_MS) {
                return OUTCOME_DEBOUNCED
            }
            lastAttemptAt = now

            if (app.checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION)
                != PackageManager.PERMISSION_GRANTED
            ) {
                NativeJournal.record(app, "watchdog_refused", "source=$source reason=no_location_permission")
                return OUTCOME_REFUSED
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q &&
                app.checkSelfPermission(Manifest.permission.ACCESS_BACKGROUND_LOCATION)
                != PackageManager.PERMISSION_GRANTED
            ) {
                NativeJournal.record(app, "watchdog_refused", "source=$source reason=no_background_location")
                return OUTCOME_REFUSED
            }

            BackgroundLocatorPlugin.registerAfterBoot(app)
            NativeJournal.record(app, "service_restarted_by_watchdog", "source=$source")
            return OUTCOME_RESTARTED
        } catch (e: Throwable) {
            // ForegroundServiceStartNotAllowedException (API 31+) and
            // SecurityException land here. The TYPE only: its text can name
            // internals.
            NativeJournal.record(app, "watchdog_refused", "source=$source type=${e.javaClass.simpleName}")
            return OUTCOME_REFUSED
        }
    }

    private fun releaseWhenNotWanted(app: Context, source: String) {
        try {
            HeartbeatScheduler.cancel(app)
            ActivityTransitionsManager.stop(app)
            NativeJournal.record(app, "watchdog_released", "source=$source reason=not_wanted")
        } catch (e: Throwable) {
            // Best effort.
        }
    }
}
