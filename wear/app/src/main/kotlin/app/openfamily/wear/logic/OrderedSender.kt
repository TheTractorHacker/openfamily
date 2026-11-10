package app.openfamily.wear.logic

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.launch

/**
 * Hands items to [send] one at a time, in the order they were [post]ed, however long each send takes. Used for the
 * presence messages: sent from separate coroutines a plain `visible` could overtake a `visible finding` and end
 * the phone's faster cadence until the next repeat. [post] never blocks and is safe from any thread.
 */
class OrderedSender<T>(scope: CoroutineScope, private val send: suspend (T) -> Unit) {
    private val queue = Channel<T>(Channel.UNLIMITED)

    init {
        scope.launch { for (item in queue) runCatching { send(item) } }
    }

    fun post(item: T) {
        queue.trySend(item)
    }

    /** No more items; those already posted are still sent, then the sender ends. */
    fun close() {
        queue.close()
    }
}
