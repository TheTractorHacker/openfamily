package app.openfamily.e2ee_keystore

import android.app.Activity
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyInfo
import android.security.keystore.KeyPermanentlyInvalidatedException
import android.security.keystore.KeyProperties
import android.security.keystore.StrongBoxUnavailableException
import android.view.WindowManager
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.SecretKey
import javax.crypto.SecretKeyFactory
import javax.crypto.spec.GCMParameterSpec

/**
 * Android Keystore wrapping key for the end-to-end encryption secrets.
 *
 * The Keystore holds ONE non-extractable AES-256-GCM key. Dart encrypts the
 * identity seed and cached circle keys with it before writing them to disk.
 * The Ed25519 / X25519 / XChaCha20 primitives are NOT hardware backed; only
 * this wrapping key is (StrongBox when the phone has it, TEE otherwise,
 * software as the last resort). `status` reports which one so the app can show
 * it. If the key is invalidated, `decrypt` fails with code "invalidated" and
 * the app fails closed (restore from the recovery phrase).
 *
 * Locked phone: the wrapping key is deliberately NOT bound to an unlocked device
 * (no setUnlockedDeviceRequired), because the background location service must
 * seal and upload positions while the phone sits locked in a pocket. It is still
 * hardware-backed, non-exportable and device-bound. The key `alias` (v2) replaced
 * `legacyAlias` (v1), which required an unlocked device; the legacy key is only
 * used to decrypt old blobs while migrating (see E2eeVault.migrateLegacy) and is
 * deleted only after Dart confirmed every blob was re-wrapped and read back.
 *
 * Registered as a plugin, so Flutter attaches it to EVERY engine: the app's and
 * the headless background-location engine (background_locator_2). It used to be
 * set up in MainActivity.configureFlutterEngine, i.e. only on the app's engine,
 * so in the background isolate every vault read failed with
 * MissingPluginException and every Private-circle fix was parked until the app
 * was opened (and was lost after 12 h). All engines share the one Keystore key;
 * Android serialises the calls on the main thread.
 *
 * `setSecure` needs an Activity and is a no-op in an engine without one.
 */
