package app.openfamily.driving_native

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.res.Configuration
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.app.UiModeManager
import android.os.Handler
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
    private var contextChannel: EventChannel? = null
    private var proxListener: SensorEventListener? = null
    private var ctxHandler: Handler? = null
    private var ctxPoll: Runnable? = null

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
        contextChannel = EventChannel(binding.binaryMessenger, "app.openfamily/driving_native/context")
        contextChannel?.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, sink: EventChannel.EventSink) {
                startContext(ctx, sink)
            }

            override fun onCancel(arguments: Any?) {
                stopContext(ctx)
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
            stopContext(it)
        }
        contextChannel?.setStreamHandler(null)
        contextChannel = null
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

    // ---- phone context: proximity + call/audio route (no permissions) ----

    private var lastCtxKey: String? = null
    private var proximity = "unknown"

    private fun startContext(ctx: Context, sink: EventChannel.EventSink) {
        stopContext(ctx)
        lastCtxKey = null
        proximity = "unknown"
        val sm = ctx.getSystemService(Context.SENSOR_SERVICE) as SensorManager
        val prox = sm.getDefaultSensor(Sensor.TYPE_PROXIMITY)
        if (prox != null) {
            val l = object : SensorEventListener {
                override fun onSensorChanged(e: SensorEvent) {
                    val near = e.values[0] < minOf(prox.maximumRange, 5f)
                    val p = if (near) "near" else "far"
                    if (p != proximity) {
                        proximity = p
                        emitContext(ctx, sink)
                    }
                }

                override fun onAccuracyChanged(s: Sensor?, accuracy: Int) {}
            }
            // On-change sensor: costs next to nothing, unlike a streaming one.
            sm.registerListener(l, prox, SensorManager.SENSOR_DELAY_NORMAL)
            proxListener = l
        }
        val h = Handler(Looper.getMainLooper())
        val poll = object : Runnable {
            override fun run() {
                emitContext(ctx, sink)
                h.postDelayed(this, 2000L)
            }
        }
        ctxHandler = h
        ctxPoll = poll
        poll.run()
    }

    private fun stopContext(ctx: Context) {
        proxListener?.let {
            val sm = ctx.getSystemService(Context.SENSOR_SERVICE) as SensorManager
            sm.unregisterListener(it)
        }
        proxListener = null
        ctxPoll?.let { ctxHandler?.removeCallbacks(it) }
        ctxPoll = null
        ctxHandler = null
    }

    private fun emitContext(ctx: Context, sink: EventChannel.EventSink) {
        val am = ctx.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        val mode = when (am.mode) {
            AudioManager.MODE_IN_CALL -> "call"
            AudioManager.MODE_IN_COMMUNICATION -> "voip"
            else -> "none"
        }
        val ui = ctx.getSystemService(Context.UI_MODE_SERVICE) as UiModeManager
        val car = ui.currentModeType == Configuration.UI_MODE_TYPE_CAR
        val route = if (mode == "none") "unknown" else callRoute(am)
        val key = "$proximity|$mode|$route|$car"
        if (key == lastCtxKey) return
        lastCtxKey = key
        sink.success(
            mapOf(
                "t" to System.currentTimeMillis(),
                "proximity" to proximity,
                "mode" to mode,
                "route" to route,
                "car" to car,
            )
        )
    }

    /**
     * Where the call audio goes. Uses the communication device (API 31+) or
     * the active routing flags; AudioManager.getDevices() needs no Bluetooth
     * permission. Heuristic: a connected car/Bluetooth/wired output during a
     * call is taken as the route unless the speaker is explicitly on.
     */
    @Suppress("DEPRECATION")
    private fun callRoute(am: AudioManager): String {
        if (Build.VERSION.SDK_INT >= 31) {
            am.communicationDevice?.let { return typeToRoute(it.type) }
        }
        if (am.isSpeakerphoneOn) return "speaker"
        if (am.isBluetoothScoOn) return "bluetooth"
        if (am.isWiredHeadsetOn) return "wired"
        if (Build.VERSION.SDK_INT >= 23) {
            try {
                for (d in am.getDevices(AudioManager.GET_DEVICES_OUTPUTS)) {
                    val r = typeToRoute(d.type)
                    if (r == "bluetooth" || r == "wired" || r == "car") return r
                }
            } catch (_: Exception) {
            }
        }
        return "earpiece"
    }

    private fun typeToRoute(type: Int): String = when (type) {
        AudioDeviceInfo.TYPE_BUILTIN_EARPIECE -> "earpiece"
        AudioDeviceInfo.TYPE_BUILTIN_SPEAKER -> "speaker"
        AudioDeviceInfo.TYPE_BLUETOOTH_SCO,
        AudioDeviceInfo.TYPE_BLUETOOTH_A2DP,
        AudioDeviceInfo.TYPE_HEARING_AID -> "bluetooth"
        AudioDeviceInfo.TYPE_WIRED_HEADSET,
        AudioDeviceInfo.TYPE_WIRED_HEADPHONES,
        AudioDeviceInfo.TYPE_USB_HEADSET -> "wired"
        AudioDeviceInfo.TYPE_BUS,
        AudioDeviceInfo.TYPE_USB_DEVICE,
        AudioDeviceInfo.TYPE_USB_ACCESSORY -> "car"
        else -> if (Build.VERSION.SDK_INT >= 31 && type == AudioDeviceInfo.TYPE_BLE_HEADSET) "bluetooth" else "unknown"
    }
}
