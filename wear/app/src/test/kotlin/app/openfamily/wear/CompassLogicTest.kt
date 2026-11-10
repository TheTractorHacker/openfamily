package app.openfamily.wear

import app.openfamily.wear.logic.AccuracyGate
import app.openfamily.wear.logic.AngleFollower
import app.openfamily.wear.logic.ArrowEngine
import app.openfamily.wear.logic.Commands
import app.openfamily.wear.logic.CompassMath
import app.openfamily.wear.logic.CompassMath.Axis
import app.openfamily.wear.logic.DeclinationCache
import app.openfamily.wear.logic.TiltTracker
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.sin

/** Unit quaternion (x, y, z, w) as the rotation-vector sensor reports it. */
private fun quat(axisX: Double, axisY: Double, axisZ: Double, deg: Double): FloatArray {
    val n = Math.sqrt(axisX * axisX + axisY * axisY + axisZ * axisZ)
    val h = Math.toRadians(deg) / 2
    val s = sin(h) / n
    return floatArrayOf((axisX * s).toFloat(), (axisY * s).toFloat(), (axisZ * s).toFloat(), cos(h).toFloat())
}

/** Hamilton product a * b (apply b first, then a), both x, y, z, w. */
private fun mul(a: FloatArray, b: FloatArray): FloatArray {
    val (ax, ay, az, aw) = a.map { it.toDouble() }
    val (bx, by, bz, bw) = b.map { it.toDouble() }
    return floatArrayOf(
        (aw * bx + ax * bw + ay * bz - az * by).toFloat(),
        (aw * by - ax * bz + ay * bw + az * bx).toFloat(),
        (aw * bz + ax * by - ay * bx + az * bw).toFloat(),
        (aw * bw - ax * bx - ay * by - az * bz).toFloat(),
    )
}

private fun matrix(q: FloatArray): DoubleArray = DoubleArray(9).also { CompassMath.rotationMatrix(q, it) }

/**
 * A watch whose 12 o'clock points at compass [headingDeg] (clockwise from north), screen tilted up by [pitchDeg]
 * (0 flat, 90 vertical with 12 o'clock up), rolled by [rollDeg] about its own 12 o'clock axis.
 * World is east, north, up; at identity the device is flat, 12 o'clock to north.
 */
private fun pose(headingDeg: Double, pitchDeg: Double = 0.0, rollDeg: Double = 0.0): FloatArray {
    val yaw = quat(0.0, 0.0, 1.0, -headingDeg) // clockwise heading is a negative turn about up
    val pitch = quat(1.0, 0.0, 0.0, pitchDeg) // tilts 12 o'clock up (positive about east)
    val roll = quat(0.0, 1.0, 0.0, rollDeg)
    return mul(yaw, mul(pitch, roll))
}

private fun angDiff(a: Double, b: Double) = abs(((a - b) % 360.0 + 540.0) % 360.0 - 180.0)

class AngleFollowerTest {
    @Test fun crossingNorthTurnsTheShortWay() {
        val f = AngleFollower(18.0)
        f.snapTo(359.0)
        f.setTarget(1.0)
        assertEquals(2.0, f.target - f.position, 1e-9)
        var maxStep = 0.0
        var prev = f.position
        repeat(60) {
            f.step(1.0 / 60)
            maxStep = maxOf(maxStep, abs(f.position - prev))
            prev = f.position
        }
        assertTrue("never sweeps the long way, biggest step $maxStep", maxStep < 2.1)
        assertEquals(1.0, f.degrees, 0.06)
    }

    @Test fun neverOvershootsAStep() {
        val f = AngleFollower(18.0)
        f.snapTo(0.0)
        f.setTarget(90.0)
        var peak = 0.0
        repeat(200) {
            f.step(1.0 / 60)
            peak = maxOf(peak, f.position)
        }
        assertTrue("peak $peak", peak <= 90.0 + 1e-6)
        assertEquals(90.0, f.position, 1e-9)
    }

    @Test fun reaches90PercentInAboutAFifthOfASecond() {
        val f = AngleFollower(18.0)
        f.snapTo(0.0)
        f.setTarget(100.0)
        var t = 0.0
        while (f.position < 90.0) {
            f.step(1.0 / 60)
            t += 1.0 / 60
        }
        assertTrue("took $t s", t in 0.15..0.30)
    }

