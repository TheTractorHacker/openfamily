package app.openfamily.wear.logic

/**
 * Per-login identity of the data on the watch. The phone makes a new session id each
 * time the user signs in (allowPublish) and puts it in every snapshot item; data of
 * any other session is the previous user's and must not survive.
 */
object SessionGate {
    /**
     * @param stored session of the data currently held on the watch (null = none or unknown)
     * @param incoming session on the arriving item (null = phone without session support)
     * @return true when everything stored (snapshot, tile and complication data) must be
     *         wiped BEFORE the incoming item is used.
     */
    fun mustWipe(stored: String?, incoming: String?): Boolean =
        incoming != null && stored != null && stored != incoming

    /** The session to remember after accepting [incoming]. */
    fun next(stored: String?, incoming: String?): String? = incoming ?: stored
}
