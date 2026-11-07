package app.openfamily.wear.ui

import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.State
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.ui.platform.LocalContext

/**
 * Compass heading (degrees from north) while the calling screen is visible and
 * not ambient. The sensor is registered only for that time; null if the watch
 * has no rotation sensor.
 */
@Composable
fun rememberHeading(enabled: Boolean): State<Double?> {
    val ctx = LocalContext.current
    val state = remember { mutableStateOf<Double?>(null) }
    DisposableEffect(enabled) {
        val sm = ctx.getSystemService(SensorManager::class.java)
        val sensor = sm?.getDefaultSensor(Sensor.TYPE_ROTATION_VECTOR)
        val l = object : SensorEventListener {
            private val r = FloatArray(9)
            private val o = FloatArray(3)
            private var last = 0L
            override fun onSensorChanged(e: SensorEvent) {
                if (e.timestamp - last < 200_000_000L) return // 5 updates a second is plenty for an arrow
                last = e.timestamp
                SensorManager.getRotationMatrixFromVector(r, e.values)
                SensorManager.getOrientation(r, o)
                state.value = (Math.toDegrees(o[0].toDouble()) + 360.0) % 360.0
            }
            override fun onAccuracyChanged(s: Sensor?, a: Int) {}
        }
        if (enabled && sensor != null) sm.registerListener(l, sensor, SensorManager.SENSOR_DELAY_UI)
        onDispose { sm?.unregisterListener(l) }
    }
    return state
}
