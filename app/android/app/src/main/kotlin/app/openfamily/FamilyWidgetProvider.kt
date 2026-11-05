package app.openfamily

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.view.View
import android.widget.RemoteViews
import org.json.JSONObject

/**
 * Home-screen widget listing up to 6 family members from a display-only
 * snapshot (names, status strings, battery) written by the Flutter app into
 * the "openfamily_widget" SharedPreferences. No tokens or coordinates.
 * Every entry point is wrapped so widget problems can never crash the app.
 */
class FamilyWidgetProvider : AppWidgetProvider() {

    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
        for (id in ids) render(context, manager, id)
    }

    override fun onAppWidgetOptionsChanged(
        context: Context, manager: AppWidgetManager, id: Int, newOptions: android.os.Bundle?
    ) {
        render(context, manager, id)
    }

    override fun onDeleted(context: Context, ids: IntArray) {
        // Last widget removed: drop any stored names.
        if (!hasWidgets(context)) clear(context)
    }

    companion object {
        private const val PREFS = "openfamily_widget"
        private const val KEY = "snapshot"
        private val ROWS = intArrayOf(R.id.row0, R.id.row1, R.id.row2, R.id.row3, R.id.row4, R.id.row5)
        private val INITIALS = intArrayOf(R.id.ini0, R.id.ini1, R.id.ini2, R.id.ini3, R.id.ini4, R.id.ini5)
        private val CIRC = intArrayOf(R.id.circ0, R.id.circ1, R.id.circ2, R.id.circ3, R.id.circ4, R.id.circ5)
        private val NAMES = intArrayOf(R.id.name0, R.id.name1, R.id.name2, R.id.name3, R.id.name4, R.id.name5)
        private val STATUS = intArrayOf(R.id.status0, R.id.status1, R.id.status2, R.id.status3, R.id.status4, R.id.status5)
        private val BATT = intArrayOf(R.id.batt0, R.id.batt1, R.id.batt2, R.id.batt3, R.id.batt4, R.id.batt5)

        fun ids(context: Context): IntArray = try {
            AppWidgetManager.getInstance(context)
                .getAppWidgetIds(ComponentName(context, FamilyWidgetProvider::class.java))
        } catch (_: Throwable) { IntArray(0) }

        fun hasWidgets(context: Context): Boolean = ids(context).isNotEmpty()

        /** Stores [json] only if a widget instance exists. Returns whether stored. */
        fun write(context: Context, json: String): Boolean {
            return try {
                if (!hasWidgets(context)) {
                    clear(context)
                    return false
                }
                context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                    .edit().putString(KEY, json).apply()
                refresh(context)
                true
            } catch (_: Throwable) { false }
        }

        fun clear(context: Context) {
            try {
                context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().clear().apply()
                refresh(context)
            } catch (_: Throwable) {}
        }

        private fun refresh(context: Context) {
            try {
                val mgr = AppWidgetManager.getInstance(context)
                for (id in ids(context)) render(context, mgr, id)
            } catch (_: Throwable) {}
        }

        private fun render(context: Context, mgr: AppWidgetManager, id: Int) {
            try {
                val views = RemoteViews(context.packageName, R.layout.family_widget)
                val launch = context.packageManager.getLaunchIntentForPackage(context.packageName)
                if (launch != null) {
                    val pi = PendingIntent.getActivity(
                        context, 0, launch,
                        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
                    )
                    views.setOnClickPendingIntent(R.id.widget_root, pi)
                }
                // Rows that fit: ~72dp per row after the header.
                val minH = mgr.getAppWidgetOptions(id).getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_HEIGHT, 110)
                val fit = ((minH - 36) / 44).coerceIn(1, ROWS.size)
                var shown = 0
                val raw = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString(KEY, null)
                if (raw != null) {
                    val members = JSONObject(raw).optJSONArray("members")
                    if (members != null) {
                        shown = minOf(members.length(), fit)
                        for (i in 0 until shown) {
                            val m = members.getJSONObject(i)
                            views.setViewVisibility(ROWS[i], View.VISIBLE)
                            views.setTextViewText(INITIALS[i], m.optString("initials", "?"))
                            views.setTextViewText(NAMES[i], m.optString("name"))
                            views.setTextViewText(STATUS[i], m.optString("status"))
                            views.setTextViewText(BATT[i], m.optInt("battery", 0).toString() + "%")
                            val c = m.optLong("color", 0xFF607D8BL).toInt()
                            views.setInt(CIRC[i], "setColorFilter", c)
                        }
                    }
                }
                for (i in shown until ROWS.size) views.setViewVisibility(ROWS[i], View.GONE)
                views.setViewVisibility(R.id.empty, if (shown == 0) View.VISIBLE else View.GONE)
                mgr.updateAppWidget(id, views)
            } catch (_: Throwable) {
                try {
                    mgr.updateAppWidget(id, RemoteViews(context.packageName, R.layout.family_widget))
                } catch (_: Throwable) {}
            }
        }
    }
}
