package app.openfamily.wear.logic

import kotlin.math.abs
import kotlin.math.exp
import kotlin.math.floor

/**
 * A critically damped follower for an angle in degrees. It runs once per display frame, so the arrow glides
 * between sensor readings instead of stepping at the sensor rate, and it never overshoots.
 *
 * The angle is kept **unwrapped** (it can be 725 or -40): a new reading moves the target by the shortest turn from
 * the previous one, so 359 to 1 degrees is +2, never -358, and the follower never spins the long way round.
 * The step is the exact closed-form solution of a critically damped spring, so it is stable for any frame time.
 * Not thread-safe: use it from one thread (the main thread).
 */
class AngleFollower(private val omega: Double) {
    /** Where the follower is now, unwrapped. */
    var position = 0.0
        private set

    /** Degrees per second. */
    var velocity = 0.0
        private set

    /** Where it is heading, unwrapped. */
    var target = 0.0
        private set

    private var lastRaw = 0.0

    /** False until the first reading; the first one is taken as is, with no glide from 0. */
    var started = false
        private set

    /** The position as 0..360. */
    val degrees: Double get() = norm(position)

    /** Within a twentieth of a degree of the target and almost stopped: the frame loop can rest. */
    val settled: Boolean get() = abs(position - target) < SETTLED_DEG && abs(velocity) < SETTLED_DEG_PER_S

    /** Jump to [raw] with no glide (the first reading). */
    fun snapTo(raw: Double) {
        position = norm(raw)
        target = position
        lastRaw = target
        velocity = 0.0
        started = true
    }

    /** Aim at [raw] (0..360 or any angle); the move is the shortest turn from the last aim. */
    fun setTarget(raw: Double) {
        if (!started) {
            snapTo(raw)
            return
        }
        target += HeadingFilter.delta(lastRaw, raw)
        lastRaw = norm(raw)
        // Keep the numbers small so float precision never degrades after hours of turning.
        if (abs(target) > RENORM_DEG) {
            val k = floor(target / 360.0) * 360.0
            target -= k
            position -= k
        }
    }

    /** Advance by [dtSec] (clamped to 0..0.1 s so a long gap never lurches). */
    fun step(dtSec: Double) {
        val dt = dtSec.coerceIn(0.0, MAX_DT_S)
        if (dt == 0.0) return
        val x = position - target
        val e = exp(-omega * dt)
        val j = velocity + omega * x
        position = target + (x + j * dt) * e
        velocity = (velocity - omega * j * dt) * e
        if (settled) {
            position = target
            velocity = 0.0
        }
    }

    private fun norm(d: Double) = ((d % 360.0) + 360.0) % 360.0

    companion object {
        const val MAX_DT_S = 0.1
        const val SETTLED_DEG = 0.05
        const val SETTLED_DEG_PER_S = 0.5
        private const val RENORM_DEG = 720.0
    }
}

/**
 * The compass arrow: where the person is relative to where the watch points, both followed on unwrapped angles.
 * The heading follower is quick (about 0.2 s to get 90% of the way); the bearing follower is slower, so a new
 * position of the other person glides in instead of jumping. Main thread only.
 */
class ArrowEngine {
    private val heading = AngleFollower(HEADING_OMEGA)
    private val bearing = AngleFollower(BEARING_OMEGA)

    /** True once the first compass reading has arrived; before that the arrow points with north at the top. */
    val hasHeading: Boolean get() = heading.started

    /** Feed a true-north heading. Returns true if the frame loop should wake (the change is not just noise). */
    fun onHeading(rawDeg: Double): Boolean {
        if (heading.started && abs(HeadingFilter.delta(heading.target, rawDeg)) < NOISE_DEG) return false
        heading.setTarget(rawDeg)
        return true
    }

    /** Feed the bearing to the person. The first one is taken as is; later ones glide. Returns true to wake the loop. */
    fun onBearing(rawDeg: Double): Boolean {
        if (bearing.started && abs(HeadingFilter.delta(bearing.target, rawDeg)) < 0.01) return false
        bearing.setTarget(rawDeg)
        return true
    }

    fun step(dtSec: Double) {
        heading.step(dtSec)
        bearing.step(dtSec)
    }

    val settled: Boolean get() = heading.settled && bearing.settled

    /** Arrow rotation, 0..360 clockwise from the top of the watch. */
    val arrowDeg: Double get() = (((bearing.position - heading.position) % 360.0) + 360.0) % 360.0

    /** Where north is on the dial, 0..360 clockwise from the top (the opposite of the heading). */
    val northDeg: Double get() = ((-heading.position % 360.0) + 360.0) % 360.0

    companion object {
        /** Heading: a steady turn lags by about 2 / omega = 0.11 s; no overshoot. */
        const val HEADING_OMEGA = 18.0

        /** Bearing: settles in about 0.65 s. */
        const val BEARING_OMEGA = 6.0

        /** A reading closer than this to the current aim is sensor noise: ignored, and it does not wake the loop. */
        const val NOISE_DEG = 0.3

        /** First frame after a pause or wake-up. */
        const val FIRST_FRAME_DT_S = 1.0 / 60.0
    }
}
