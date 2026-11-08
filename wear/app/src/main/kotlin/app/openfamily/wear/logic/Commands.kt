package app.openfamily.wear.logic

import org.json.JSONObject
import java.util.UUID

/** The fixed command vocabulary the phone accepts (docs/design/WATCH_APPS.md). */
object Commands {
    const val PATH = "/orbitly/cmd"
    const val ACK_PATH = "/orbitly/ack"
    const val SNAPSHOT_PATH = "/orbitly/snapshot"

    enum class Cmd(val wire: String) { Sos("sos"), CheckIn("checkin"), Pause("pause"), Resume("resume"), Ack("ack"), Refresh("refresh"), Reply("reply") }

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
