package yukams.app.background_locator_2

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

/**
 * Restarts background tracking after a reboot AND after the app is updated:
 * Android stops the foreground service when the package is replaced, and
 * before this nothing restarted it until the user opened the map again, so a
 * phone sent no position from the update until the next app open.
 *
 * Only for a user who is sharing ([PreferencesManager.isTrackingWanted]).
 * Both broadcasts are exempt from the background foreground-service start
 * limits; a refusal is caught so the receiver can never crash the app.
 */
class BootBroadcastReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.action
        if (action != Intent.ACTION_BOOT_COMPLETED &&
            action != Intent.ACTION_MY_PACKAGE_REPLACED
        ) return
        if (!PreferencesManager.isTrackingWanted(context)) return
        try {
            BackgroundLocatorPlugin.registerAfterBoot(context)
        } catch (e: Exception) {
            Log.w("BootBroadcastReceiver", "could not restart tracking after $action", e)
        }
    }
}
