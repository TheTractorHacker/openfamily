package app.openfamily.wear.data

import org.json.JSONArray
import org.json.JSONException
import org.json.JSONObject

/** Everything the phone tells the watch. Wire format: docs/design/WATCH_APPS.md. */
data class Snapshot(
    val version: Int = 1,
    /** When the phone built the snapshot (epoch ms). */
    val ts: Long = 0,
    val signedIn: Boolean = false,
    val scope: Scope = Scope(),
    val circles: List<Circle> = emptyList(),
    val sharing: Sharing = Sharing.On,
    val pausedUntil: Long? = null,
    val unread: Int = 0,
    val members: List<Member> = emptyList(),
    val alerts: List<Alert> = emptyList(),
    val lastCommand: CommandResult? = null,
) {
    data class Scope(val id: String = "", val name: String = "", val isPrivate: Boolean = false)
    data class Circle(val id: String, val name: String, val unread: Int, val isPrivate: Boolean)
    enum class Sharing { On, Paused }

    enum class State { Driving, Moving, AtPlace, Still, Stopped, None }

    data class Member(
        val id: String,
        val name: String,
        val initials: String,
        val color: Int,
        val lat: Double?,
        val lon: Double?,
        val fixAt: Long?,
        val battery: Int,
        val state: State,
        val speedKmh: Int?,
        val place: String,
        val address: String,
        /** The phone's own one-line status, shown as is. */
        val line: String,
        val isPrivate: Boolean,
        val isYou: Boolean,
    ) {
        val hasPosition: Boolean get() = lat != null && lon != null
    }

    data class Alert(
        val id: String,
        val kind: String,
        val from: String,
        val at: Long,
        val note: String,
        val active: Boolean,
    )

    data class CommandResult(val id: String, val cmd: String, val ok: Boolean, val at: Long, val message: String)

    companion object {
        const val MAX_BYTES = 100 * 1024

        /** Returns null when [json] is not a snapshot this watch understands. */
        fun parse(json: String): Snapshot? {
            if (json.length > MAX_BYTES) return null
            return try {
                val o = JSONObject(json)
                val v = o.optInt("v", 0)
                // Unknown newer major versions are ignored rather than half-read.
                if (v < 1 || v > 1) return null
                val scope = o.optJSONObject("scope")
                val me = o.optJSONObject("me")
                Snapshot(
                    version = v,
                    ts = o.optLong("ts", 0),
                    signedIn = o.optBoolean("signedIn", false),
                    scope = Scope(
                        scope?.optString("id").orEmpty(),
                        scope?.optString("name").orEmpty(),
                        scope?.optBoolean("private", false) ?: false,
                    ),
                    circles = o.optJSONArray("circles").objects().map {
                        Circle(it.optString("id"), it.optString("name"), it.optInt("unread", 0).coerceAtLeast(0), it.optBoolean("private", false))
                    },
                    sharing = if (me?.optString("sharing") == "paused") Sharing.Paused else Sharing.On,
                    pausedUntil = me?.optLongOrNull("pausedUntil"),
                    unread = o.optInt("unread", 0).coerceAtLeast(0),
                    members = o.optJSONArray("members").objects().mapNotNull { m ->
                        val id = m.optString("id")
                        if (id.isEmpty()) return@mapNotNull null
                        val name = m.optString("name").ifEmpty { "Someone" }
                        Member(
                            id = id,
                            name = name,
                            initials = m.optString("initials").ifEmpty { name.take(1).uppercase() },
                            color = m.optLong("color", 0xFF8E8E93).toInt(),
                            lat = m.optDoubleOrNull("lat"),
                            lon = m.optDoubleOrNull("lon"),
                            fixAt = m.optLongOrNull("fixAt"),
                            battery = m.optInt("battery", -1).let { if (it in 0..100) it else -1 },
                            state = stateOf(m.optString("state")),
                            speedKmh = m.optIntOrNull("speedKmh"),
                            place = m.optString("place"),
                            address = m.optString("address"),
                            line = m.optString("line"),
                            isPrivate = m.optBoolean("private", false),
                            isYou = m.optBoolean("you", false),
                        )
                    },
                    alerts = o.optJSONArray("alerts").objects().mapNotNull { a ->
                        val id = a.optString("id")
                        if (id.isEmpty()) null else Alert(
                            id, a.optString("kind"), a.optString("from").ifEmpty { "Someone" },
                            a.optLong("at", 0), a.optString("note"), a.optBoolean("active", true),
                        )
                    },
                    lastCommand = o.optJSONObject("lastCommand")?.let {
                        val id = it.optString("id")
                        if (id.isEmpty()) null else CommandResult(
                            id, it.optString("cmd"), it.optBoolean("ok", false), it.optLong("at", 0), it.optString("message"),
                        )
                    },
                )
            } catch (_: JSONException) {
                null
            }
        }

        private fun stateOf(s: String) = when (s) {
            "driving" -> State.Driving
            "moving" -> State.Moving
            "at_place" -> State.AtPlace
            "still" -> State.Still
            "stopped" -> State.Stopped
            else -> State.None
        }
    }
}

private fun JSONArray?.objects(): List<JSONObject> =
    if (this == null) emptyList() else (0 until length()).mapNotNull { optJSONObject(it) }

private fun JSONObject.optLongOrNull(k: String): Long? = if (has(k) && !isNull(k)) optLong(k) else null
private fun JSONObject.optIntOrNull(k: String): Int? = if (has(k) && !isNull(k)) optInt(k) else null
private fun JSONObject.optDoubleOrNull(k: String): Double? =
    if (has(k) && !isNull(k)) optDouble(k).takeUnless { it.isNaN() } else null
