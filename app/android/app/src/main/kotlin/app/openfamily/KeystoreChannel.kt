package app.openfamily

import android.app.Activity
import android.content.pm.PackageManager
import android.os.Build
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyInfo
import android.security.keystore.KeyPermanentlyInvalidatedException
import android.security.keystore.KeyProperties
import android.security.keystore.StrongBoxUnavailableException
import android.view.WindowManager
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
 */
class KeystoreChannel(private val activity: Activity) {
    private val alias = "openfamily_e2ee_wrap_v1"
    private val provider = "AndroidKeyStore"

    fun handle(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "encrypt" -> result.success(encrypt(call.arguments as ByteArray))
                "decrypt" -> result.success(decrypt(call.arguments as ByteArray))
                "status" -> result.success(status())
                "recreateKey" -> {
                    val auth = (call.arguments as? Map<*, *>)?.get("requireUserAuth") == true
                    recreate(auth)
                    result.success(null)
                }
                "setSecure" -> {
                    val on = call.arguments == true
                    activity.runOnUiThread {
                        if (on) activity.window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
                        else activity.window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
                    }
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        } catch (e: KeyPermanentlyInvalidatedException) {
            result.error("invalidated", "key invalidated", null)
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
                b.setUnlockedDeviceRequired(true)
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
            activity.packageManager.hasSystemFeature(PackageManager.FEATURE_STRONGBOX_KEYSTORE)
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

    private fun decrypt(blob: ByteArray): ByteArray {
        val ivLen = blob[0].toInt()
        val iv = blob.copyOfRange(1, 1 + ivLen)
        val ct = blob.copyOfRange(1 + ivLen, blob.size)
        val c = Cipher.getInstance("AES/GCM/NoPadding")
        c.init(Cipher.DECRYPT_MODE, store().getKey(alias, null) ?: throw java.security.UnrecoverableKeyException(),
            GCMParameterSpec(128, iv))
        return c.doFinal(ct)
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
            unlocked = Build.VERSION.SDK_INT >= Build.VERSION_CODES.P
            auth = info.isUserAuthenticationRequired
        } catch (_: Throwable) {
            // keep "software": we could not prove hardware backing
        }
        return mapOf("level" to level, "unlockedDeviceRequired" to unlocked, "userAuthRequired" to auth)
    }
}
