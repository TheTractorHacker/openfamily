package app.openfamily.wear

import app.openfamily.wear.data.Snapshot
import app.openfamily.wear.logic.Commands
import app.openfamily.wear.logic.Format
import app.openfamily.wear.logic.Geo
import app.openfamily.wear.logic.Presenter
import app.openfamily.wear.logic.Sos
import app.openfamily.wear.logic.SosState
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

private const val NOW = 1_767_225_600_000L

private val SAMPLE = """
{"v":1,"ts":$NOW,"signedIn":true,
 "scope":{"id":"all","name":"Everyone","private":false},
 "circles":[{"id":"c1","name":"Family","unread":2,"private":false}],
 "me":{"sharing":"paused","pausedUntil":${NOW + 3_600_000}},
 "unread":2,
 "members":[
  {"id":"u0","name":"Me","initials":"M","color":4283215696,"lat":51.5,"lon":-0.12,"fixAt":$NOW,"battery":80,"state":"still","line":"Stationary","you":true},
  {"id":"u1","name":"Sam","initials":"S","color":4283215696,"lat":51.51,"lon":-0.12,"fixAt":${NOW - 300_000},"battery":15,"state":"driving","speedKmh":68,"place":"","address":"12 High St","line":"Driving 42 mph","private":true},
  {"id":"u2","name":"Ana","initials":"A","lat":51.6,"lon":-0.12,"fixAt":${NOW - 30_000},"battery":63,"state":"at_place","place":"Home","line":"At Home"},
  {"id":"u3","name":"Nolan","state":"none"},
  {"name":"no id"}
 ],
 "alerts":[{"id":"a1","kind":"sos","from":"Sam","at":${NOW - 1000},"note":"","active":true}],
 "lastCommand":{"id":"k9","cmd":"checkin","ok":true,"at":$NOW,"message":""},
 "future_field":{"x":1}
}""".trimIndent()

class SnapshotTest {
    @Test fun parsesFullSnapshot() {
        val s = Snapshot.parse(SAMPLE)!!
        assertTrue(s.signedIn)
        assertEquals("Everyone", s.scope.name)
        assertEquals(Snapshot.Sharing.Paused, s.sharing)
        assertEquals(2, s.unread)
        // The member without an id is dropped, the rest kept.
        assertEquals(listOf("u0", "u1", "u2", "u3"), s.members.map { it.id })
        val sam = s.members[1]
        assertEquals(Snapshot.State.Driving, sam.state)
        assertEquals(68, sam.speedKmh)
        assertTrue(sam.isPrivate)
        assertEquals(15, sam.battery)
        assertTrue(s.members[0].isYou)
        assertFalse(s.members[3].hasPosition)
        assertEquals(-1, s.members[3].battery)
        assertEquals("k9", s.lastCommand?.id)
        assertEquals("sos", s.alerts.single().kind)
    }

    @Test fun rejectsGarbageAndUnknownVersions() {
        assertNull(Snapshot.parse("not json"))
        assertNull(Snapshot.parse("{}"))
        assertNull(Snapshot.parse("""{"v":2,"signedIn":true}"""))
        assertNull(Snapshot.parse("{\"v\":1,\"pad\":\"" + "x".repeat(Snapshot.MAX_BYTES) + "\"}"))
    }

    @Test fun signedOutSnapshotIsEmpty() {
        val s = Snapshot.parse("""{"v":1,"ts":5,"signedIn":false}""")!!
        assertFalse(s.signedIn)
        assertTrue(s.members.isEmpty())
    }
}

class GeoTest {
    @Test fun distanceAndBearing() {
        // 0.01 degrees of latitude is about 1112 m, due north.
        val d = Geo.distanceM(51.5, -0.12, 51.51, -0.12)
        assertEquals(1112.0, d, 5.0)
        assertEquals(0.0, Geo.bearingDeg(51.5, -0.12, 51.51, -0.12), 0.01)
        assertEquals(90.0, Geo.bearingDeg(0.0, 0.0, 0.0, 1.0), 0.01)
        assertEquals(180.0, Geo.bearingDeg(1.0, 0.0, 0.0, 0.0), 0.01)
        assertEquals(270.0, Geo.bearingDeg(0.0, 1.0, 0.0, 0.0), 0.01)
    }

