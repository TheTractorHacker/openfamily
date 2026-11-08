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
                // Signed out / switched off: never send family data (until allowPublish).
                if (json == null || !available() || isBlocked(context)) {
                    result.success(false)
                    return
                }
                // First publish of a login that has no identity yet (restored session).
                val sid = session(context) ?: newSession(context)
                putSnapshot(context, json, sid)
                    .addOnSuccessListener { result.success(true) }
                    .addOnFailureListener { result.success(false) }
            }
            "clear" -> {
                // Not best effort: block sending and remember the debt first, pay it now if
                // possible, otherwise when a watch connects (WatchListenerService).
                setBlocked(context, true)
                setClearPending(context, true)
                dropSession(context)
                deleteSnapshot(context) { delivered -> result.success(delivered) }
            }
            "allowPublish" -> {
                // A NEW identity: a previous user's data on the watch is dropped because its
                // session differs. An undelivered wipe is sent first (and announces the new
                // session); the debt is only cleared once the delete reached a connected watch.
                newSession(context)
                setBlocked(context, false)
                if (clearPending(context)) payClearDebt(context, announce = false) {}
                result.success(null)
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

        private const val PREFS = "orbitly_watch"
        private const val KEY_PENDING = "clear_pending"
        private const val KEY_BLOCKED = "blocked"
        private const val KEY_SESSION = "session"

        private fun prefs(c: Context) = c.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

        /** A wipe the watch has not confirmed yet. Survives restarts. */
        fun clearPending(c: Context): Boolean = prefs(c).getBoolean(KEY_PENDING, false)
        fun setClearPending(c: Context, v: Boolean) { prefs(c).edit().putBoolean(KEY_PENDING, v).apply() }

        /** No family data may be sent (after clear, until allowPublish). */
        fun isBlocked(c: Context): Boolean = prefs(c).getBoolean(KEY_BLOCKED, false)
        fun setBlocked(c: Context, v: Boolean) { prefs(c).edit().putBoolean(KEY_BLOCKED, v).apply() }

        /** Identity of the current login; every snapshot carries it and the watch drops other sessions. */
        fun session(c: Context): String? = prefs(c).getString(KEY_SESSION, null)
        fun newSession(c: Context): String =
            java.util.UUID.randomUUID().toString().also { prefs(c).edit().putString(KEY_SESSION, it).apply() }
        fun dropSession(c: Context) { prefs(c).edit().remove(KEY_SESSION).apply() }

        fun putSnapshot(c: Context, json: String, sid: String) =
            Wearable.getDataClient(c).putDataItem(
                PutDataMapRequest.create(SNAPSHOT_PATH).apply {
                    dataMap.putString("json", json)
                    dataMap.putString("session", sid)
                }.asPutDataRequest().setUrgent(),
            )

        /**
         * Deletes the snapshot DataItem and reports whether the removal is confirmed:
         * true only with Play services, a successful delete and at least one connected
         * watch to receive it. On true the pending flag is cleared.
         */
        fun deleteSnapshot(c: Context, done: (Boolean) -> Unit) {
            try {
                val ok = GoogleApiAvailability.getInstance().isGooglePlayServicesAvailable(c) == ConnectionResult.SUCCESS
                if (!ok) {
                    done(false)
                    return
                }
                val uri = android.net.Uri.Builder().scheme("wear").path(SNAPSHOT_PATH).build()
                Wearable.getDataClient(c).deleteDataItems(uri)
                    .addOnSuccessListener {
                        Wearable.getNodeClient(c).connectedNodes
                            .addOnSuccessListener { nodes ->
                                val delivered = nodes.isNotEmpty()
                                if (delivered) setClearPending(c, false)
                                done(delivered)
                            }
                            .addOnFailureListener { done(false) }
                    }
                    .addOnFailureListener { done(false) }
            } catch (_: Throwable) {
                done(false)
            }
        }

        /**
         * Pays an outstanding wipe: delete the item and, when [announce] and the user has
         * signed in again (not blocked), announce the new session with an EMPTY snapshot so a
         * watch that missed the delete still drops the previous user's data. [announce] is
         * false while the app runs: its real snapshot carries the new session itself and an
         * empty one could overwrite it.
         */
        fun payClearDebt(c: Context, announce: Boolean, done: (Boolean) -> Unit) {
            deleteSnapshot(c) { delivered ->
                if (announce && delivered && !isBlocked(c)) {
                    val sid = session(c) ?: newSession(c)
                    try {
                        putSnapshot(c, """{"v":1,"ts":${System.currentTimeMillis()},"signedIn":false}""", sid)
                    } catch (_: Throwable) {
                    }
                }
                done(delivered)
            }
        }

        fun appRunning(): Boolean = current != null

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
