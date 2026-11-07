package app.openfamily

import android.app.ActivityManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Read-only phone health facts and OEM settings deep links for the in-app
 * "Why isn't my phone reporting?" screen. Nothing here reads a location, a
 * contact or any credential. Never throws into Dart.
 *
 * Channel "app.openfamily/diagnostics":
 *   state            -> { ignoringBatteryOptimizations, powerSave, backgroundRestricted,
 *                         manufacturer, brand, model, sdk, release }
 *   openOemSettings  -> { kind: "autostart" | "battery" }  returns the label of the
 *                       screen that opened, or null when no OEM screen exists
 *                       (the Dart side then falls back to the stock Settings page).
 */
class DiagnosticsChannel(private val context: Context) {
    fun handle(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "state" -> result.success(state())
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
            "manufacturer" to Build.MANUFACTURER,
            "brand" to Build.BRAND,
            "model" to Build.MODEL,
            "sdk" to Build.VERSION.SDK_INT,
            "release" to Build.VERSION.RELEASE,
        )
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
