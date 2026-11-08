package app.openfamily.wear

import app.openfamily.wear.data.Snapshot
import app.openfamily.wear.logic.Dedupe
import app.openfamily.wear.logic.HeadingFilter
import app.openfamily.wear.logic.Presenter
import app.openfamily.wear.logic.Sos
import app.openfamily.wear.logic.SosState
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

class DedupeTest {
    @Test fun identicalPushIsDropped() {
        val d = Dedupe()
        assertTrue(d.accept("{\"v\":1}", "s1"))
        assertFalse(d.accept("{\"v\":1}", "s1"))
        assertTrue(d.accept("{\"v\":1,\"ts\":2}", "s1"))
        assertTrue("another login with the same text must be handled", d.accept("{\"v\":1,\"ts\":2}", "s2"))
    }

    @Test fun resetAndSeed() {
        val d = Dedupe()
        d.accept("a", null)
        d.reset()
        assertTrue(d.accept("a", null))
        d.seed("b", "s")
        assertFalse(d.accept("b", "s"))
    }
}

class HeadingFilterTest {
    @Test fun shortestTurnAcrossNorth() {
        assertEquals(2.0, HeadingFilter.delta(359.0, 1.0), 1e-9)
        assertEquals(-2.0, HeadingFilter.delta(1.0, 359.0), 1e-9)
        assertEquals(-170.0, HeadingFilter.delta(0.0, 190.0), 1e-9)
    }

    @Test fun firstValueIsTakenAsIs() = assertEquals(90.0, HeadingFilter.next(null, 90.0), 1e-9)

    @Test fun deadBandKeepsValueStill() {
        assertEquals(100.0, HeadingFilter.next(100.0, 101.0), 0.0)
        assertEquals(100.0, HeadingFilter.next(100.0, 99.0), 0.0)
    }

    @Test fun smoothsLargeStepsWithoutJumping() {
        val n = HeadingFilter.next(100.0, 130.0, alpha = 0.4)
        assertEquals(112.0, n, 1e-9)
    }

    @Test fun wrapsAroundNorthInsteadOfSweeping() {
        val n = HeadingFilter.next(358.0, 10.0, alpha = 0.5)
        assertEquals(4.0, n, 1e-9) // 358 + 0.5*12 = 364 -> 4
    }

    @Test fun convergesToTarget() {
        var h: Double? = 0.0
        repeat(40) { h = HeadingFilter.next(h, 200.0) }
        assertTrue(kotlin.math.abs(HeadingFilter.delta(h!!, 200.0)) < 1.5)
    }
}

class SnapshotKeysTest {
    @Test fun duplicateIdsAreDroppedSoListKeysStayUnique() {
        val s = Snapshot.parse(
            """{"v":1,"ts":1,"signedIn":true,
               "members":[{"id":"a","name":"A"},{"id":"a","name":"A again"},{"id":"b","name":"B"}],
               "alerts":[{"id":"x","kind":"sos"},{"id":"x","kind":"sos"}]}""",
        )
        assertNotNull(s)
        assertEquals(listOf("a", "b"), s!!.members.map { it.id })
        assertEquals(1, s.alerts.size)
    }

    @Test fun rowDetailIsBuiltOnceAndSkipsEmptyParts() {
        val r = Presenter.Row("a", "A", "A", 0, "Home", "", false)
        assertEquals("Home", r.detail)
        assertEquals("Home · 80%", Presenter.Row("a", "A", "A", 0, "Home", "80%", false).detail)
    }

    @Test fun oversizedSnapshotIsRejectedBeforeParsing() {
        assertEquals(null, Snapshot.parse(" ".repeat(Snapshot.MAX_BYTES + 1)))
    }
}

class SosHoldTest {
    @Test fun holdAccumulatesInSmallStepsAndArmsOnce() {
        var s = SosState()
        var armedAt = -1
        for (i in 1..40) {
            s = Sos.hold(s, 50)
            if (s.phase == SosState.Phase.Countdown && armedAt < 0) armedAt = i
        }
        assertEquals(30, armedAt) // 30 x 50 ms = 1.5 s
        assertEquals(SosState.COUNTDOWN_SECONDS, s.secondsLeft)
    }

    @Test fun progressNeverExceedsOneBeforeArming() {
        var s = SosState()
        repeat(29) { s = Sos.hold(s, 50) }
        assertTrue(s.holdMs.toFloat() / SosState.HOLD_MS < 1f)
        assertEquals(SosState.Phase.Holding, s.phase)
    }
}
