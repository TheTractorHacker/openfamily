package app.openfamily

import android.content.Context
import android.os.Handler
import android.os.Looper
import com.google.android.gms.common.ConnectionResult
import com.google.android.gms.common.GoogleApiAvailability
import com.google.android.gms.wearable.PutDataMapRequest
import com.google.android.gms.wearable.Wearable
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Phone side of the Wear OS companion (docs/design/WATCH_APPS.md).
 *
 * MethodChannel `app.openfamily/watch`:
 *   publish(json)  -> bool   puts the snapshot into the Wearable Data Layer
 *   clear()                  deletes it (sign-out, bridge off)
 *   status()       -> map    {available, nodes, names}
 * and calls back into Dart: command(json), peerChanged().
 *
 * Everything degrades to a harmless no-op without Google Play services or a
 * paired watch; nothing here ever throws into Dart.
 */
class WatchBridgePlugin private constructor(
    private val context: Context,
    messenger: BinaryMessenger,
) {
    private val channel = MethodChannel(messenger, CHANNEL)
    private val main = Handler(Looper.getMainLooper())

    init {
        channel.setMethodCallHandler { call, result ->
            try {
                handle(call, result)
            } catch (_: Throwable) {
                result.success(null)
            }
        }
    }

    private fun available(): Boolean = try {
        GoogleApiAvailability.getInstance().isGooglePlayServicesAvailable(context) == ConnectionResult.SUCCESS
    } catch (_: Throwable) {
        false
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "publish" -> {
                val json = call.arguments as? String
                if (json == null || !available()) {
                    result.success(false)
                    return
                }
                val req = PutDataMapRequest.create(SNAPSHOT_PATH).apply {
                    dataMap.putString("json", json)
                }.asPutDataRequest().setUrgent()
                Wearable.getDataClient(context).putDataItem(req)
                    .addOnSuccessListener { result.success(true) }
                    .addOnFailureListener { result.success(false) }
            }
            "clear" -> {
                if (!available()) {
                    result.success(null)
                    return
                }
                val uri = android.net.Uri.Builder().scheme("wear").path(SNAPSHOT_PATH).build()
                Wearable.getDataClient(context).deleteDataItems(uri)
                    .addOnCompleteListener { result.success(null) }
            }
            "status" -> {
                if (!available()) {
                    result.success(mapOf("available" to false, "nodes" to 0, "names" to emptyList<String>()))
                    return
                }
                Wearable.getNodeClient(context).connectedNodes
                    .addOnSuccessListener { nodes ->
                        result.success(
                            mapOf(
                                "available" to true,
                                "nodes" to nodes.size,
                                "names" to nodes.map { it.displayName },
                            ),
                        )
                    }
                    .addOnFailureListener {
                        result.success(mapOf("available" to true, "nodes" to 0, "names" to emptyList<String>()))
                    }
            }
            else -> result.notImplemented()
        }
    }

    /** True when Dart has taken the command; false when no engine is attached. */
    private fun deliver(method: String, arg: Any?) {
        main.post {
            try {
                channel.invokeMethod(method, arg)
            } catch (_: Throwable) {
            }
        }
    }

    companion object {
        const val CHANNEL = "app.openfamily/watch"
        const val SNAPSHOT_PATH = "/orbitly/snapshot"
        const val COMMAND_PATH = "/orbitly/cmd"
        const val ACK_PATH = "/orbitly/ack"

        @Volatile
        private var current: WatchBridgePlugin? = null

        /** Called from MainActivity.configureFlutterEngine. */
        fun register(context: Context, messenger: BinaryMessenger) {
            current = WatchBridgePlugin(context.applicationContext, messenger)
        }

        /** The Flutter engine is gone; commands can no longer be executed. */
        fun unregister() {
            current?.channel?.setMethodCallHandler(null)
            current = null
        }

        /** Used by [WatchListenerService]. Returns false when the app is not running. */
        fun forwardCommand(json: String): Boolean {
            val p = current ?: return false
            p.deliver("command", json)
            return true
        }

        fun peerChanged() {
            current?.deliver("peerChanged", null)
        }
    }
}
