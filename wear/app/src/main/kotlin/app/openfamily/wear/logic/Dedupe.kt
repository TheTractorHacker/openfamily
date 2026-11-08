package app.openfamily.wear.logic

/**
 * Remembers the last snapshot (text and login session) that was handled, so an
 * identical push costs one string comparison instead of a JSON parse, a disk
 * write and a tile and complication redraw. Exact comparison, not a hash, so a
 * collision can never hide a real change.
 */
class Dedupe {
    private var json: String? = null
    private var session: String? = null

    /** True when [json] with [session] differs from the last accepted one; records it as accepted. */
    @Synchronized
    fun accept(json: String, session: String?): Boolean {
        if (json == this.json && session == this.session) return false
        this.json = json
        this.session = session
        return true
    }

    /** Forget the last value (sign-out, wipe) so the same text is handled again. */
    @Synchronized
    fun reset() {
        json = null
        session = null
    }

    /** Take over a value loaded from disk, so a repeat of it is skipped. */
    @Synchronized
    fun seed(json: String?, session: String?) {
        this.json = json
        this.session = session
    }
}
