package app.openfamily.wear.logic

import kotlin.math.abs

/** Smoothing for the compass arrow so a 5 Hz sensor does not make it jitter or cost redraws. */
object HeadingFilter {
    /** Signed shortest turn from [from] to [to], in -180..180. */
    fun delta(from: Double, to: Double): Double {
        val d = ((to - from) % 360.0 + 540.0) % 360.0 - 180.0
        return d
    }

    /**
     * Low-pass step on a circle (359 -> 1 is a 2 degree turn, not 358).
     * Returns [prev] unchanged when the change is under [deadbandDeg], which keeps
     * the state (and the screen) still while the watch is held steady.
     */
    fun next(prev: Double?, raw: Double, alpha: Double = 0.4, deadbandDeg: Double = 1.5): Double {
        if (prev == null) return norm(raw)
        val d = delta(prev, raw)
        if (abs(d) < deadbandDeg) return prev
        return norm(prev + alpha * d)
    }

    private fun norm(d: Double) = ((d % 360.0) + 360.0) % 360.0
}
