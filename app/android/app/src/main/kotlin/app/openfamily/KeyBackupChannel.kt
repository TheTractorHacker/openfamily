package app.openfamily

import android.content.Context
import com.google.android.gms.auth.blockstore.Blockstore
import com.google.android.gms.auth.blockstore.BlockstoreClient
import com.google.android.gms.auth.blockstore.DeleteBytesRequest
import com.google.android.gms.auth.blockstore.RetrieveBytesRequest
import com.google.android.gms.auth.blockstore.StoreBytesData
import com.google.android.gms.common.ConnectionResult
import com.google.android.gms.common.GoogleApiAvailability
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * "Keep this phone's key safe through reinstalls" (lib/services/e2ee/key_backup.dart,
 * docs/design/E2EE.md "Keys survive a reinstall").
 *
 * MethodChannel `app.openfamily/key_backup`, main engine only:
 *   store({key, bytes}) -> bool     Block Store. The entry is also backed up to the user's Google
 *                                   account ONLY when Google can end-to-end encrypt it (Android 9+
 *                                   with a screen lock, isEndToEndEncryptionAvailable); otherwise
 *                                   it stays on this phone.
 *   retrieve({key})     -> bytes?   null when there is no entry
 *   delete({key})       -> null
 *   deleteAll()         -> null
 *
 * The bytes are already sealed by Dart. Nothing here logs them, and errors carry only an
 * exception class name. Without Google Play services (SERVICE_MISSING) every call fails with
 * "unavailable", which Dart treats as "there can be no copy here". Any other Play services state
 * (updating, disabled, ...) and any Block Store failure is a plain "blockstore" error: Dart treats
 * that as "a copy may exist" and does not create a new identity over it.
 */
class KeyBackupChannel(private val context: Context) {
    private fun playServicesState(): Int = try {
        GoogleApiAvailability.getInstance().isGooglePlayServicesAvailable(context)
    } catch (_: Throwable) {
        ConnectionResult.INTERNAL_ERROR
    }

    private fun fail(result: MethodChannel.Result, e: Throwable?) {
        result.error("blockstore", e?.javaClass?.simpleName ?: "failed", null)
    }

    private fun put(client: BlockstoreClient, key: String, bytes: ByteArray, cloud: Boolean, result: MethodChannel.Result) {
        try {
            val data = StoreBytesData.Builder()
                .setKey(key)
                .setBytes(bytes)
                .setShouldBackupToCloud(cloud)
                .build()
            client.storeBytes(data)
                .addOnSuccessListener { n -> result.success(n == bytes.size) }
                .addOnFailureListener { e -> fail(result, e) }
        } catch (e: Throwable) {
            fail(result, e)
        }
    }

    fun handle(call: MethodCall, result: MethodChannel.Result) {
        try {
            val state = playServicesState()
            if (state == ConnectionResult.SERVICE_MISSING) {
                result.error("unavailable", "no Google Play services", null)
                return
            }
            if (state != ConnectionResult.SUCCESS) {
                // Updating, disabled, outdated: may work again soon, so this is not "no copy".
                result.error("blockstore", "play_services_$state", null)
                return
            }
            val client = Blockstore.getClient(context)
            when (call.method) {
                "store" -> {
                    val key = call.argument<String>("key")
                    val bytes = call.argument<ByteArray>("bytes")
                    if (key.isNullOrEmpty() || bytes == null) {
                        result.error("args", "key and bytes", null)
                        return
                    }
                    // Cloud copy only when Google can end-to-end encrypt it; any doubt means local only.
                    client.isEndToEndEncryptionAvailable()
                        .addOnSuccessListener { e2ee -> put(client, key, bytes, e2ee == true, result) }
                        .addOnFailureListener { put(client, key, bytes, false, result) }
                }
                "retrieve" -> {
                    val key = call.argument<String>("key")
                    if (key.isNullOrEmpty()) {
                        result.error("args", "key", null)
                        return
                    }
                    val request = RetrieveBytesRequest.Builder().setKeys(listOf(key)).build()
                    client.retrieveBytes(request)
                        .addOnSuccessListener { r -> result.success(r.blockstoreDataMap[key]?.bytes) }
                        .addOnFailureListener { e -> fail(result, e) }
                }
                "delete" -> {
                    val key = call.argument<String>("key")
                    if (key.isNullOrEmpty()) {
                        result.error("args", "key", null)
                        return
                    }
                    client.deleteBytes(DeleteBytesRequest.Builder().setKeys(listOf(key)).build())
                        .addOnSuccessListener { result.success(null) }
                        .addOnFailureListener { e -> fail(result, e) }
                }
                "deleteAll" -> {
                    client.deleteBytes(DeleteBytesRequest.Builder().setDeleteAll(true).build())
                        .addOnSuccessListener { result.success(null) }
                        .addOnFailureListener { e -> fail(result, e) }
                }
                else -> result.notImplemented()
            }
        } catch (e: Throwable) {
            fail(result, e)
        }
    }
}
