package yukams.app.background_locator_2

import android.app.*
import android.Manifest
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.PowerManager
import android.util.Log
import androidx.core.app.NotificationCompat
import android.content.pm.PackageManager
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import yukams.app.background_locator_2.pluggables.DisposePluggable
import yukams.app.background_locator_2.pluggables.InitPluggable
import yukams.app.background_locator_2.pluggables.Pluggable
import yukams.app.background_locator_2.provider.*
import com.google.android.gms.location.LocationRequest
import java.util.HashMap
import androidx.core.app.ActivityCompat

// How long a single background location delivery may hold the partial wake
// lock so the Dart callback can complete its HTTP POST (http timeout is 15s).
// Kept below the 60s location interval so the CPU can sleep between updates.
private const val UPDATE_WAKE_LOCK_MS = 30_000L

// Requests at or below this interval (drive mode / live boost) are never
// downgraded to the stationary profile.
private const val FAST_REQUEST_MS = 10_000L

class IsolateHolderService : MethodChannel.MethodCallHandler, LocationUpdateListener, Service() {
    companion object {
        @JvmStatic
        val ACTION_SHUTDOWN = "SHUTDOWN"

        @JvmStatic
        val ACTION_START = "START"

        @JvmStatic
        val ACTION_UPDATE_NOTIFICATION = "UPDATE_NOTIFICATION"

        @JvmStatic
        private val WAKELOCK_TAG = "IsolateHolderService::WAKE_LOCK"

        @JvmStatic
        var backgroundEngine: FlutterEngine? = null

        @JvmStatic
        private val notificationId = 1

        @JvmStatic
        var isServiceRunning = false

        @JvmStatic
        var isServiceInitialized = false

        /**
         * The live service instance, if any. Receivers run in the same process
         * but cannot (and must not — background service-start restrictions)
         * rebind the service via intents, so they talk to this reference
         * directly. Null when the tracking service is not running.
         */
        @JvmStatic
        internal var activeInstance: IsolateHolderService? = null

        fun getBinaryMessenger(context: Context?): BinaryMessenger? {
            val messenger = backgroundEngine?.dartExecutor?.binaryMessenger
            return messenger
                ?: if (context != null) {
                    backgroundEngine = FlutterEngine(context)
                    backgroundEngine?.dartExecutor?.binaryMessenger
                }else{
                    messenger
                }
        }

        /**
         * Forwards a liveness-alarm tick into the Dart background isolate,
         * which POSTs a heartbeat (no location row, no GPS fix). No-op when
         * the engine or the registered heartbeat callback is missing: without
         * an active tracking session a bare liveness signal would be wrong.
         */
        @JvmStatic
        fun dispatchHeartbeat(context: Context?) {
            val appContext = context?.applicationContext ?: return
            if (backgroundEngine == null) return
            val callback = PreferencesManager.getCallbackHandle(
                appContext,
                Keys.HEARTBEAT_CALLBACK_HANDLE_KEY,
            ) ?: return
            val messenger = getBinaryMessenger(appContext) ?: return
            val channel = MethodChannel(messenger, Keys.BACKGROUND_CHANNEL_ID)
            Handler(appContext.mainLooper).post {
                channel.invokeMethod(
                    Keys.BCM_SEND_HEARTBEAT,
                    hashMapOf<Any, Any>(Keys.ARG_HEARTBEAT_CALLBACK to callback),
                )
            }
        }

        /** Entry point for movement-state transitions detected by
         *  [ActivityTransitionsReceiver]. */
        @JvmStatic
        internal fun applyMotionProfile(context: Context?, moving: Boolean) {
            activeInstance?.applyMotionProfileInternal(moving)
        }
    }

