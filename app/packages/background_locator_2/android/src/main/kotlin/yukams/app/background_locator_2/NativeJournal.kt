package yukams.app.background_locator_2

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject

/**
 * A small bounded journal of what happened to the tracking service (created,
 * destroyed, restarted by the OS, heartbeat dropped, task removed, memory
 * trimmed). The app's Diagnostics report reads it through the diagnostics
 * channel: the app module cannot see this plugin's classes, so it reads the
 * same preferences file ([PREFS]) and key ([KEY]) by name (see
 * DiagnosticsChannel.kt in the app module; keep the two in step).
 *
 * Event codes and short details only: never a location, a token or the text of
 * an exception. A line equal to the previous one is folded into it (a repeat
 * counter and a "last seen" time), and an identical event arriving within
 * [MIN_REPEAT_MS] is not written at all, so a failure that repeats every
 * second cannot turn this into a write per second.
 *
 * Never throws.
 */
object NativeJournal {
    const val PREFS = "orbitly_tracking_journal"
    const val KEY = "lines"
    private const val MAX_LINES = 40
    private const val MIN_REPEAT_MS = 5_000L

    private var lastEvent = ""
    private var lastDetail = ""
    private var lastWrittenAt = 0L

    @JvmStatic
    @Synchronized
    fun record(context: Context?, event: String, detail: String = "") {
        try {
            val app = context?.applicationContext ?: return
            val now = System.currentTimeMillis()
            if (event == lastEvent && detail == lastDetail && now - lastWrittenAt in 0 until MIN_REPEAT_MS) return
            lastEvent = event
            lastDetail = detail
            lastWrittenAt = now

            val prefs = app.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            val lines = try {
                JSONArray(prefs.getString(KEY, "[]"))
            } catch (e: Exception) {
                JSONArray()
            }
            val last = if (lines.length() > 0) lines.optJSONObject(lines.length() - 1) else null
            if (last != null && last.optString("e") == event && last.optString("d") == detail) {
                last.put("n", last.optInt("n", 1) + 1)
                last.put("l", now)
            } else {
                val line = JSONObject()
                line.put("t", now)
                line.put("e", event)
                if (detail.isNotEmpty()) line.put("d", detail)
                lines.put(line)
            }
            val kept = JSONArray()
            for (i in maxOf(0, lines.length() - MAX_LINES) until lines.length()) {
                kept.put(lines.get(i))
            }
            prefs.edit().putString(KEY, kept.toString()).apply()
        } catch (e: Throwable) {
            // The journal must never disturb tracking.
        }
    }
}
