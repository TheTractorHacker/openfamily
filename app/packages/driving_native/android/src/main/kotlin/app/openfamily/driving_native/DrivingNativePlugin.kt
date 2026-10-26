package app.openfamily.driving_native

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.os.Build
import android.os.Bundle
import android.os.Looper
import android.os.PowerManager
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Two EventChannels for the driving detection (both only active while Dart
 * listens, i.e. while a driving session is running):
 *
 *  - `app.openfamily/driving_native/gps`: ~1 Hz fixes from the platform
 *    LocationManager GPS provider (speed, bearing, lat, lon). No Google Play
 *    Services. Needs only the location permissions the app already holds, plus
 *    the foreground service that is running while tracking is active.
 *  - `app.openfamily/driving_native/screen`: see below.
 *
 * Streams ACTION_SCREEN_ON / ACTION_SCREEN_OFF / ACTION_USER_PRESENT to Dart.
 *
 * These broadcasts cannot be declared in the manifest, so the receiver is
 * registered dynamically with the application context while Dart is listening
 * and unregistered when it cancels. Flutter creates one instance of this plugin
 * per FlutterEngine, so it also exists in the headless engine that the
 * background location foreground service hosts: it keeps the process alive, and
 * therefore the receiver registered, while location tracking runs.
 *
 * It needs no permission and reads no app usage. It only reports that the
 * screen turned on/off or the user unlocked the device.
 */
class DrivingNativePlugin : FlutterPlugin {
    private var events: EventChannel? = null
    private var methods: MethodChannel? = null
    private var appContext: Context? = null
    private var receiver: BroadcastReceiver? = null
    private var gps: EventChannel? = null
    private var gpsListener: LocationListener? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        val ctx = binding.applicationContext
        appContext = ctx
        events = EventChannel(binding.binaryMessenger, "app.openfamily/driving_native/screen")
        gps = EventChannel(binding.binaryMessenger, "app.openfamily/driving_native/gps")
        gps?.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, sink: EventChannel.EventSink) {
                startGps(ctx, sink)
            }

            override fun onCancel(arguments: Any?) {
                stopGps(ctx)
            }
        })
        events?.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, sink: EventChannel.EventSink) {
                register(ctx, sink)
            }

            override fun onCancel(arguments: Any?) {
                unregister(ctx)
            }
        })
        methods = MethodChannel(binding.binaryMessenger, "app.openfamily/driving_native/methods")
        methods?.setMethodCallHandler { call: MethodCall, result: MethodChannel.Result ->
            when (call.method) {
                "isInteractive" -> {
                    val pm = ctx.getSystemService(Context.POWER_SERVICE) as PowerManager
                    result.success(pm.isInteractive)
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext?.let {
            unregister(it)
            stopGps(it)
        }
        events?.setStreamHandler(null)
        gps?.setStreamHandler(null)
        gps = null
        methods?.setMethodCallHandler(null)
        events = null
        methods = null
        appContext = null
    }

    private fun register(ctx: Context, sink: EventChannel.EventSink) {
        unregister(ctx)
        val r = object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                val type = when (intent?.action) {
                    Intent.ACTION_SCREEN_ON -> "screen_on"
                    Intent.ACTION_SCREEN_OFF -> "screen_off"
                    Intent.ACTION_USER_PRESENT -> "user_present"
                    else -> return
                }
                // Delivered on the main looper (default for registerReceiver).
                sink.success(mapOf("type" to type, "t" to System.currentTimeMillis()))
            }
        }
        val filter = IntentFilter().apply {
            addAction(Intent.ACTION_SCREEN_ON)
            addAction(Intent.ACTION_SCREEN_OFF)
            addAction(Intent.ACTION_USER_PRESENT)
        }
        if (Build.VERSION.SDK_INT >= 33) {
            // Protected system broadcasts are still delivered to receivers
            // that are not exported.
            ctx.registerReceiver(r, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            ctx.registerReceiver(r, filter)
        }
        receiver = r
    }

    private fun unregister(ctx: Context) {
        receiver?.let {
            try {
                ctx.unregisterReceiver(it)
            } catch (_: IllegalArgumentException) {
                // Already unregistered.
            }
        }
        receiver = null
    }

    @Suppress("MissingPermission", "DEPRECATION")
    private fun startGps(ctx: Context, sink: EventChannel.EventSink) {
        stopGps(ctx)
        val lm = ctx.getSystemService(Context.LOCATION_SERVICE) as LocationManager
        val l = object : LocationListener {
            override fun onLocationChanged(loc: Location) {
                sink.success(
                    mapOf(
                        "t" to System.currentTimeMillis(),
                        "lat" to loc.latitude,
                        "lon" to loc.longitude,
                        // Doppler speed in m/s; -1 when the fix has none.
                        "speed" to (if (loc.hasSpeed()) loc.speed.toDouble() else -1.0),
                        "accuracy" to (if (loc.hasAccuracy()) loc.accuracy.toDouble() else -1.0),
                        "mock" to (if (Build.VERSION.SDK_INT >= 31) loc.isMock else loc.isFromMockProvider),
                    )
                )
            }

            @Deprecated("Deprecated in Java")
            override fun onStatusChanged(provider: String?, status: Int, extras: Bundle?) {}
            override fun onProviderEnabled(provider: String) {}
            override fun onProviderDisabled(provider: String) {}
        }
        try {
            lm.requestLocationUpdates(LocationManager.GPS_PROVIDER, 1000L, 0f, l, Looper.getMainLooper())
            gpsListener = l
        } catch (e: SecurityException) {
            sink.error("permission", "Location permission missing", null)
        } catch (e: IllegalArgumentException) {
            sink.error("no_gps", "GPS provider unavailable", null)
        }
    }

    private fun stopGps(ctx: Context) {
        gpsListener?.let {
            val lm = ctx.getSystemService(Context.LOCATION_SERVICE) as LocationManager
            lm.removeUpdates(it)
        }
        gpsListener = null
    }
}
