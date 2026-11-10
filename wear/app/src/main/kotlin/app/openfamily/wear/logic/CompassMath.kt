package app.openfamily.wear.logic

import kotlin.math.abs
import kotlin.math.atan2
import kotlin.math.sqrt

/**
 * Pure maths for the compass, kept out of the sensor code so it runs in plain unit tests (the framework's
 * SensorManager helpers return zeros under test). Nothing here touches location or leaves the watch.
 */
object CompassMath {
    /**
     * Rotation matrix (row-major, 9 entries) from a rotation-vector sensor reading, the same as
     * SensorManager.getRotationMatrixFromVector: world (east, north, up) = R * device (x, y, z).
     * [values] is x, y, z and optionally w (then maybe the accuracy estimate).
     */
    fun rotationMatrix(values: FloatArray, out: DoubleArray) {
        val q1 = values[0].toDouble()
        val q2 = values[1].toDouble()
        val q3 = values[2].toDouble()
        val q0 = if (values.size >= 4) values[3].toDouble() else sqrt(maxOf(0.0, 1.0 - q1 * q1 - q2 * q2 - q3 * q3))
        val sq1 = 2 * q1 * q1
        val sq2 = 2 * q2 * q2
        val sq3 = 2 * q3 * q3
        val q1q2 = 2 * q1 * q2
        val q3q0 = 2 * q3 * q0
        val q1q3 = 2 * q1 * q3
        val q2q0 = 2 * q2 * q0
        val q2q3 = 2 * q2 * q3
        val q1q0 = 2 * q1 * q0
        out[0] = 1 - sq2 - sq3
        out[1] = q1q2 - q3q0
        out[2] = q1q3 + q2q0
        out[3] = q1q2 + q3q0
        out[4] = 1 - sq1 - sq3
        out[5] = q2q3 - q1q0
        out[6] = q1q3 - q2q0
        out[7] = q2q3 + q1q0
        out[8] = 1 - sq1 - sq2
    }

    /** Which device axis is read as "where the watch points". */
    enum class Axis {
        /** The 12 o'clock axis: right while the wrist is level or tilted up to about 60 degrees. */
        Top,

        /** Out of the back of the watch (like a phone camera): right when the screen is held upright. */
        Back,
    }

    /**
     * Compass azimuth (0..360 clockwise from magnetic north) of [axis], or null when that axis points almost
     * straight up or down and has no direction to speak of.
     */
    fun azimuthDeg(r: DoubleArray, axis: Axis): Double? {
        val east: Double
        val north: Double
        if (axis == Axis.Top) {
            east = r[1]; north = r[4]
        } else {
            east = -r[2]; north = -r[5]
        }
        if (east * east + north * north < MIN_HORIZONTAL * MIN_HORIZONTAL) return null
        return (Math.toDegrees(atan2(east, north)) + 360.0) % 360.0
    }

    /** Vertical part of the 12 o'clock axis: 0 level, 1 straight up, -1 straight down. */
    fun topUp(r: DoubleArray): Double = r[7]

    /** Below this horizontal length an axis has no usable direction. */
    const val MIN_HORIZONTAL = 0.2

    /** Switch to [Axis.Back] when the 12 o'clock axis is more than about 60 degrees up or down. */
    const val SWITCH_TO_BACK = 0.87

    /** Switch back to [Axis.Top] below about 48 degrees; the gap between the two is the hysteresis. */
    const val SWITCH_TO_TOP = 0.74

    /** True north from a magnetic azimuth and the local declination (east is positive). */
    fun trueHeading(magneticDeg: Double, declinationDeg: Double): Double =
        (((magneticDeg + declinationDeg) % 360.0) + 360.0) % 360.0

    /** Estimated heading error (radians) above which the compass is treated as needing calibration. */
    const val POOR_ESTIMATE_RAD = 0.35

    /**
     * True when the compass should not be trusted: the sensor says accuracy is unreliable (0) or low (1),
     * or its heading error estimate ([estimateRad], values[4] of a rotation-vector event; negative or null when
     * absent) is large.
     */
    fun isPoor(accuracy: Int, estimateRad: Float?): Boolean =
        accuracy <= 1 || (estimateRad != null && estimateRad >= 0f && estimateRad > POOR_ESTIMATE_RAD)
}

/** Picks the axis for each reading with hysteresis, so holding the wrist near the switch angle does not flicker. */
class TiltTracker {
    var axis = CompassMath.Axis.Top
        private set

    private val r = DoubleArray(9)

    /** True-or-magnetic azimuth for the reading in [values], or null (hold the last one) if it has no direction. */
    fun azimuth(values: FloatArray): Double? {
        CompassMath.rotationMatrix(values, r)
        return azimuthOf(r)
    }

    fun azimuthOf(r: DoubleArray): Double? {
        val up = abs(CompassMath.topUp(r))
        axis = when (axis) {
            CompassMath.Axis.Top -> if (up > CompassMath.SWITCH_TO_BACK) CompassMath.Axis.Back else CompassMath.Axis.Top
            CompassMath.Axis.Back -> if (up < CompassMath.SWITCH_TO_TOP) CompassMath.Axis.Top else CompassMath.Axis.Back
        }
        return CompassMath.azimuthDeg(r, axis)
    }
}

/**
 * Decides when to show the "move your wrist in a figure 8" hint: only after the compass has been poor for
 * [showAfterMs], and hides it after it has been fine for [hideAfterMs], so it does not flash.
 */
class AccuracyGate(private val showAfterMs: Long = 1_500, private val hideAfterMs: Long = 1_000) {
    var showing = false
        private set
    private var poorSince = -1L
    private var goodSince = -1L

    /** Feed each reading; returns whether the hint should be showing now. */
    fun update(nowMs: Long, poor: Boolean): Boolean {
        if (poor) {
            goodSince = -1L
            if (poorSince < 0) poorSince = nowMs
            if (!showing && nowMs - poorSince >= showAfterMs) showing = true
        } else {
            poorSince = -1L
            if (goodSince < 0) goodSince = nowMs
            if (showing && nowMs - goodSince >= hideAfterMs) showing = false
        }
        return showing
    }
}

/**
 * Remembers the magnetic declination for a place. [compute] is the platform call (GeomagneticField); it is only
 * asked again when the position moved by about 0.1 degree (11 km) or the answer is a day old.
 */
class DeclinationCache(private val compute: (lat: Double, lon: Double, nowMs: Long) -> Float?) {
    private var lat = 0.0
    private var lon = 0.0
    private var at = 0L
    private var value: Float? = null

    /** Declination in degrees, east positive, or null if it cannot be worked out. */
    fun get(lat: Double, lon: Double, nowMs: Long): Float? {
        val v = value
        if (v != null && nowMs >= at && nowMs - at < MAX_AGE_MS &&
            abs(lat - this.lat) < MOVED_DEG && abs(HeadingFilter.delta(this.lon, lon)) < MOVED_DEG
        ) return v
        val fresh = runCatching { compute(lat, lon, nowMs) }.getOrNull()
        if (fresh != null) {
            this.lat = lat; this.lon = lon; at = nowMs; value = fresh
            return fresh
        }
        return v // an old answer beats none; null if there never was one
    }

    companion object {
        const val MAX_AGE_MS = 24L * 60 * 60 * 1000
        const val MOVED_DEG = 0.1
    }
}

object CompassTuning {
    /** While the Direction screen is open the watch's cached fix is re-read this often (no GPS is started). */
    const val HERE_REFRESH_MS = 15_000L
}
