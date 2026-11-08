package app.openfamily.wear.ui

import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import androidx.compose.runtime.Composable
import androidx.compose.runtime.State
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.ui.platform.LocalContext
import androidx.lifecycle.compose.LifecycleResumeEffect
import app.openfamily.wear.logic.HeadingFilter

/**
 * Compass heading (degrees from north). The rotation sensor is registered only
 * while this screen is composed, the app is RESUMED (so not with the screen off
 * or the watch face in front) and [enabled] (not ambient), at 5 Hz, and is
 * unregistered the moment any of that stops. A low-pass filter with a small
 * dead band keeps the value still when the watch is held steady, so the arrow
 * redraws only when it really turns. Null if the watch has no rotation sensor.
 */
@Composable
fun rememberHeading(enabled: Boolean): State<Double?> {
    val ctx = LocalContext.current
    val state = remember { mutableStateOf<Double?>(null) }
    LifecycleResumeEffect(enabled) {
        val sm = ctx.getSystemService(SensorManager::class.java)
        val sensor = sm?.getDefaultSensor(Sensor.TYPE_ROTATION_VECTOR)
        val l = object : SensorEventListener {
            private val r = FloatArray(9)
            private val o = FloatArray(3)
            private var last = 0L
            override fun onSensorChanged(e: SensorEvent) {
                if (e.timestamp - last < MIN_GAP_NS) return
                last = e.timestamp
                SensorManager.getRotationMatrixFromVector(r, e.values)
                SensorManager.getOrientation(r, o)
                val raw = (Math.toDegrees(o[0].toDouble()) + 360.0) % 360.0
                val next = HeadingFilter.next(state.value, raw)
                if (next != state.value) state.value = next
            }
            override fun onAccuracyChanged(s: Sensor?, a: Int) {}
        }
        if (enabled && sm != null && sensor != null) sm.registerListener(l, sensor, SAMPLING_US)
        onPauseOrDispose { sm?.unregisterListener(l) }
    }
    return state
}

private const val SAMPLING_US = 200_000 // 5 Hz
private const val MIN_GAP_NS = 180_000_000L