class E2eeKeystorePlugin : FlutterPlugin, ActivityAware {
    private var channel: MethodChannel? = null
    private var context: Context? = null
    private var activity: Activity? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "app.openfamily/keystore").also {
            it.setMethodCallHandler { call, result -> handle(call, result) }
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
        context = null
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
    }

    override fun onDetachedFromActivityForConfigChanges() {
        activity = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activity = binding.activity
    }

    override fun onDetachedFromActivity() {
        activity = null
    }

    private val alias = "openfamily_e2ee_wrap_v2"
    private val legacyAlias = "openfamily_e2ee_wrap_v1"
    private val provider = "AndroidKeyStore"

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "encrypt" -> result.success(encrypt(call.arguments as ByteArray))
                "decrypt" -> result.success(decrypt(call.arguments as ByteArray))
                "status" -> result.success(status())
                // Migration from the v1 key (unlocked-device-only). Never creates a key.
                "decryptLegacy" -> result.success(decryptLegacy(call.arguments as ByteArray))
                "hasLegacy" -> result.success(store().containsAlias(legacyAlias))
                "deleteLegacy" -> {
                    val ks = store()
                    if (ks.containsAlias(legacyAlias)) ks.deleteEntry(legacyAlias)
                    result.success(null)
                }
                "recreateKey" -> {
                    val auth = (call.arguments as? Map<*, *>)?.get("requireUserAuth") == true
                    recreate(auth)
                    result.success(null)
                }
                "setSecure" -> {
                    val on = call.arguments == true
                    val a = activity
                    a?.runOnUiThread {
                        if (on) a.window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
                        else a.window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
                    }
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        } catch (e: KeyPermanentlyInvalidatedException) {
            result.error("invalidated", "key invalidated", null)
        } catch (e: android.security.keystore.UserNotAuthenticatedException) {
            // Locked phone / auth-bound key: the key is fine, just not usable right now.
            result.error("locked", "key not usable now", null)
        } catch (e: java.security.UnrecoverableKeyException) {
            result.error("invalidated", "key unrecoverable", null)
        } catch (e: Throwable) {
            // Never put key material or plaintext in the message.
            result.error("keystore", e.javaClass.simpleName, null)
        }
    }

    private fun store(): KeyStore = KeyStore.getInstance(provider).apply { load(null) }

    private fun key(): SecretKey {
        val ks = store()
        val existing = ks.getKey(alias, null) as? SecretKey
        if (existing != null) return existing
        return generate(false)
    }

    private fun generate(requireUserAuth: Boolean): SecretKey {
        fun spec(strongBox: Boolean): KeyGenParameterSpec {
            val b = KeyGenParameterSpec.Builder(
                alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .setRandomizedEncryptionRequired(true)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                if (strongBox) b.setIsStrongBoxBacked(true)
                // Only the opt-in strict mode ties the key to an unlocked phone.
                // The default must work with the screen locked (background sealing).
                if (requireUserAuth) b.setUnlockedDeviceRequired(true)
            }
            if (requireUserAuth) {
                b.setUserAuthenticationRequired(true)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                    b.setUserAuthenticationParameters(
                        30, KeyProperties.AUTH_BIOMETRIC_STRONG or KeyProperties.AUTH_DEVICE_CREDENTIAL)
                } else {
                    @Suppress("DEPRECATION")
                    b.setUserAuthenticationValidityDurationSeconds(30)
                }
            }
            return b.build()
        }
        val gen = javax.crypto.KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, provider)
        val sbOk = Build.VERSION.SDK_INT >= Build.VERSION_CODES.P &&
            context?.packageManager?.hasSystemFeature(PackageManager.FEATURE_STRONGBOX_KEYSTORE) == true
        if (sbOk) {
            try {
                gen.init(spec(true))
                return gen.generateKey()
            } catch (_: StrongBoxUnavailableException) {
                // fall through to the TEE
            }
        }
        gen.init(spec(false))
        return gen.generateKey()
    }

    private fun recreate(requireUserAuth: Boolean) {
        val ks = store()
        if (ks.containsAlias(alias)) ks.deleteEntry(alias)
        generate(requireUserAuth)
    }

    private fun encrypt(plain: ByteArray): ByteArray {
        val c = Cipher.getInstance("AES/GCM/NoPadding")
        c.init(Cipher.ENCRYPT_MODE, key())
        val iv = c.iv
        val ct = c.doFinal(plain)
        return byteArrayOf(iv.size.toByte()) + iv + ct
    }

    private fun decrypt(blob: ByteArray, which: String = alias): ByteArray {
        val ivLen = blob[0].toInt()
        val iv = blob.copyOfRange(1, 1 + ivLen)
        val ct = blob.copyOfRange(1 + ivLen, blob.size)
        val c = Cipher.getInstance("AES/GCM/NoPadding")
        c.init(Cipher.DECRYPT_MODE, store().getKey(which, null) ?: throw java.security.UnrecoverableKeyException(),
            GCMParameterSpec(128, iv))
        return c.doFinal(ct)
    }

    /** A key that needs an unlocked phone refuses to init while locked: report that as "locked", not as lost. */
    private fun decryptLegacy(blob: ByteArray): ByteArray = try {
        decrypt(blob, legacyAlias)
    } catch (e: KeyPermanentlyInvalidatedException) {
        throw e
    } catch (e: java.security.InvalidKeyException) {
        throw android.security.keystore.UserNotAuthenticatedException()
    }

    private fun status(): Map<String, Any> {
        val k = key()
        var level = "software"
        var unlocked = false
        var auth = false
        try {
            val info = SecretKeyFactory.getInstance(k.algorithm, provider).getKeySpec(k, KeyInfo::class.java) as KeyInfo
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                level = when (info.securityLevel) {
                    KeyProperties.SECURITY_LEVEL_STRONGBOX -> "strongbox"
                    KeyProperties.SECURITY_LEVEL_TRUSTED_ENVIRONMENT -> "tee"
                    else -> "software"
                }
            } else {
                @Suppress("DEPRECATION")
                level = if (info.isInsideSecureHardware) "tee" else "software"
            }
            // KeyInfo cannot report this; it was requested when the key was created (API 28+).
            auth = info.isUserAuthenticationRequired
            // KeyInfo does not expose "unlocked device required" at all, so it cannot be read back.
            // The v2 key is created without that flag (see the key generator above); the opt-in strict
            // mode is the only path that sets it, and nothing in the UI turns that on.
            unlocked = false
        } catch (_: Throwable) {
            // keep "software": we could not prove hardware backing
        }
        return mapOf("level" to level, "unlockedDeviceRequired" to unlocked, "userAuthRequired" to auth,
            "legacyKey" to store().containsAlias(legacyAlias))
    }
}