    private var notificationChannelName = "Flutter Locator Plugin"
    private var notificationTitle = "Start Location Tracking"
    private var notificationMsg = "Track location in background"
    private var notificationBigMsg =
        "Background location is on to keep the app up-tp-date with your location. This is required for main features to work properly when the app is not running."
    private var notificationIconColor = 0
    private var icon = 0
    private var locatorClient: BLLocationProvider? = null
    private val serviceHandler by lazy { Handler(mainLooper) }
    private var usingGoogleLocationClient = false
    private var googleFallbackRunnable: Runnable? = null
    private var wakeLock: PowerManager.WakeLock? = null
    internal lateinit var backgroundChannel: MethodChannel
    internal var context: Context? = null
    private var pluggables: ArrayList<Pluggable> = ArrayList()

    /** The location request the moving-profile was started with, kept so the
     *  stationary profile can restore it on the next movement transition. */
    private var activeRequest: LocationRequestOptions? = null

    /** Whether [locatorClient] is currently running the low-power stationary
     *  profile. Guards against redundant client churn on repeated events. */
    private var isStillProfile = false

    override fun onBind(intent: Intent?): IBinder? {
        return null
    }

    override fun onCreate() {
        super.onCreate()
        activeInstance = this
        startLocatorService(this)
        startForeground(notificationId, getNotification())
    }

    private fun start() {
        // Starting Service as foreground with a notification prevent service from closing
        val notification = getNotification()
        startForeground(notificationId, notification)

        // Keep "last seen" fresh even when no location fixes arrive (device
        // stationary / GPS deferred by the OS power manager).
        HeartbeatScheduler.schedule(this)

        // Track movement transitions so GPS sampling can drop to a slow,
        // low-power profile while stationary; the motion-sensor pipeline that
        // provides these transitions costs a fraction of continuous GPS.
        ActivityTransitionsManager.start(this)

        pluggables.forEach {
            context?.let { it1 -> it.onServiceStart(it1) }
        }
    }

