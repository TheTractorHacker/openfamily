package app.openfamily.wear.data

import app.openfamily.wear.logic.Commands
import org.json.JSONObject
import com.google.android.gms.wearable.DataEvent
import com.google.android.gms.wearable.DataEventBuffer
import com.google.android.gms.wearable.DataMapItem
import com.google.android.gms.wearable.MessageEvent
import com.google.android.gms.wearable.Node
import com.google.android.gms.wearable.WearableListenerService

/**
 * Woken by the system only when the phone writes or deletes the snapshot item
 * or the phone connects/disconnects. There is no polling anywhere in this app.
 */
class DataLayerService : WearableListenerService() {
    override fun onDataChanged(events: DataEventBuffer) {
        try {
            for (e in events) {
                if (e.dataItem.uri.path != Commands.SNAPSHOT_PATH) continue
                when (e.type) {
                    DataEvent.TYPE_CHANGED -> {
                        val json = DataMapItem.fromDataItem(e.dataItem).dataMap.getString("json")
                        if (json != null) SnapshotRepository.accept(this, json)
                    }
                    DataEvent.TYPE_DELETED -> SnapshotRepository.clear(this)
                }
            }
        } finally {
            events.release()
        }
    }

    /** The phone's own refusal when Orbitly is not running there (see WatchListenerService on the phone). */
    override fun onMessageReceived(event: MessageEvent) {
        if (event.path != Commands.ACK_PATH || event.data.size > 512) return
        runCatching {
            val o = JSONObject(String(event.data, Charsets.UTF_8))
            val id = o.optString("id")
            if (id.isNotEmpty()) {
                SnapshotRepository.postExternalResult(
                    Snapshot.CommandResult(id, "", o.optBoolean("ok", false), System.currentTimeMillis(), o.optString("message")),
                )
            }
        }
    }

    override fun onPeerConnected(peer: Node) {
        SnapshotRepository.setPhoneConnected(true)
    }

    override fun onPeerDisconnected(peer: Node) {
        SnapshotRepository.setPhoneConnected(false)
    }
}
