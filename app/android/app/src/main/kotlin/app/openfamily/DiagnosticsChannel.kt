package app.openfamily

import android.app.ActivityManager
import android.app.usage.UsageStatsManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray

/**
 * Read-only phone health facts and OEM settings deep links for the in-app
 * "Why isn't my phone reporting?" screen. Nothing here reads a location, a
 * contact or any credential. Never throws into Dart.
 *
 * Channel "app.openfamily/diagnostics":
 *   state            -> { ignoringBatteryOptimizations, powerSave, backgroundRestricted,
 *                         standbyBucket (API 28+, else null),
 *                         manufacturer, brand, model, sdk, release }
 *   exitReasons      -> the last 8 entries of Android's record of why this app's processes ended
 *                       (ApplicationExitInfo, API 30+; null before that): a list of
 *                       { timestamp, reason, importance, status, processName, description }.
 *                       Numbers and Android's own short text only, no user data.
 *   trackingJournal  -> the tracking service's own journal (written by the background_locator_2
 *                       plugin's NativeJournal): a list of { t, e, d, n, l }.
 *   openOemSettings  -> { kind: "autostart" | "battery" }  returns the label of the
 *                       screen that opened, or null when no OEM screen exists
 *                       (the Dart side then falls back to the stock Settings page).
 */
class DiagnosticsChannel(private val context: Context) {
    fun handle(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "state" -> result.success(state())
                "exitReasons" -> result.success(exitReasons())
                "trackingJournal" -> result.success(trackingJournal())
                "openOemSettings" -> {
                    val kind = (call.arguments as? Map<*, *>)?.get("kind") as? String ?: "battery"
                    result.success(openOem(kind))
                }
                else -> result.notImplemented()
            }
        } catch (_: Throwable) {
            result.success(null)
        }
    }

    private fun state(): Map<String, Any?> {
        val pm = context.getSystemService(Context.POWER_SERVICE) as PowerManager
        val am = context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        return mapOf(
            "ignoringBatteryOptimizations" to pm.isIgnoringBatteryOptimizations(context.packageName),
            "powerSave" to pm.isPowerSaveMode,
            "backgroundRestricted" to (Build.VERSION.SDK_INT >= 28 && am.isBackgroundRestricted),
            "standbyBucket" to standbyBucket(),
            "manufacturer" to Build.MANUFACTURER,
            "brand" to Build.BRAND,
            "model" to Build.MODEL,
            "sdk" to Build.VERSION.SDK_INT,
            "release" to Build.VERSION.RELEASE,
        )
    }

    /** UsageStatsManager.STANDBY_BUCKET_* of this app (10 active ... 50 never), or null before Android 9. */
    private fun standbyBucket(): Int? {
        if (Build.VERSION.SDK_INT < 28) return null
        return try {
            (context.getSystemService(Context.USAGE_STATS_SERVICE) as? UsageStatsManager)?.appStandbyBucket
        } catch (_: Throwable) {
            null
        }
    }

    /** The last 8 process exits of this package (why Android ended it), newest first. Null before Android 11. */
    private fun exitReasons(): List<Map<String, Any?>>? {
        if (Build.VERSION.SDK_INT < 30) return null
        val am = context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        val out = ArrayList<Map<String, Any?>>()
        for (e in am.getHistoricalProcessExitReasons(context.packageName, 0, 8)) {
            out.add(
                mapOf(
                    "timestamp" to e.timestamp,
                    "reason" to e.reason,
                    "importance" to e.importance,
                    "status" to e.status,
                    "processName" to e.processName,
                    "description" to e.description,
                ),
            )
        }
        return out
    }

    /**
     * The service's own journal. The same file and key as NativeJournal in the background_locator_2
     * plugin (the app module cannot see the plugin's classes): keep the two in step.
     */
    private fun trackingJournal(): List<Map<String, Any?>> {
        val raw = context.getSharedPreferences("orbitly_tracking_journal", Context.MODE_PRIVATE)
            .getString("lines", null) ?: return emptyList()
        val lines = JSONArray(raw)
        val out = ArrayList<Map<String, Any?>>()
        for (i in 0 until lines.length()) {
            val o = lines.optJSONObject(i) ?: continue
            out.add(
                mapOf(
                    "t" to o.optLong("t"),
                    "e" to o.optString("e"),
                    "d" to o.optString("d"),
                    "n" to o.optInt("n", 1),
                    "l" to (if (o.has("l")) o.optLong("l") else null),
                ),
            )
        }
        return out
    }

    private data class Target(val label: String, val pkg: String, val cls: String)

    private fun targets(kind: String): List<Target> {
        val m = (Build.MANUFACTURER + " " + Build.BRAND).lowercase()
        val auto = kind == "autostart"
        return when {
            m.contains("xiaomi") || m.contains("redmi") || m.contains("poco") -> if (auto) listOf(
                Target("Xiaomi Autostart", "com.miui.securitycenter", "com.miui.permcenter.autostart.AutoStartManagementActivity"),
            ) else listOf(
                Target("Xiaomi Battery saver", "com.miui.powerkeeper", "com.miui.powerkeeper.ui.HiddenAppsConfigActivity"),
            )
            m.contains("samsung") -> listOf(
                Target("Samsung Device care battery", "com.samsung.android.lool", "com.samsung.android.sm.battery.ui.BatteryActivity"),
                Target("Samsung Device care battery", "com.samsung.android.lool", "com.samsung.android.sm.ui.battery.BatteryActivity"),
                Target("Samsung Smart Manager battery", "com.samsung.android.sm", "com.samsung.android.sm.ui.battery.BatteryActivity"),
            )
            m.contains("oneplus") -> if (auto) listOf(
                Target("OnePlus Auto-launch", "com.oneplus.security", "com.oneplus.security.chainlaunch.view.ChainLaunchAppListActivity"),
            ) else listOf(
                Target("OnePlus Battery optimization", "com.android.settings", "com.android.settings.Settings\$HighPowerApplicationsActivity"),
            )
            m.contains("huawei") || m.contains("honor") -> if (auto) listOf(
                Target("Huawei App launch", "com.huawei.systemmanager", "com.huawei.systemmanager.startupmgr.ui.StartupNormalAppListActivity"),
            ) else listOf(
                Target("Huawei Protected apps", "com.huawei.systemmanager", "com.huawei.systemmanager.optimize.process.ProtectActivity"),
            )
            m.contains("oppo") || m.contains("realme") -> if (auto) listOf(
                Target("Oppo Startup manager", "com.coloros.safecenter", "com.coloros.safecenter.permission.startup.StartupAppListActivity"),
                Target("Oppo Startup manager", "com.oppo.safe", "com.oppo.safe.permission.startup.StartupAppListActivity"),
            ) else listOf(
                Target("Oppo Battery", "com.coloros.oppoguardelf", "com.coloros.powermanager.fuelgaue.PowerUsageModelActivity"),
                Target("Oppo Battery", "com.oplus.battery", "com.oplus.powermanager.fuelgaue.PowerUsageModelActivity"),
            )
            else -> emptyList()
        }
    }

    private fun openOem(kind: String): String? {
        for (t in targets(kind)) {
            val intent = Intent().apply {
                component = ComponentName(t.pkg, t.cls)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                putExtra("package_name", context.packageName)
                putExtra("package_label", "Orbitly")
            }
            if (intent.resolveActivity(context.packageManager) == null) continue
            try {
                context.startActivity(intent)
                return t.label
            } catch (_: Throwable) {
                // Vendor activities are not stable API: try the next candidate.
            }
        }
        return null
    }
}
