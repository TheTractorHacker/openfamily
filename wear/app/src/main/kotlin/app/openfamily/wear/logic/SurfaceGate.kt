package app.openfamily.wear.logic

import app.openfamily.wear.data.Snapshot
import kotlin.math.roundToLong

/**
 * Decides whether a new snapshot is worth redrawing the tile and the complication
 * (each redraw binds their services). They show the nearest people with a distance
 * and an age, the unread count and the sharing state, so only those are compared:
 *
 *  - hard part (signed in, unread, sharing, who has a position): redraw at once;
 *  - soft part (positions to about 100 m, fix times to the minute): at most once
 *    per [minGapMs].
 *
 * Anything else in the snapshot (battery, status text, alerts, command answers,
 * the timestamp of a keep-alive) never redraws them. The system asks for the tile
 * again whenever it is shown, so its ages are current when looked at anyway.
 */
class SurfaceGate(private val minGapMs: Long = 60_000L) {
    private var hard: String? = null
    private var soft: String? = null
    private var lastAt: Long = Long.MIN_VALUE

    /** True when the surfaces should be redrawn for [s]; records it as drawn. */
    @Synchronized
    fun shouldRefresh(s: Snapshot?, nowMs: Long): Boolean {
        val h = hardKey(s)
        val k = softKey(s)
        val go = h != hard || (k != soft && (lastAt == Long.MIN_VALUE || nowMs - lastAt >= minGapMs))
        if (go) {
            hard = h
            soft = k
            lastAt = nowMs
        }
        return go
    }

    /** Forget what was drawn (wipe, sign-out): the next snapshot redraws. */
    @Synchronized
    fun reset() {
        hard = null
        soft = null
        lastAt = Long.MIN_VALUE
    }

    companion object {
        private fun shown(s: Snapshot) = s.members.filter { !it.isYou && it.hasPosition }.sortedBy { it.id }

        fun hardKey(s: Snapshot?): String =
            if (s == null || !s.signedIn) "out"
            else "in|${s.unread}|${s.sharing}|" + shown(s).joinToString(",") { "${it.id}:${it.name}" }

        private fun r3(v: Double?) = if (v == null) 0L else (v * 1000).roundToLong()

        fun softKey(s: Snapshot?): String =
            if (s == null || !s.signedIn) ""
            else shown(s).joinToString(",") { "${it.id}:${r3(it.lat)}:${r3(it.lon)}:${(it.fixAt ?: 0L) / 60_000L}" }
    }
}
