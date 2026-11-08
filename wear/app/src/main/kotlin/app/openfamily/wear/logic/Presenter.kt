package app.openfamily.wear.logic

import app.openfamily.wear.data.Snapshot

/** Turns a snapshot into what the screens show. Pure functions, unit tested. */
object Presenter {
    data class Here(val lat: Double, val lon: Double)

    data class Row(val id: String, val name: String, val initials: String, val color: Int, val subtitle: String, val battery: String, val lowBattery: Boolean) {
        /** Second line of a list row, built once when the row is made instead of on every recomposition. */
        val detail: String = listOf(subtitle, battery).filter { it.isNotEmpty() }.joinToString(" · ")
    }

    sealed interface Link {
        data object NoData : Link
        data object Connected : Link
        data class Offline(val ageText: String) : Link
    }

    /** What the header says about the connection to the phone. */
    fun link(s: Snapshot?, phoneConnected: Boolean, nowMs: Long): Link = when {
        s == null || !s.signedIn && s.ts == 0L -> Link.NoData
        phoneConnected -> Link.Connected
        else -> Link.Offline(Format.age(nowMs, s.ts))
    }

    /** Line under a name: the phone's status text, plus how old the position is when it is not fresh. */
    fun subtitle(m: Snapshot.Member, nowMs: Long): String {
        val base = m.line.ifEmpty {
            when (m.state) {
                Snapshot.State.Driving -> m.speedKmh?.let { "Driving" } ?: "Driving"
                Snapshot.State.AtPlace -> if (m.place.isNotEmpty()) "At ${m.place}" else "Stationary"
                Snapshot.State.Stopped -> "Updates stopped"
                else -> if (m.hasPosition) "Location shared" else "No location yet"
            }
        }
        val fresh = m.fixAt != null && nowMs - m.fixAt < 2 * 60_000
        return if (m.fixAt == null || fresh) base else "$base · ${Format.age(nowMs, m.fixAt)}"
    }

    fun rows(s: Snapshot, nowMs: Long, here: Here? = null): List<Row> =
        sorted(s.members, here).map {
            Row(it.id, it.name, it.initials, it.color, subtitle(it, nowMs), Format.battery(it.battery), it.battery in 1..20)
        }

    /** Nearest first when the watch knows where it is; otherwise "you" first, then most recently seen. */
    fun sorted(members: List<Snapshot.Member>, here: Here?): List<Snapshot.Member> =
        if (here != null) {
            members.sortedWith(compareBy({ !it.hasPosition }, { distanceTo(it, here) ?: Double.MAX_VALUE }))
        } else {
            members.sortedWith(compareBy({ !it.isYou }, { -(it.fixAt ?: 0L) }))
        }

    fun distanceTo(m: Snapshot.Member, here: Here): Double? =
        if (m.lat == null || m.lon == null) null else Geo.distanceM(here.lat, here.lon, m.lat, m.lon)

    /** Nearest other person with a known position. */
    fun nearest(s: Snapshot, here: Here?): Snapshot.Member? {
        val others = s.members.filter { !it.isYou && it.hasPosition }
        return if (here != null) others.minByOrNull { distanceTo(it, here) ?: Double.MAX_VALUE }
        else others.maxByOrNull { it.fixAt ?: 0L }
    }

    fun sharingLabel(s: Snapshot): String = if (s.sharing == Snapshot.Sharing.Paused) "Sharing paused" else "Sharing on"

    /** Result of the latest command the user sent, if the phone has answered. */
    fun commandOutcome(s: Snapshot?, commandId: String?): Snapshot.CommandResult? =
        if (commandId == null) null else s?.lastCommand?.takeIf { it.id == commandId }
}
