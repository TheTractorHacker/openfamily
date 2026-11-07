package app.openfamily

import android.content.Intent
import android.os.Bundle
import androidx.core.view.WindowCompat
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterFragmentActivity() {
    private var linkChannel: MethodChannel? = null
    private var initialLink: String? = null

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

        // Keystore-backed wrapping key + FLAG_SECURE for the end-to-end encryption
        // secrets (see KeystoreChannel.kt).
        val keystore = KeystoreChannel(this)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "app.openfamily/keystore")
            .setMethodCallHandler { call, result -> keystore.handle(call, result) }

        // Read-only phone health facts and OEM settings deep links for the
        // Diagnostics screen (see DiagnosticsChannel.kt).
        val diagnostics = DiagnosticsChannel(applicationContext)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "app.openfamily/diagnostics")
            .setMethodCallHandler { call, result -> diagnostics.handle(call, result) }

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