    @Test fun formatting() {
        assertEquals("80 m", Geo.formatDistance(80.0, true))
        assertEquals("340 m", Geo.formatDistance(341.0, true))
        assertEquals("1.4 km", Geo.formatDistance(1400.0, true))
        assertEquals("98 ft", Geo.formatDistance(30.0, false))
        assertEquals("0.5 mi", Geo.formatDistance(805.0, false))
        assertEquals("N", Geo.compassWord(359.0))
        assertEquals("NE", Geo.compassWord(45.0))
        assertEquals("W", Geo.compassWord(270.0))
        assertEquals(350.0, Geo.relativeDeg(10.0, 20.0), 0.001)
        assertEquals(10.0, Geo.relativeDeg(10.0, null), 0.001)
    }
}

class FormatTest {
    @Test fun ageText() {
        assertEquals("just now", Format.age(NOW, NOW - 20_000))
        assertEquals("2 min ago", Format.age(NOW, NOW - 125_000))
        assertEquals("3 h ago", Format.age(NOW, NOW - 3 * 3_600_000L))
        assertEquals("4 d ago", Format.age(NOW, NOW - 4 * 86_400_000L))
        assertEquals("unknown", Format.age(NOW, null))
        assertEquals("just now", Format.age(NOW, NOW + 5_000)) // clock skew never shows a negative age
    }

    @Test fun staleness() {
        assertTrue(Format.isStale(NOW, 0))
        assertTrue(Format.isStale(NOW, NOW - 16 * 60_000))
        assertFalse(Format.isStale(NOW, NOW - 60_000))
    }
}

class PresenterTest {
    private val snap = Snapshot.parse(SAMPLE)!!

    @Test fun linkStates() {
        assertEquals(Presenter.Link.NoData, Presenter.link(null, true, NOW))
        assertEquals(Presenter.Link.Connected, Presenter.link(snap, true, NOW))
        val off = Presenter.link(snap.copy(ts = NOW - 120_000), false, NOW)
        assertEquals(Presenter.Link.Offline("2 min ago"), off)
    }

    @Test fun rowsWithoutWatchLocationPutYouFirstThenMostRecent() {
        val rows = Presenter.rows(snap, NOW)
        assertEquals(listOf("Me", "Ana", "Sam", "Nolan"), rows.map { it.name })
    }

    @Test fun rowsNearestFirstWithLocation() {
        val here = Presenter.Here(51.5, -0.12)
        val rows = Presenter.rows(snap, NOW, here)
        // "Me" is at the same spot (distance 0), then Sam (1.1 km), Ana (11 km), Nolan has no position.
        assertEquals(listOf("Me", "Sam", "Ana", "Nolan"), rows.map { it.name })
    }

    @Test fun subtitleAddsAgeOnlyWhenNotFresh() {
        val sam = snap.members.first { it.id == "u1" }
        assertEquals("Driving 42 mph · 5 min ago", Presenter.subtitle(sam, NOW))
        val ana = snap.members.first { it.id == "u2" }
        assertEquals("At Home", Presenter.subtitle(ana, NOW))
        val nolan = snap.members.first { it.id == "u3" }
        assertEquals("No location yet", Presenter.subtitle(nolan, NOW))
    }

    @Test fun lowBatteryFlag() {
        val rows = Presenter.rows(snap, NOW).associateBy { it.name }
        assertTrue(rows.getValue("Sam").lowBattery)
        assertEquals("15%", rows.getValue("Sam").battery)
        assertFalse(rows.getValue("Ana").lowBattery)
        assertEquals("", rows.getValue("Nolan").battery)
    }

