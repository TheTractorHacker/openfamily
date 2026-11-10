package app.openfamily

import android.app.ActivityManager
import android.content.Context
import android.content.Intent
import android.os.Bundle
import androidx.core.view.WindowCompat
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterFragmentActivity() {
    private var linkChannel: MethodChannel? = null
    private var initialLink: String? = null
    private var deviceChannel: MethodChannel? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        // Deliberately opt in to edge-to-edge (Android 15+ enforces it for
        // targetSdk 35+; this keeps older versions identical). The Flutter UI
        // pads for the status bar, cutout and gesture bar via MediaQuery.
        WindowCompat.setDecorFitsSystemWindows(window, false)
        super.onCreate(savedInstanceState)
        // Cold start from an invite link (https://<server>/join/<code> or
        // openfamily://join?...). A restored activity must not replay it.
        if (savedInstanceState == null) {
            initialLink = linkFrom(intent)
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "app.openfamily/links")
        channel.setMethodCallHandler { call, result ->
            if (call.method == "getInitialLink") {
                result.success(initialLink)
                initialLink = null
            } else {
                result.notImplemented()
            }
        }
        linkChannel = channel

        // Memory facts for the device tier (see perf/device_tier.dart) and the
        // channel that carries onTrimMemory levels back to Dart.
        val device = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "app.openfamily/device")
        device.setMethodCallHandler { call, result ->
            if (call.method == "memoryInfo") {
                try {
                    val am = getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
                    val mi = ActivityManager.MemoryInfo()
                    am.getMemoryInfo(mi)
                    result.success(
                        mapOf(
                            "totalBytes" to mi.totalMem,
                            "availableBytes" to mi.availMem,
                            "isLowRamDevice" to am.isLowRamDevice,
                            "memoryClassMb" to am.memoryClass,
                            "largeMemoryClassMb" to am.largeMemoryClass,
                        )
                    )
                } catch (_: Throwable) {
                    result.success(null)
                }
            } else {
                result.notImplemented()
            }
        }
        deviceChannel = device

        // The Keystore wrapping key of the end-to-end encryption vault (and
        // FLAG_SECURE) is the e2ee_keystore plugin (packages/e2ee_keystore), so it
        // is registered in every engine, the background-location one included.

        // Read-only phone health facts and OEM settings deep links for the
        // Diagnostics screen (see DiagnosticsChannel.kt).
        val diagnostics = DiagnosticsChannel(applicationContext)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "app.openfamily/diagnostics")
            .setMethodCallHandler { call, result -> diagnostics.handle(call, result) }

        // "Keep this phone's key safe through reinstalls": Block Store, local only
        // (see KeyBackupChannel.kt). Main engine only: restore runs at sign-in.
        val keyBackup = KeyBackupChannel(applicationContext)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "app.openfamily/key_backup")
            .setMethodCallHandler { call, result -> keyBackup.handle(call, result) }

        // Wear OS companion bridge; a no-op without Play services or a paired
        // watch (see WatchBridgePlugin.kt).
        WatchBridgePlugin.register(applicationContext, flutterEngine.dartExecutor.binaryMessenger)

        // Home-screen widget snapshot store. Never throws into Dart.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "app.openfamily/widget")
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "write" -> result.success(
                            FamilyWidgetProvider.write(applicationContext, call.arguments as? String ?: "")
                        )
                        "clear" -> {
                            FamilyWidgetProvider.clear(applicationContext)
                            result.success(null)
                        }
                        "hasWidgets" -> result.success(FamilyWidgetProvider.hasWidgets(applicationContext))
                        else -> result.notImplemented()
                    }
                } catch (_: Throwable) {
                    result.success(false)
                }
            }
    }

    // The system asks apps to give memory back (ComponentCallbacks2). Dart
    // decides what to free; see perf/memory_pressure.dart.
    override fun onTrimMemory(level: Int) {
        super.onTrimMemory(level)
        try {
            deviceChannel?.invokeMethod("trim", level)
        } catch (_: Throwable) {
        }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        WatchBridgePlugin.unregister()
        super.cleanUpFlutterEngine(flutterEngine)
    }

    // singleTop: a link opened while the app is running arrives here.
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        linkFrom(intent)?.let { linkChannel?.invokeMethod("link", it) }
    }

    private fun linkFrom(intent: Intent?): String? =
        if (intent?.action == Intent.ACTION_VIEW) intent.dataString else null
}
