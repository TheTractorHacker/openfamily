package app.openfamily.wear.logic

object Format {
    /** "just now", "2 min ago", "3 h ago", "4 d ago". */
    fun age(nowMs: Long, atMs: Long?): String {
        if (atMs == null || atMs <= 0) return "unknown"
        val s = ((nowMs - atMs) / 1000).coerceAtLeast(0)
        return when {
            s < 60 -> "just now"
            s < 3600 -> "${s / 60} min ago"
            s < 86_400 -> "${s / 3600} h ago"
            else -> "${s / 86_400} d ago"
        }
    }

    /** Snapshot is old enough that the screen should say so loudly. */
    fun isStale(nowMs: Long, snapshotTs: Long, limitMs: Long = 15 * 60_000L): Boolean =
        snapshotTs <= 0 || nowMs - snapshotTs > limitMs

    fun battery(pct: Int): String = if (pct in 0..100) "$pct%" else ""
}
