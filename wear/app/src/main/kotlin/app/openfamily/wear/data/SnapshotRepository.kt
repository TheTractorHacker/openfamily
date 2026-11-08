package app.openfamily.wear.data

import android.content.Context
import androidx.wear.tiles.TileService
import androidx.wear.watchface.complications.datasource.ComplicationDataSourceUpdateRequester
import android.content.ComponentName
import app.openfamily.wear.logic.SessionGate
import app.openfamily.wear.tile.CircleTileService
import app.openfamily.wear.tile.NearestComplicationService
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * The last snapshot from the phone: held in memory for the UI and copied to
 * app-private storage so the watch can show it (with its age) when the phone
 * is out of range or this process was restarted. Nothing else is stored.
 */
object SnapshotRepository {
    private const val PREFS = "orbitly_snapshot"
    private const val KEY = "json"
    private const val KEY_SESSION = "session"

    private val _snapshot = MutableStateFlow<Snapshot?>(null)
    val snapshot: StateFlow<Snapshot?> = _snapshot.asStateFlow()

    private val _phoneConnected = MutableStateFlow(false)
    val phoneConnected: StateFlow<Boolean> = _phoneConnected.asStateFlow()

    /** Loads the stored copy once per process, before the first Data Layer event arrives. */
    fun restore(context: Context) {
        if (_snapshot.value != null) return
        val json = context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString(KEY, null) ?: return
        Snapshot.parse(json)?.let { if (_snapshot.value == null) _snapshot.value = it }
    }

    /** Called by the Data Layer service and by the activity's initial read. */
    fun accept(context: Context, json: String, session: String? = null) {
        val parsed = Snapshot.parse(json) ?: return
        val app = context.applicationContext
        val prefs = app.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        // Another login than the stored data's: it is the previous user's, drop it first.
        if (SessionGate.mustWipe(prefs.getString(KEY_SESSION, null), session)) {
            prefs.edit().remove(KEY).apply()
            _snapshot.value = null
            _external.value = null
        }
        SessionGate.next(prefs.getString(KEY_SESSION, null), session)?.let { prefs.edit().putString(KEY_SESSION, it).apply() }
        // A signed-out phone sends an empty snapshot: forget everything on this watch too.
        if (!parsed.signedIn) {
            app.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().remove(KEY).apply()
            _snapshot.value = parsed
        } else {
            app.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putString(KEY, json).apply()
            _snapshot.value = parsed
        }
        refreshSurfaces(app)
    }

    fun clear(context: Context) {
        val app = context.applicationContext
        app.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().remove(KEY).remove(KEY_SESSION).apply()
        _snapshot.value = null
        refreshSurfaces(app)
    }

    private val _external = MutableStateFlow<Snapshot.CommandResult?>(null)

    /** An answer that came straight from the phone's listener, outside the snapshot. */
    val externalResult: StateFlow<Snapshot.CommandResult?> = _external.asStateFlow()

    fun postExternalResult(r: Snapshot.CommandResult) {
        _external.value = r
    }

    fun setPhoneConnected(connected: Boolean) {
        _phoneConnected.value = connected
    }

    /** Tile and complication show the same data; ask the system to redraw them. */
    private fun refreshSurfaces(app: Context) {
        runCatching { TileService.getUpdater(app).requestUpdate(CircleTileService::class.java) }
        runCatching {
            ComplicationDataSourceUpdateRequester
                .create(app, ComponentName(app, NearestComplicationService::class.java))
                .requestUpdateAll()
        }
    }
}