    @Test fun startsWithoutAJerk() {
        val f = AngleFollower(18.0)
        f.snapTo(0.0)
        f.setTarget(90.0)
        assertEquals("starts at rest, no velocity jump", 0.0, f.velocity, 0.0)
        f.step(1.0 / 60)
        val first = f.position
        f.step(1.0 / 60)
        assertTrue("first frame moves little: $first", first < 4.0)
        assertTrue("and speeds up smoothly: ${f.position - first} vs $first", f.position - first > first)
    }

    @Test fun sameResultForAnyFrameTime() {
        fun run(dt: Double, n: Int): Double {
            val f = AngleFollower(18.0)
            f.snapTo(0.0)
            f.setTarget(60.0)
            repeat(n) { f.step(dt) }
            return f.position
        }
        assertEquals(run(1.0 / 120, 60), run(1.0 / 30, 15), 1e-6) // 0.5 s either way
    }

    @Test fun longGapIsClamped() {
        val f = AngleFollower(2.0)
        f.snapTo(0.0)
        f.setTarget(90.0)
        f.step(5.0)
        val clamped = AngleFollower(2.0).also { it.snapTo(0.0); it.setTarget(90.0); it.step(AngleFollower.MAX_DT_S) }
        assertEquals(clamped.position, f.position, 1e-12)
    }

    @Test fun settlesExactlyAndSaysSo() {
        val f = AngleFollower(18.0)
        f.snapTo(10.0)
        assertTrue(f.settled)
        f.setTarget(40.0)
        assertFalse(f.settled)
        var frames = 0
        while (!f.settled && frames < 600) { f.step(1.0 / 60); frames++ }
        assertTrue(f.settled)
        assertEquals(40.0, f.position, 0.0)
        assertTrue("settled within a second, took $frames frames", frames < 60)
    }

    @Test fun keepsTurningTheSameWayForManyLapsAndStaysPrecise() {
        val f = AngleFollower(18.0)
        f.snapTo(0.0)
        var raw = 0.0
        repeat(36_000) { // 100 laps in 10 degree steps
            raw = (raw + 10.0) % 360.0
            f.setTarget(raw)
            f.step(1.0 / 60)
        }
        assertTrue("unwrapped state stays small: ${f.target}", abs(f.target) < 1100)
        repeat(120) { f.step(1.0 / 60) }
        assertEquals(raw, f.degrees, 0.06)
    }

    @Test fun firstTargetIsTakenAsIs() {
        val f = AngleFollower(18.0)
        f.setTarget(200.0)
        assertTrue(f.started)
        assertEquals(200.0, f.degrees, 0.0)
        assertTrue(f.settled)
    }
}

class ArrowEngineTest {
    @Test fun arrowIsBearingMinusHeading() {
        val e = ArrowEngine()
        e.onBearing(90.0)
        e.onHeading(30.0)
        assertEquals(60.0, e.arrowDeg, 1e-9)
        assertEquals(330.0, e.northDeg, 1e-9)
    }

    @Test fun noiseDoesNotWakeTheLoop() {
        val e = ArrowEngine()
        e.onBearing(0.0)
        assertTrue(e.onHeading(100.0))
        assertFalse(e.onHeading(100.2))
        assertFalse(e.onHeading(99.8))
        assertTrue(e.onHeading(100.5))
    }

    @Test fun aNewBearingGlidesInInsteadOfJumping() {
        val e = ArrowEngine()
        e.onBearing(10.0)
        e.onHeading(0.0)
        assertTrue(e.onBearing(50.0))
        assertEquals(10.0, e.arrowDeg, 1e-9) // nothing moved yet
        e.step(1.0 / 60)
        assertTrue("moves a little in the first frame: ${e.arrowDeg}", e.arrowDeg > 10.0 && e.arrowDeg < 14.0)
        repeat(120) { e.step(1.0 / 60) }
        assertEquals(50.0, e.arrowDeg, 0.06)
        assertTrue(e.settled)
    }

    @Test fun turningThroughNorthDoesNotSpinTheArrow() {
        val e = ArrowEngine()
        e.onBearing(0.0)
        e.onHeading(358.0)
        var last = e.arrowDeg
        var worst = 0.0
        for (raw in listOf(359.0, 0.5, 2.0, 4.0, 6.0)) {
            e.onHeading(raw)
            repeat(3) {
                e.step(1.0 / 60)
                worst = maxOf(worst, angDiff(e.arrowDeg, last))
                last = e.arrowDeg
            }
        }
        assertTrue("biggest frame step $worst", worst < 3.0)
    }

