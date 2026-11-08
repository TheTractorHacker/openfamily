package app.openfamily.wear.data

import android.content.Context
import androidx.wear.tiles.TileService
import androidx.wear.watchface.complications.datasource.ComplicationDataSourceUpdateRequester
import android.content.ComponentName
import app.openfamily.wear.logic.Dedupe
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

    /** True once the stored copy has been read (or there is none). The UI shows nothing until then, so it never flashes "sign in". */
    private val _restored = MutableStateFlow(false)
    val restored: StateFlow<Boolean> = _restored.asStateFlow()

    private val dedupe = Dedupe()
    private val lock = Any()
    private var storedSession: String? = null

    private fun prefs(app: Context) = app.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    /**
     * Loads the stored copy once per process, before the first Data Layer event is used.
     * Reads disk and parses JSON: call it off the main thread.
     */
    fun restore(context: Context) {
        if (_restored.value) return
        synchronized(lock) {
            if (_restored.value) return
            val p = prefs(context.applicationContext)
            storedSession = p.getString(KEY_SESSION, null)
            val json = p.getString(KEY, null)
            if (json != null && _snapshot.value == null) {
                Snapshot.parse(json)?.let {
                    _snapshot.value = it
                    dedupe.seed(json, storedSession)
                }
            }
            _restored.value = true
        }
    }

    /**
     * Called by the Data Layer service and by the activity's initial read, on a
     * background thread. An item identical to the last one is dropped at once: no parse,
     * no disk write, no tile or complication redraw.
     */
    fun accept(context: Context, json: String, session: String? = null) {
        val app = context.applicationContext
        restore(app)
        if (!dedupe.accept(json, session)) return
        val parsed = Snapshot.parse(json)
        if (parsed == null) {
            dedupe.reset()
            return
        }
        synchronized(lock) {
            val p = prefs(app)
            val e = p.edit()
            // Another login than the stored data's: it is the previous user's, drop it first.
            if (SessionGate.mustWipe(storedSession, session)) {
                e.remove(KEY)
                _snapshot.value = null
                _external.value = null
            }
            SessionGate.next(storedSession, session)?.let { storedSession = it; e.putString(KEY_SESSION, it) }
            // A signed-out phone sends an empty snapshot: forget everything on this watch too.
            if (!parsed.signedIn) e.remove(KEY) else e.putString(KEY, json)
            e.apply()
            _snapshot.value = parsed
        }
        refreshSurfaces(app)
    }

    fun clear(context: Context) {
        val app = context.applicationContext
        synchronized(lock) {
            prefs(app).edit().remove(KEY).remove(KEY_SESSION).apply()
            storedSession = null
            dedupe.reset()
            _snapshot.value = null
            _restored.value = true
        }
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
