package app.openfamily

import com.google.android.gms.wearable.MessageEvent
import com.google.android.gms.wearable.Node
import com.google.android.gms.wearable.Wearable
import com.google.android.gms.wearable.WearableListenerService
import org.json.JSONObject

/**
 * Woken by Google Play services when a paired watch sends a command or
 * connects. Commands are run by the Flutter app (it holds the tokens and the
 * Private-circle keys); if the app is not running the watch gets an immediate
 * "open Orbitly" answer instead of a command that fires minutes later.
 */
class WatchListenerService : WearableListenerService() {
    override fun onMessageReceived(event: MessageEvent) {
        if (event.path != WatchBridgePlugin.COMMAND_PATH) return
        // Only the paired watch can reach this service (same applicationId and
        // signature are enforced by the Data Layer); still bound the input.
        if (event.data.size > 512) return
        val json = String(event.data, Charsets.UTF_8)
        if (WatchBridgePlugin.forwardCommand(json)) return
        val id = try { JSONObject(json).optString("id") } catch (_: Throwable) { "" }
        if (id.isEmpty()) return
        val reply = JSONObject()
            .put("id", id)
            .put("ok", false)
            .put("message", "Open Orbitly on your phone first.")
            .toString()
            .toByteArray(Charsets.UTF_8)
        Wearable.getMessageClient(this).sendMessage(event.sourceNodeId, WatchBridgePlugin.ACK_PATH, reply)
    }

    override fun onPeerConnected(peer: Node) {
        WatchBridgePlugin.peerChanged()
    }

    override fun onPeerDisconnected(peer: Node) {
        WatchBridgePlugin.peerChanged()
    }
}
