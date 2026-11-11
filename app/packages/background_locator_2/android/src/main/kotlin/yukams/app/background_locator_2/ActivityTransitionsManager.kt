package yukams.app.background_locator_2

import android.annotation.SuppressLint
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.util.Log
import androidx.core.app.ActivityCompat
import com.google.android.gms.location.ActivityRecognition
import com.google.android.gms.location.ActivityTransition
import com.google.android.gms.location.ActivityTransitionRequest
import com.google.android.gms.location.DetectedActivity

/**
 * Registers movement-state transition callbacks with the Play Services
 * activity-recognition pipeline.
 *
 * The pipeline fuses the low-power motion sensors on-device (much of it in the
 * sensor hub) so the app learns "device started/stopped moving" for a
 * negligible battery cost — far cheaper than sampling GPS to discover the same
 * fact. The service uses those signals to swap between two location profiles:
 * an accurate, frequent one while moving and a slow, low-power one while
 * stationary, where liveness is carried by [HeartbeatScheduler] instead of GPS.
 *
 * Requires API 29+ (the transition API and the ACTIVITY_RECOGNITION runtime
 * permission). On older devices or when the permission is missing this is a
 * silent no-op: tracking keeps its single fixed profile.
 */
object ActivityTransitionsManager {
    private var pendingIntent: PendingIntent? = null

    /** Location request interval used while the device is stationary. */
    const val STILL_INTERVAL_MS: Long = 15 * 60 * 1000L

    @SuppressLint("MissingPermission")
    fun start(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return
        val appContext = context.applicationContext
        if (ActivityCompat.checkSelfPermission(
                appContext, android.Manifest.permission.ACTIVITY_RECOGNITION,
            ) != PackageManager.PERMISSION_GRANTED
        ) {
            return
        }
        if (pendingIntent != null) return // already registered

        val transitions = listOf(
            DetectedActivity.IN_VEHICLE,
            DetectedActivity.ON_BICYCLE,
            DetectedActivity.WALKING,
            DetectedActivity.RUNNING,
            DetectedActivity.STILL,
        ).flatMap { activity ->
            listOf(
                ActivityTransition.Builder()
                    .setActivityType(activity)
                    .setActivityTransition(ActivityTransition.ACTIVITY_TRANSITION_ENTER)
                    .build(),
                ActivityTransition.Builder()
                    .setActivityType(activity)
                    .setActivityTransition(ActivityTransition.ACTIVITY_TRANSITION_EXIT)
                    .build(),
            )
        }

        val pi = buildPendingIntent(appContext)

        try {
            ActivityRecognition.getClient(appContext)
                .requestActivityTransitionUpdates(
                    ActivityTransitionRequest(transitions), pi,
                )
                .addOnFailureListener { error ->
                    Log.w("IsolateHolderService", "activity transition registration failed", error)
                    pendingIntent = null
                }
            pendingIntent = pi
        } catch (error: Exception) {
            Log.w("IsolateHolderService", "activity recognition unavailable", error)
        }
    }

    /** The same PendingIntent every time (equal intent and request code), so a
     *  fresh process can still remove a registration made by an earlier one. */
    private fun buildPendingIntent(appContext: Context): PendingIntent {
        val intent = Intent(appContext, ActivityTransitionsReceiver::class.java)
        return PendingIntent.getBroadcast(
            appContext, 0, intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    /** Removes the registration. Works from a fresh process (after the service
     *  died the in-memory reference is gone but Play Services still holds the
     *  registration), which is what lets the watchdog clean up after a stop
     *  that happened while the service was not running. */
    fun stop(context: Context) {
        val appContext = context.applicationContext
        val pi = pendingIntent ?: buildPendingIntent(appContext)
        pendingIntent = null
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return
        try {
            ActivityRecognition.getClient(appContext)
                .removeActivityTransitionUpdates(pi)
        } catch (error: Exception) {
            Log.w("IsolateHolderService", "activity transition deregistration failed", error)
        }
    }
}