    // This is a foreground *location* service, so the OS already lets it run
    // in the background. Holding a PARTIAL_WAKE_LOCK for the whole configured
    // wakeLockTime window (default 60 min) would keep the CPU awake
    // needlessly and drain the battery. Instead we hold a short-lived wake
    // lock only while a location is being delivered to the background isolate,
    // so its HTTP POST (15s timeout) is not interrupted, then release it. When
    // the user is stationary no updates arrive and the lock is not held at all.
    private fun holdWakeLockForUpdate() {
        val lock = wakeLock
            ?: (getSystemService(Context.POWER_SERVICE) as PowerManager)
                .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, WAKELOCK_TAG)
                .apply { setReferenceCounted(false) }
                .also { wakeLock = it }
        // acquire(timeout) auto-releases after the timeout; a subsequent update
        // simply renews it, so the CPU is never pinned for longer than needed.
        lock.acquire(UPDATE_WAKE_LOCK_MS)
    }

    private fun getNotification(): Notification {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            // Notification channel is available in Android O and up
            val channel = NotificationChannel(
                Keys.CHANNEL_ID, notificationChannelName,
                NotificationManager.IMPORTANCE_LOW
            )

            (getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager)
                .createNotificationChannel(channel)
        }

        val intent = Intent(this, getMainActivityClass(this))
        intent.action = Keys.NOTIFICATION_ACTION

        val pendingIntent: PendingIntent = PendingIntent.getActivity(
            this,
            1, intent, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )

        return NotificationCompat.Builder(this, Keys.CHANNEL_ID)
            .setContentTitle(notificationTitle)
            .setContentText(notificationMsg)
            .setStyle(
                NotificationCompat.BigTextStyle()
                    .bigText(notificationBigMsg)
            )
            .setSmallIcon(icon)
            .setColor(notificationIconColor)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setContentIntent(pendingIntent)
            .setOnlyAlertOnce(true) // so when data is updated don't make sound and alert in android 8.0+
            .setOngoing(true)
            .build()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        Log.e("IsolateHolderService", "onStartCommand => intent.action : ${intent?.action}")
        if(intent == null) {
            // The OS restarted the service after killing the process
            // (START_STICKY). Without re-registering the location client, the
            // heartbeat alarm, and the motion transitions here, the service
            // would sit alive but idle — reporting nothing — until the app
            // was next opened. That was the production cause of background
            // updates dying silently a while after the app was closed.
            if (ActivityCompat.checkSelfPermission(this, Manifest.permission.ACCESS_FINE_LOCATION) != PackageManager.PERMISSION_GRANTED
                || ActivityCompat.checkSelfPermission(this, Manifest.permission.ACCESS_COARSE_LOCATION) != PackageManager.PERMISSION_GRANTED) {
                Log.e("IsolateHolderService", "location permission missing after restart, stopping")
                stopSelf()
                return START_NOT_STICKY
            }
            if (!restartFromStoredSettings()) {
                stopSelf()
                return START_NOT_STICKY
            }
            return START_STICKY
        }

        when {
            ACTION_SHUTDOWN == intent?.action -> {
                isServiceRunning = false
                shutdownHolderService()
            }
            ACTION_START == intent?.action -> {
                if (isServiceRunning) {
                    isServiceRunning = false
                    shutdownHolderService()
                }

                if (!isServiceRunning) {
                    isServiceRunning = true
                    startHolderService(intent)
                }
            }
            ACTION_UPDATE_NOTIFICATION == intent?.action -> {
                if (isServiceRunning) {
                    updateNotification(intent)
                }
            }
            Keys.ACTION_HEARTBEAT == intent?.action -> {
                if (isServiceRunning) {
                    dispatchHeartbeat(this)
                }
            }
            Keys.ACTION_ACTIVITY_CHANGE == intent?.action -> {
                if (isServiceRunning) {
                    applyMotionProfileInternal(
                        intent.getBooleanExtra(Keys.EXTRA_IS_MOVING, false),
                    )
                }
            }
        }

        return START_STICKY
    }

    private fun startHolderService(intent: Intent) {
        Log.e("IsolateHolderService", "startHolderService")
        notificationChannelName =
            intent.getStringExtra(Keys.SETTINGS_ANDROID_NOTIFICATION_CHANNEL_NAME).toString()
        notificationTitle =
            intent.getStringExtra(Keys.SETTINGS_ANDROID_NOTIFICATION_TITLE).toString()
        notificationMsg = intent.getStringExtra(Keys.SETTINGS_ANDROID_NOTIFICATION_MSG).toString()
        notificationBigMsg =
            intent.getStringExtra(Keys.SETTINGS_ANDROID_NOTIFICATION_BIG_MSG).toString()
        val iconNameDefault = "ic_launcher"
        var iconName = intent.getStringExtra(Keys.SETTINGS_ANDROID_NOTIFICATION_ICON)
        if (iconName == null || iconName.isEmpty()) {
            iconName = iconNameDefault
        }
        icon = resources.getIdentifier(iconName, "mipmap", packageName)
        notificationIconColor =
            intent.getLongExtra(Keys.SETTINGS_ANDROID_NOTIFICATION_ICON_COLOR, 0).toInt()

        val request = getLocationRequest(intent)
        activeRequest = request
        isStillProfile = false
        context?.let { startLocationClient(it, request) }

        // Fill pluggable list
        if (intent.hasExtra(Keys.SETTINGS_INIT_PLUGGABLE)) {
            pluggables.add(InitPluggable())
        }

        if (intent.hasExtra(Keys.SETTINGS_DISPOSABLE_PLUGGABLE)) {
            pluggables.add(DisposePluggable())
        }

        start()
    }

    /**
     * Re-arms tracking after an OS-initiated restart (null-intent
     * onStartCommand), using the settings persisted by the last registration.
     * Mirrors [startHolderService]: notification chrome, location client,
     * heartbeat alarm, and movement-transition registration. Returns false
     * when nothing was ever registered on this device.
     */
    private fun restartFromStoredSettings(): Boolean {
        Log.e("IsolateHolderService", "restarting from stored settings")
        val settings = PreferencesManager.getSettings(this)[Keys.ARG_SETTINGS] as? Map<*, *>
            ?: return false
        val intervalSeconds = (settings[Keys.SETTINGS_INTERVAL] as? Int) ?: 0
        if (intervalSeconds <= 0) return false // never registered here

        notificationChannelName =
            (settings[Keys.SETTINGS_ANDROID_NOTIFICATION_CHANNEL_NAME] as? String) ?: notificationChannelName
        notificationTitle =
            (settings[Keys.SETTINGS_ANDROID_NOTIFICATION_TITLE] as? String) ?: notificationTitle
        notificationMsg =
            (settings[Keys.SETTINGS_ANDROID_NOTIFICATION_MSG] as? String) ?: notificationMsg
        notificationBigMsg =
            (settings[Keys.SETTINGS_ANDROID_NOTIFICATION_BIG_MSG] as? String) ?: notificationBigMsg
        val iconName = (settings[Keys.SETTINGS_ANDROID_NOTIFICATION_ICON] as? String)
            .takeUnless { it.isNullOrEmpty() } ?: "ic_launcher"
        icon = resources.getIdentifier(iconName, "mipmap", packageName)
        notificationIconColor =
            (settings[Keys.SETTINGS_ANDROID_NOTIFICATION_ICON_COLOR] as? Long)?.toInt() ?: 0

        val request = LocationRequestOptions(
            interval = intervalSeconds * 1000L,
            accuracy = getAccuracy((settings[Keys.SETTINGS_ACCURACY] as? Int) ?: 4),
            distanceFilter = (settings[Keys.SETTINGS_DISTANCE_FILTER] as? Double)?.toFloat() ?: 0f,
        )
        activeRequest = request
        isStillProfile = false
        isServiceRunning = true
        startLocationClient(this, request)
        start()
        return true
    }

    private fun shutdownHolderService() {
        Log.e("IsolateHolderService", "shutdownHolderService")
        wakeLock?.takeIf { it.isHeld }?.release()
        wakeLock = null

        HeartbeatScheduler.cancel(this)
        ActivityTransitionsManager.stop(this)
        activeRequest = null
        isStillProfile = false

        googleFallbackRunnable?.let { serviceHandler.removeCallbacks(it) }
        googleFallbackRunnable = null
        usingGoogleLocationClient = false

        locatorClient?.removeLocationUpdates()
        stopForeground(true)
        stopSelf()

        pluggables.forEach {
            context?.let { it1 -> it.onServiceDispose(it1) }
        }
    }

    private fun updateNotification(intent: Intent) {
        Log.e("IsolateHolderService", "updateNotification")
        if (intent.hasExtra(Keys.SETTINGS_ANDROID_NOTIFICATION_TITLE)) {
            notificationTitle =
                intent.getStringExtra(Keys.SETTINGS_ANDROID_NOTIFICATION_TITLE).toString()
        }

        if (intent.hasExtra(Keys.SETTINGS_ANDROID_NOTIFICATION_MSG)) {
            notificationMsg =
                intent.getStringExtra(Keys.SETTINGS_ANDROID_NOTIFICATION_MSG).toString()
        }

        if (intent.hasExtra(Keys.SETTINGS_ANDROID_NOTIFICATION_BIG_MSG)) {
            notificationBigMsg =
                intent.getStringExtra(Keys.SETTINGS_ANDROID_NOTIFICATION_BIG_MSG).toString()
        }

        val notification = getNotification()
        val notificationManager =
            getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        notificationManager.notify(notificationId, notification)
    }

    private fun getMainActivityClass(context: Context): Class<*>? {
        val packageName = context.packageName
        val launchIntent = context.packageManager.getLaunchIntentForPackage(packageName)
        val className = launchIntent?.component?.className ?: return null

        return try {
            Class.forName(className)
        } catch (e: ClassNotFoundException) {
            e.printStackTrace()
            null
        }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                Keys.METHOD_SERVICE_INITIALIZED -> {
                    isServiceRunning = true
                }
                else -> result.notImplemented()
            }

            result.success(null)
        } catch (e: Exception) {

        }
    }

    override fun onDestroy() {
        isServiceRunning = false
        activeInstance = null
        super.onDestroy()
    }


    /**
     * Swaps between the moving and stationary location profiles based on
     * movement transitions from the activity-recognition pipeline.
     *
     * Stationary profile: slow interval, balanced-power priority, no distance
     * filter — one cheap periodic fix keeps the server's stationary-dedup
     * path fed so liveness never goes quiet. Moving profile: the user's
     * configured request. No-op when the requested state is already active.
     */
    @Synchronized
    private fun applyMotionProfileInternal(moving: Boolean) {
        activityMoving = moving
        val base = activeRequest ?: return
        if (moving == !isStillProfile) return

        val profile = if (moving) {
            base
        } else {
            LocationRequestOptions(
                interval = maxOf(base.interval, ActivityTransitionsManager.STILL_INTERVAL_MS),
                accuracy = LocationRequest.PRIORITY_BALANCED_POWER_ACCURACY,
                distanceFilter = 0f,
            )
        }
        isStillProfile = !moving
        Log.d("IsolateHolderService", "applying ${if (moving) "moving" else "stationary"} location profile")

        googleFallbackRunnable?.let { serviceHandler.removeCallbacks(it) }
        googleFallbackRunnable = null
        usingGoogleLocationClient = false
        try {
            locatorClient?.removeLocationUpdates()
        } catch (_: Exception) {
            // The previous client may not have registered a callback.
        }

        context?.let { startLocationClient(it, profile) }
    }

    /** Last movement classification from activity recognition (true until a
     *  STILL transition is seen). */
    private var activityMoving = true

    /**
     * Adaptive cadence entry point (called from Dart through the plugin
     * channel): replaces the configured request with a new interval /
     * displacement filter / accuracy and re-requests location updates, without
     * restarting the service. A fast request (<= [FAST_REQUEST_MS], i.e. drive
     * or live boost) always runs as-is, even if activity recognition says
     * STILL; a slow request keeps the low-power stationary profile when the
     * device is classified STILL, so the existing stationary behaviour and
     * the liveness alarm are unchanged.
     */
    @Synchronized
    fun updateLocationRequest(intervalMs: Long, distanceFilter: Float, highAccuracy: Boolean): Boolean {
        if (!isServiceRunning) return false
        val ctx = context ?: return false
        val base = LocationRequestOptions(
            interval = intervalMs,
            accuracy = if (highAccuracy) LocationRequest.PRIORITY_HIGH_ACCURACY
            else LocationRequest.PRIORITY_BALANCED_POWER_ACCURACY,
            distanceFilter = distanceFilter,
        )
        activeRequest = base
        val still = intervalMs > FAST_REQUEST_MS && !activityMoving
        val profile = if (still) {
            LocationRequestOptions(
                interval = maxOf(base.interval, ActivityTransitionsManager.STILL_INTERVAL_MS),
                accuracy = LocationRequest.PRIORITY_BALANCED_POWER_ACCURACY,
                distanceFilter = 0f,
            )
        } else {
            base
        }
        isStillProfile = still
        googleFallbackRunnable?.let { serviceHandler.removeCallbacks(it) }
        googleFallbackRunnable = null
        usingGoogleLocationClient = false
        try {
            locatorClient?.removeLocationUpdates()
        } catch (_: Exception) {
            // The previous client may not have registered a callback.
        }
        startLocationClient(ctx, profile)
        return true
    }

    private fun startLocationClient(context: Context, request: LocationRequestOptions) {        when (PreferencesManager.getLocationClient(context)) {
            LocationClient.Google -> {
                try {
                    val googleClient = GoogleLocationProviderClient(context, this) { error ->
                        Log.w(
                            "IsolateHolderService",
                            "Google location request failed; using Android LocationManager",
                            error
                        )
                        fallBackToAndroid(request)
                    }
                    locatorClient = googleClient
                    usingGoogleLocationClient = true
                    googleClient.requestLocationUpdates(request)
                    scheduleSilentGoogleFallback(request)
                } catch (error: Exception) {
                    Log.w(
                        "IsolateHolderService",
                        "Google location unavailable; using Android LocationManager",
                        error
                    )
                    fallBackToAndroid(request)
                }
            }
            LocationClient.Android -> {
                usingGoogleLocationClient = false
                locatorClient = AndroidLocationProviderClient(context, this).also {
                    it.requestLocationUpdates(request)
                }
            }
        }
    }

    /**
     * Fused Location can be present but unusable (for example when Google Play
     * Services is absent or its location permission is unavailable). Switch
     * the already-running foreground service to Android's platform GPS/network
     * providers instead of silently running without updates.
     */
    @Synchronized
    private fun fallBackToAndroid(request: LocationRequestOptions) {
        if (locatorClient is AndroidLocationProviderClient) return
        googleFallbackRunnable?.let { serviceHandler.removeCallbacks(it) }
        googleFallbackRunnable = null
        usingGoogleLocationClient = false
        try {
            locatorClient?.removeLocationUpdates()
        } catch (_: Exception) {
            // The failed Google client may not have registered a callback.
        }
        locatorClient = AndroidLocationProviderClient(this, this).also {
            it.requestLocationUpdates(request)
        }
    }

    /** Some Fused Location implementations accept the request but never call
     * either success or failure. If no first fix arrives, use AOSP after one
     * configured interval plus a small grace period. */
    private fun scheduleSilentGoogleFallback(request: LocationRequestOptions) {
        googleFallbackRunnable?.let { serviceHandler.removeCallbacks(it) }
        val runnable = Runnable {
            if (usingGoogleLocationClient) {
                Log.w(
                    "IsolateHolderService",
                    "Google location produced no first update; using Android LocationManager"
                )
                fallBackToAndroid(request)
            }
        }
        googleFallbackRunnable = runnable
        val delayMs = (request.interval + 15_000L).coerceIn(30_000L, 120_000L)
        serviceHandler.postDelayed(runnable, delayMs)
    }

    override fun onLocationUpdated(location: HashMap<Any, Any>?) {
        try {
            if (usingGoogleLocationClient) {
                googleFallbackRunnable?.let { serviceHandler.removeCallbacks(it) }
                googleFallbackRunnable = null
                usingGoogleLocationClient = false
            }
            context?.let {
                FlutterInjector.instance().flutterLoader().ensureInitializationComplete(
                    it, null
                )
            }

            //https://github.com/flutter/plugins/pull/1641
            //https://github.com/flutter/flutter/issues/36059
            //https://github.com/flutter/plugins/pull/1641/commits/4358fbba3327f1fa75bc40df503ca5341fdbb77d
            // new version of flutter can not invoke method from background thread
            if (location != null) {
                val callback =
                    context?.let {
                        PreferencesManager.getCallbackHandle(
                            it,
                            Keys.CALLBACK_HANDLE_KEY
                        )
                    } as Long

                // Attach the latest activity-recognition classification so the
                // report carries motion_state without the Dart isolate reading
                // cross-file shared preferences (which never worked — the two
                // sides used different prefs files).
                location[Keys.EXTRA_MOTION_STATE] =
                    context?.let { PreferencesManager.getMotionState(it) } ?: ""

                val result: HashMap<Any, Any> =
                    hashMapOf(
                        Keys.ARG_CALLBACK to callback,
                        Keys.ARG_LOCATION to location
                    )

                holdWakeLockForUpdate()
                sendLocationEvent(result)
            }
        } catch (e: Exception) {

        }
    }

    private fun sendLocationEvent(result: HashMap<Any, Any>) {
        //https://github.com/flutter/plugins/pull/1641
        //https://github.com/flutter/flutter/issues/36059
        //https://github.com/flutter/plugins/pull/1641/commits/4358fbba3327f1fa75bc40df503ca5341fdbb77d
        // new version of flutter can not invoke method from background thread

        if (backgroundEngine != null) {
            context?.let {
                val backgroundChannel =
                    MethodChannel(
                        getBinaryMessenger(it)!!,
                        Keys.BACKGROUND_CHANNEL_ID
                    )
                Handler(it.mainLooper)
                    .post {
                        Log.d("plugin", "sendLocationEvent $result")
                        backgroundChannel.invokeMethod(Keys.BCM_SEND_LOCATION, result)
                    }
            }
        }
    }
}
