package app.openfamily.wear.ui

import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.Stable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.withFrameNanos
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalView
import androidx.lifecycle.compose.LifecycleResumeEffect
import app.openfamily.wear.data.Declination
import app.openfamily.wear.logic.AccuracyGate
import app.openfamily.wear.logic.ArrowEngine
import app.openfamily.wear.logic.CompassMath
import app.openfamily.wear.logic.Presenter
import app.openfamily.wear.logic.TiltTracker
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.withContext

/**
 * What the Direction screen shows. [arrowDeg] and [northDeg] change every display frame while the wrist moves and
 * are read only in a draw lambda, so a frame redraws the arrow and recomposes nothing. The other fields change
 * rarely (sensor found, calibration hint, true or magnetic north) and may be read while composing.
 */
@Stable
class CompassState {
    internal val engine = ArrowEngine()

    /** Arrow rotation in degrees clockwise from the top of the watch. Read in draw only. */
    val arrowDeg = mutableFloatStateOf(0f)

    /** Where north is on the dial. Read in draw only. */
    val northDeg = mutableFloatStateOf(0f)

    /** The watch has a rotation sensor. */
    var hasSensor by mutableStateOf(true)
        internal set

    /** At least one compass reading has arrived (until then the arrow points with north at the top). */
    var hasReading by mutableStateOf(false)
        internal set

    /** The compass is poorly calibrated: show the figure-8 hint and dim the arrow. */
    var needsCalibration by mutableStateOf(false)
        internal set

    /** The declination could not be worked out: the arrow points from magnetic north. */
    var approxNorth by mutableStateOf(false)
        internal set

    internal val wake = Channel<Unit>(Channel.CONFLATED)
    internal var declination = 0.0

    internal fun publish() {
        arrowDeg.floatValue = engine.arrowDeg.toFloat()
        northDeg.floatValue = engine.northDeg.toFloat()
    }

    /**
     * The frame loop: asleep until something changes, then one step per display frame until the arrow has settled.
     * A new run starts from a 1/60 s step so a long pause never lurches, and the arrow keeps its last angle.
     */
    internal suspend fun runFrames() {
        for (ignored in wake) {
            var prev = 0L
            while (!engine.settled) {
                withFrameNanos { t ->
                    val dt = if (prev == 0L) ArrowEngine.FIRST_FRAME_DT_S else (t - prev) / 1e9
                    prev = t
                    engine.step(dt)
                    publish()
                }
            }
            publish()
        }
    }
}

/**
 * Compass state for the Direction screen, with the arrow aimed at [bearingDeg] (true bearing to the person, null
 * if there is nothing to point at yet).
 *
 * The rotation-vector sensor (gyro, accelerometer and magnetometer fused) is registered at game rate (about
 * 50 Hz, no batching) only while the screen is RESUMED, [enabled] (not ambient) and there is something to point
 * at, and is unregistered as soon as any of that stops (a pause at once; ambient mode within a frame, because the
 * ambient state change has to be recomposed to draw the ambient screen anyway). The listener does a little arithmetic and wakes the frame
 * loop; the loop eases the arrow every display frame and goes to sleep when it has settled, so a still wrist
 * costs no frames. North is true north: the declination at [here] is added to the magnetic reading, and if it
 * cannot be had the arrow uses magnetic north and [CompassState.approxNorth] says so.
 */
@Composable
fun rememberCompass(enabled: Boolean, bearingDeg: Double?, here: Presenter.Here?): CompassState {
    val ctx = LocalContext.current
    val view = LocalView.current
    val state = remember { CompassState() }
    val active = enabled && bearingDeg != null

    // True-north correction. Works on a background thread; GeomagneticField is cheap but not free.
    LaunchedEffect(here) {
        if (here == null) return@LaunchedEffect
        val d = withContext(Dispatchers.Default) { Declination.at(here.lat, here.lon) }
        state.declination = d?.toDouble() ?: 0.0
        state.approxNorth = d == null
    }

    // The target bearing eases to a new value; the first one is taken as is.
    LaunchedEffect(bearingDeg) {
        if (bearingDeg != null && state.engine.onBearing(bearingDeg)) {
            state.publish()
            state.wake.trySend(Unit)
        }
    }

    // The frame loop exists only while active; leaving it (ambient, screen off) stops all frame work.
    LaunchedEffect(active) {
        if (!active) return@LaunchedEffect
        state.wake.trySend(Unit) // settle on whatever changed while it was off
        state.runFrames()
    }

    LifecycleResumeEffect(active) {
        val sm = ctx.getSystemService(SensorManager::class.java)
        val sensor = sm?.getDefaultSensor(Sensor.TYPE_ROTATION_VECTOR)
        state.hasSensor = sensor != null
        val l = object : SensorEventListener {
            private val tilt = TiltTracker()
            private val gate = AccuracyGate()
            private var rotationReadAtMs = -1L

            override fun onSensorChanged(e: SensorEvent) {
                val v = e.values
                if (v.size < 3) return
                val nowMs = e.timestamp / 1_000_000L
                // The sensor frame is the watch's own; Wear OS turns the display 180 degrees for the other-wrist
                // setting. Looked up twice a second, not 50 times.
                if (rotationReadAtMs < 0 || nowMs - rotationReadAtMs >= ROTATION_REFRESH_MS || nowMs < rotationReadAtMs) {
                    rotationReadAtMs = nowMs
                    tilt.rotation = view.display?.rotation ?: 0
                }
                // The event's own accuracy is always current; onAccuracyChanged may not fire for a fresh registration.
                val poor = CompassMath.isPoor(e.accuracy, if (v.size >= 5) v[4] else null)
                val show = gate.update(nowMs, poor)
                if (show != state.needsCalibration) state.needsCalibration = show
                val magnetic = tilt.azimuth(v) ?: return // pointing straight up or down: keep the last heading
                val heading = CompassMath.trueHeading(magnetic, state.declination)
                if (!state.hasReading) state.hasReading = true
                if (state.engine.onHeading(heading)) state.wake.trySend(Unit)
            }

            override fun onAccuracyChanged(s: Sensor?, a: Int) = Unit // each event carries its accuracy
        }
        // Game rate, and no batching (maxReportLatency 0) so no reading waits in the sensor FIFO.
        if (active && sm != null && sensor != null) {
            sm.registerListener(l, sensor, SensorManager.SENSOR_DELAY_GAME, 0)
        }
        onPauseOrDispose {
            sm?.unregisterListener(l)
            state.needsCalibration = false
        }
    }
    return state
}

private const val ROTATION_REFRESH_MS = 500L
