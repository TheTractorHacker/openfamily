package app.openfamily.wear.data

import android.content.Context
import app.openfamily.wear.logic.Commands
import com.google.android.gms.wearable.DataMapItem
import com.google.android.gms.wearable.Wearable
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.tasks.await
import kotlinx.coroutines.withContext

/** Talks to the paired phone through the Wearable Data Layer. Never throws into the UI. */
class PhoneLink(context: Context) {
    private val app = context.applicationContext

    /** Reads the stored Data Layer item (the service only fires on changes) and the connection state. */
    suspend fun syncNow(): Unit = withContext(Dispatchers.Default) {
        var readable = false
        var found = false
        runCatching {
            val items = Wearable.getDataClient(app).dataItems.await()
            readable = true
            try {
                for (item in items) {
                    if (item.uri.path == Commands.SNAPSHOT_PATH) {
                        found = true
                        val map = DataMapItem.fromDataItem(item).dataMap
                        map.getString("json")?.let { SnapshotRepository.accept(app, it, map.getString("session")) }
                    }
                }
            } finally {
                items.release()
            }
        }
        refreshConnection()
        // The phone deleted the snapshot (sign-out, bridge off) while this watch was away:
        // forget the stored copy, tile and complication data too.
        if (readable && !found && SnapshotRepository.phoneConnected.value) SnapshotRepository.clear(app)
    }

    suspend fun refreshConnection() {
        val connected = runCatching { Wearable.getNodeClient(app).connectedNodes.await().isNotEmpty() }.getOrDefault(false)
        SnapshotRepository.setPhoneConnected(connected)
    }

    /** True when the message was handed to at least one connected node. Delivery is confirmed later by the phone. */
    suspend fun send(command: Commands.Built): Boolean = runCatching {
        val nodes = Wearable.getNodeClient(app).connectedNodes.await()
        if (nodes.isEmpty()) return false
        // Nearby (the paired phone) first; cloud nodes are not used for commands.
        val targets = nodes.filter { it.isNearby }.ifEmpty { nodes }
        targets.forEach { Wearable.getMessageClient(app).sendMessage(it.id, Commands.PATH, command.bytes).await() }
        true
    }.getOrDefault(false)

    /** Asks the phone for an immediate snapshot. */
    suspend fun requestRefresh(): Boolean = send(Commands.build(Commands.Cmd.Refresh))
}