    @Test fun nearestIgnoresYouAndPositionless() {
        assertEquals("Sam", Presenter.nearest(snap, Presenter.Here(51.5, -0.12))?.name)
        // Without a watch fix: the most recently seen other person.
        assertEquals("Ana", Presenter.nearest(snap, null)?.name)
    }

    @Test fun commandOutcomeMatchesById() {
        assertNotNull(Presenter.commandOutcome(snap, "k9"))
        assertNull(Presenter.commandOutcome(snap, "other"))
        assertNull(Presenter.commandOutcome(null, "k9"))
        assertEquals("Sharing paused", Presenter.sharingLabel(snap))
    }
}

class SosTest {
    @Test fun releaseBeforeHoldCompletesArmsNothing() {
        var s = SosState()
        repeat(10) { s = Sos.hold(s, 50) } // 500 ms
        assertEquals(SosState.Phase.Holding, s.phase)
        s = Sos.release(s)
        assertEquals(SosState(), s)
    }

    @Test fun holdArmsThenCountdownSendsAfterFiveSeconds() {
        var s = SosState()
        var steps = 0
        while (s.phase != SosState.Phase.Countdown) { s = Sos.hold(s, 50); steps++ }
        assertEquals(30, steps) // 1.5 s
        assertEquals(5, s.secondsLeft)
        // Releasing the finger after arming does not cancel (only the Cancel button does).
        assertEquals(SosState.Phase.Countdown, Sos.release(s).phase)
        repeat(4) { s = Sos.tick(s); assertFalse(Sos.shouldSend(s)) }
        assertEquals(1, s.secondsLeft)
        s = Sos.tick(s)
        assertTrue(Sos.shouldSend(s))
    }

    @Test fun cancelDuringCountdownResets() {
        var s = SosState(SosState.Phase.Countdown, SosState.HOLD_MS, 3)
        s = Sos.cancel(s)
        assertEquals(SosState(), s)
        // Ticks after cancel do nothing.
        assertEquals(SosState(), Sos.tick(s))
    }

    @Test fun holdingAgainWhileSendingChangesNothing() {
        val s = SosState(SosState.Phase.Sending, SosState.HOLD_MS, 0)
        assertEquals(s, Sos.hold(s, 50))
    }
}

class CommandsTest {
    @Test fun commandJsonIsSmallAndFixed() {
        val b = Commands.build(Commands.Cmd.Reply, "omw", nowMs = NOW, id = "abc")
        val o = JSONObject(String(b.bytes))
        assertEquals("abc", b.id)
        assertEquals("reply", o.getString("cmd"))
        assertEquals("omw", o.getString("arg"))
        assertEquals(NOW, o.getLong("at"))
        assertTrue(b.bytes.size < 200)
        assertFalse(JSONObject(String(Commands.build(Commands.Cmd.Sos, nowMs = NOW).bytes)).has("arg"))
    }

    @Test fun quickReplyIdsAreUniqueAndKnownToThePhone() {
        val ids = app.openfamily.wear.logic.QuickReplies.all.map { it.id }
        assertEquals(ids.size, ids.toSet().size)
        assertEquals(setOf("ok", "omw", "late", "call", "thanks"), ids.toSet())
    }
}

class SessionGateTest {
    @Test fun otherSessionWipesStoredData() {
        assertTrue(app.openfamily.wear.logic.SessionGate.mustWipe("old", "new"))
    }

    @Test fun sameOrUnknownSessionKeepsData() {
        val g = app.openfamily.wear.logic.SessionGate
        assertFalse(g.mustWipe("a", "a"))
        assertFalse(g.mustWipe(null, "a")) // nothing stored yet
        assertFalse(g.mustWipe("a", null)) // phone without session support
        assertFalse(g.mustWipe(null, null))
    }

    @Test fun rememberedSessionOnlyChangesWhenAnnounced() {
        val g = app.openfamily.wear.logic.SessionGate
        assertEquals("b", g.next("a", "b"))
        assertEquals("a", g.next("a", null))
        assertNull(g.next(null, null))
    }
}
