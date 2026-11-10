package app.openfamily.wear.logic

import org.json.JSONObject
import java.util.UUID

/** The fixed command vocabulary the phone accepts (docs/design/WATCH_APPS.md). */
object Commands {
    const val PATH = "/orbitly/cmd"
    const val ACK_PATH = "/orbitly/ack"
    const val SNAPSHOT_PATH = "/orbitly/snapshot"

    enum class Cmd(val wire: String) {
        Sos("sos"), CheckIn("checkin"), Pause("pause"), Resume("resume"), Ack("ack"), Refresh("refresh"), Reply("reply"),

        /**
         * The app is on screen: the phone sends more often. Arg "ambient" in always-on mode, "finding" while the
         * Direction screen is open (the phone then sends about every 2 s). Never answered.
         */
        Visible("visible"),

        /** The app left the screen: the phone falls back to its slow cadence. Never answered. */
        Hidden("hidden"),
    }

    const val AMBIENT_ARG = "ambient"
    const val FINDING_ARG = "finding"

    /** Arg of [Cmd.Visible] for the app's state: always-on wins, then the Direction screen; null for plain visible. */
    fun presenceArg(ambient: Boolean, finding: Boolean): String? = when {
        ambient -> AMBIENT_ARG
        finding -> FINDING_ARG
        else -> null
    }

    /** How often the app repeats [Cmd.Visible] while on screen; the phone forgets it after 150 s without one. */
    const val VISIBLE_REPEAT_MS = 60_000L

    data class Built(val id: String, val bytes: ByteArray)

    fun build(cmd: Cmd, arg: String? = null, nowMs: Long = System.currentTimeMillis(), id: String = UUID.randomUUID().toString().take(12)): Built {
        val o = JSONObject().put("id", id).put("cmd", cmd.wire).put("at", nowMs)
        if (arg != null) o.put("arg", arg)
        return Built(id, o.toString().toByteArray(Charsets.UTF_8))
    }
}

/** Replies are sent as ids; the phone owns the wording. */
object QuickReplies {
    data class Reply(val id: String, val label: String)

    val all = listOf(
        Reply("ok", "I'm OK"),
        Reply("omw", "On my way"),
        Reply("late", "Running late"),
        Reply("call", "Call me"),
        Reply("thanks", "Thanks"),
    )
}