    @Test fun restsWhenNothingMoves() {
        val e = ArrowEngine()
        e.onBearing(30.0)
        e.onHeading(70.0)
        assertTrue(e.settled)
        e.onHeading(150.0)
        assertFalse(e.settled)
    }
}

class CompassMathTest {
    @Test fun identityRotationIsTheIdentityMatrix() {
        val r = matrix(floatArrayOf(0f, 0f, 0f, 1f))
        assertEquals(listOf(1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0), r.toList())
    }

    @Test fun threeValuesAreCompletedLikeTheFramework() {
        val a = matrix(floatArrayOf(0.1f, 0.2f, 0.3f))
        val w = Math.sqrt(1 - 0.01 - 0.04 - 0.09).toFloat()
        val b = matrix(floatArrayOf(0.1f, 0.2f, 0.3f, w))
        for (i in 0 until 9) assertEquals(b[i], a[i], 1e-6)
    }

    @Test fun matrixOfAFiveValueEventIgnoresTheAccuracyEstimate() {
        val q = pose(40.0)
        val five = q.copyOf(5).also { it[4] = 0.5f }
        assertEquals(matrix(q).toList(), matrix(five).toList())
    }

    @Test fun levelWatchReadsItsCompassHeading() {
        for (h in listOf(0.0, 45.0, 90.0, 180.0, 270.0, 359.0)) {
            val az = CompassMath.azimuthDeg(matrix(pose(h)), Axis.Top)
            assertNotNull(az)
            assertEquals("heading $h", 0.0, angDiff(az!!, h), 1e-4)
        }
    }

    @Test fun pitchingTheWristUpDoesNotChangeTheHeadingOnEitherAxis() {
        for (pitch in listOf(0.0, 20.0, 40.0, 55.0)) {
            val r = matrix(pose(120.0, pitch))
            assertEquals("top axis at $pitch", 0.0, angDiff(CompassMath.azimuthDeg(r, Axis.Top)!!, 120.0), 1e-3)
            if (pitch > 0) assertEquals("back axis at $pitch", 0.0, angDiff(CompassMath.azimuthDeg(r, Axis.Back)!!, 120.0), 1e-3)
        }
    }

    @Test fun backAxisStaysRightWhenTheScreenIsUpright() {
        // Screen vertical, 12 o'clock straight up: the top axis has no direction, the back axis still points where the watch faces.
        val r = matrix(pose(75.0, 90.0))
        assertNull(CompassMath.azimuthDeg(r, Axis.Top))
        assertEquals(0.0, angDiff(CompassMath.azimuthDeg(r, Axis.Back)!!, 75.0), 1e-3)
    }

    @Test fun trueHeadingAddsDeclinationEastPositive() {
        assertEquals(15.0, CompassMath.trueHeading(10.0, 5.0), 1e-9)
        assertEquals(355.0, CompassMath.trueHeading(5.0, -10.0), 1e-9)
        assertEquals(5.0, CompassMath.trueHeading(355.0, 10.0), 1e-9)
    }

    @Test fun poorAccuracyIsDetected() {
        assertTrue(CompassMath.isPoor(0, null))
        assertTrue(CompassMath.isPoor(1, null))
        assertFalse(CompassMath.isPoor(2, null))
        assertFalse(CompassMath.isPoor(3, 0.1f))
        assertTrue(CompassMath.isPoor(3, 0.5f))
        assertFalse("-1 means no estimate", CompassMath.isPoor(3, -1f))
    }
}

class TiltTrackerTest {
    @Test fun usesTopAxisUntilSteeplyTiltedThenBackAxisWithHysteresis() {
        val t = TiltTracker()
        assertNotNull(t.azimuth(pose(10.0, 30.0)))
        assertEquals(Axis.Top, t.axis)
        t.azimuth(pose(10.0, 65.0)) // sin 65 = 0.906 > 0.87
        assertEquals(Axis.Back, t.axis)
        t.azimuth(pose(10.0, 52.0)) // sin 52 = 0.788, between 0.74 and 0.87: stays
        assertEquals(Axis.Back, t.axis)
        t.azimuth(pose(10.0, 40.0)) // sin 40 = 0.643 < 0.74
        assertEquals(Axis.Top, t.axis)
        t.azimuth(pose(10.0, 52.0))
        assertEquals("does not flip back inside the band", Axis.Top, t.axis)
    }

