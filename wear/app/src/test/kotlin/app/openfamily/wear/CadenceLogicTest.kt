package app.openfamily.wear

import app.openfamily.wear.data.Snapshot
import app.openfamily.wear.logic.Commands
import app.openfamily.wear.logic.Presenter
import app.openfamily.wear.logic.SurfaceGate
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

private const val T0 = 1_767_225_600_000L

private fun snap(
    unread: Int = 0,
    paused: Boolean = false,
    samLat: Double = 51.51,
    samFix: Long = T0,
    battery: Int = 80,
    line: String = "At Home",
    signedIn: Boolean = true,
    ts: Long = T0,
) = Snapshot.parse(
    """
    {"v":1,"ts":$ts,"signedIn":$signedIn,"unread":$unread,
     "me":{"sharing":"${if (paused) "paused" else "on"}"},
     "members":[
      {"id":"me","name":"Me","lat":51.5,"lon":-0.12,"fixAt":$T0,"battery":50,"state":"still","line":"Stationary","you":true},
      {"id":"sam","name":"Sam","lat":$samLat,"lon":-0.12,"fixAt":$samFix,"battery":$battery,"state":"at_place","line":"$line"}
     ]}
    """.trimIndent(),
)!!

/** The cadence contract (docs/design/WATCH_APPS.md, Cadence): new fields, commands and the surface gate. */
class CadenceLogicTest {
    @Test fun lineAtIsParsedAndFormattedOnTheWatch() {
        val s = Snapshot.parse(
            """{"v":1,"ts":$T0,"signedIn":true,"members":[
              {"id":"a","name":"Ana","lat":51.5,"lon":-0.1,"fixAt":$T0,"state":"still","line":"Left Work","lineAt":${T0 - 25 * 60_000}},
              {"id":"b","name":"Bo","lat":51.5,"lon":-0.1,"fixAt":${T0 - 600_000},"state":"stopped","line":"Updates stopped, last seen","lineAt":${T0 - 3 * 86_400_000L}},
              {"id":"c","name":"Cy","lat":51.5,"lon":-0.1,"fixAt":$T0,"state":"still","line":"Stationary","lineAt":0}
            ]}""",
        )!!
        val (ana, bo, cy) = s.members
        assertEquals(T0 - 25 * 60_000, ana.lineAt)
        assertEquals("Left Work 25 min ago", Presenter.subtitle(ana, T0))
        // A minute later the watch says so by itself; the phone sent nothing new.
        assertEquals("Left Work 26 min ago", Presenter.subtitle(ana, T0 + 60_000))
        // No duplicate "· 10 min ago" from the fix time when the line carries its own age.
        assertEquals("Updates stopped, last seen 3 d ago", Presenter.subtitle(bo, T0))
        assertNull("0 or missing means no age", cy.lineAt)
        assertEquals("Stationary", Presenter.subtitle(cy, T0))
    }

    @Test fun oldSnapshotsWithoutLineAtStillWork() {
        val m = snap().members[1]
        assertNull(m.lineAt)
        assertEquals("At Home", Presenter.subtitle(m, T0))
    }

    @Test fun presenceCommandsUseTheFixedWireNames() {
        val v = JSONObject(String(Commands.build(Commands.Cmd.Visible, nowMs = T0, id = "v1").bytes))
        assertEquals("visible", v.getString("cmd"))
        assertFalse(v.has("arg"))
        val a = JSONObject(String(Commands.build(Commands.Cmd.Visible, "ambient", nowMs = T0, id = "v2").bytes))
        assertEquals("ambient", a.getString("arg"))
        assertEquals("hidden", JSONObject(String(Commands.build(Commands.Cmd.Hidden, nowMs = T0).bytes)).getString("cmd"))
        assertTrue("the phone forgets visible after 150 s", Commands.VISIBLE_REPEAT_MS < 150_000L)
    }

    @Test fun surfaceGateRedrawsOnlyForWhatTheyShow() {
        val g = SurfaceGate(minGapMs = 60_000)
        assertTrue("first snapshot", g.shouldRefresh(snap(), T0))
        // A keep-alive (new ts only), a battery step and a new status text: tile and complication show none of it.
        assertFalse(g.shouldRefresh(snap(ts = T0 + 600_000), T0 + 5_000))
        assertFalse(g.shouldRefresh(snap(battery = 40, line = "Driving"), T0 + 10_000))
        // Unread and sharing: at once.
        assertTrue(g.shouldRefresh(snap(unread = 2), T0 + 15_000))
        assertTrue(g.shouldRefresh(snap(unread = 2, paused = true), T0 + 20_000))
        // Someone moved 1 km, 10 s after the last redraw: held back for the 60 s gap...
        assertFalse(g.shouldRefresh(snap(unread = 2, paused = true, samLat = 51.52), T0 + 30_000))
        // ...then drawn.
        assertTrue(g.shouldRefresh(snap(unread = 2, paused = true, samLat = 51.52), T0 + 81_000))
        // Signed out: at once.
        assertTrue(g.shouldRefresh(snap(signedIn = false), T0 + 82_000))
    }

    @Test fun surfaceGateCountsForADrivingHourInTheVisibleTier() {
        // 720 snapshots (one per 5 s), Sam 75 m further each time: at most one redraw a minute.
        val g = SurfaceGate()
        var redraws = 0
        for (i in 0 until 720) {
            val t = T0 + i * 5_000L
            if (g.shouldRefresh(snap(samLat = 51.51 + i * 0.000675, samFix = t), t)) redraws++
        }
        assertTrue("redraws=$redraws", redraws in 55..61)
    }

    @Test fun resetRedraws() {
        val g = SurfaceGate()
        assertTrue(g.shouldRefresh(snap(), T0))
        assertFalse(g.shouldRefresh(snap(), T0 + 1))
        g.reset()
        assertTrue(g.shouldRefresh(snap(), T0 + 2))
    }
}