    @Test fun headingIsContinuousWhileRaisingTheWristThroughTheSwitch() {
        val t = TiltTracker()
        var prev: Double? = null
        var pitch = 0.0
        while (pitch <= 85.0) {
            val az = t.azimuth(pose(200.0, pitch))!!
            prev?.let { assertTrue("jump of ${angDiff(az, it)} at pitch $pitch", angDiff(az, it) < 0.5) }
            prev = az
            pitch += 1.0
        }
        assertEquals(0.0, angDiff(prev!!, 200.0), 1e-3)
    }

    @Test fun headingIsRightAtTheSwitchEvenWithSomeRoll() {
        // Roll about the arm axis moves the two axes' directions apart; at the switch angle the error stays modest.
        val t = TiltTracker()
        val az = t.azimuth(pose(100.0, 60.0, 20.0))!!
        assertTrue("error ${angDiff(az, 100.0)}", angDiff(az, 100.0) < 25.0)
    }

    @Test fun holdsWhenNoAxisHasADirection() {
        val t = TiltTracker()
        assertNull(CompassMath.azimuthDeg(matrix(pose(0.0, 90.0)), Axis.Top))
        // Watch lying face up: the back axis is straight down, but the top axis is the one in use there.
        assertNotNull(t.azimuth(pose(0.0, 0.0)))
    }
}

class AccuracyGateTest {
    @Test fun showsOnlyAfterTheCompassStaysPoor() {
        val g = AccuracyGate()
        assertFalse(g.update(0, poor = true))
        assertFalse(g.update(1_000, poor = true))
        assertTrue(g.update(1_500, poor = true))
    }

    @Test fun aShortBadPatchNeverShows() {
        val g = AccuracyGate()
        g.update(0, true)
        g.update(1_000, true)
        assertFalse(g.update(1_100, false))
        assertFalse("the clock restarted", g.update(2_000, true))
        assertFalse(g.update(3_000, true))
        assertTrue(g.update(3_500, true))
    }

    @Test fun hidesOnlyAfterItHasBeenGoodForAWhile() {
        val g = AccuracyGate()
        g.update(0, true)
        assertTrue(g.update(1_600, true))
        assertTrue(g.update(2_000, false))
        assertTrue(g.update(2_900, false))
        assertFalse(g.update(3_000, false))
        assertTrue("a dip while hiding restarts the wait", run { g.update(3_100, true); g.update(4_700, true) })
    }
}

class DeclinationCacheTest {
    @Test fun computesOnceForNearbyPositionsAndRefreshesWhenFarOrOld() {
        var calls = 0
        val c = DeclinationCache { _, _, _ -> calls++; 7.5f }
        assertEquals(7.5f, c.get(50.0, 8.0, 0)!!, 0f)
        c.get(50.05, 8.05, 1_000)
        assertEquals(1, calls)
        c.get(50.5, 8.0, 2_000) // 0.5 degree north
        assertEquals(2, calls)
        c.get(50.5, 8.0, 2_000 + DeclinationCache.MAX_AGE_MS)
        assertEquals(3, calls)
    }

    @Test fun nearTheDateLineLongitudeJumpIsNotTreatedAsFar() {
        var calls = 0
        val c = DeclinationCache { _, _, _ -> calls++; 1f }
        c.get(0.0, 179.98, 0)
        c.get(0.0, -179.98, 10)
        assertEquals(1, calls)
    }

    @Test fun aFailureGivesNullThenKeepsAnOldAnswerAndRetries() {
        var fail = true
        val c = DeclinationCache { _, _, _ -> if (fail) throw IllegalStateException("no model") else 3f }
        assertNull(c.get(10.0, 10.0, 0))
        fail = false
        assertEquals(3f, c.get(10.0, 10.0, 1)!!, 0f)
        fail = true
        assertEquals("old answer beats none", 3f, c.get(60.0, 10.0, 2)!!, 0f)
    }
}

class PresenceArgTest {
    @Test fun alwaysOnWinsThenFindingThenPlain() {
        assertEquals("ambient", Commands.presenceArg(ambient = true, finding = true))
        assertEquals("ambient", Commands.presenceArg(ambient = true, finding = false))
        assertEquals("finding", Commands.presenceArg(ambient = false, finding = true))
        assertNull(Commands.presenceArg(ambient = false, finding = false))
    }

    @Test fun theArgsMatchTheWordsThePhoneAccepts() {
        // watch_snapshot.dart accepts exactly these two.
        assertEquals("ambient", Commands.AMBIENT_ARG)
        assertEquals("finding", Commands.FINDING_ARG)
    }
}
