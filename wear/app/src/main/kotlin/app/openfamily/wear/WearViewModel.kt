package app.openfamily.wear

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import app.openfamily.wear.data.LastLocation
import app.openfamily.wear.data.PhoneLink
import app.openfamily.wear.data.Snapshot
import app.openfamily.wear.data.SnapshotRepository
import app.openfamily.wear.logic.Commands
import app.openfamily.wear.logic.OrderedSender
import app.openfamily.wear.logic.Presenter
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.merge
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull

/** Where a command the user sent is: handed over, answered by the phone, or lost. */
sealed interface CommandStatus {
    data object Idle : CommandStatus
    data class Sending(val id: String, val cmd: Commands.Cmd) : CommandStatus
    data class Done(val id: String, val cmd: Commands.Cmd, val ok: Boolean, val message: String) : CommandStatus
    /** No phone was reachable; nothing was sent. */
    data class NotSent(val cmd: Commands.Cmd) : CommandStatus
    /** Sent, but the phone did not answer in time. */
    data class NoAnswer(val id: String, val cmd: Commands.Cmd) : CommandStatus
}

class WearViewModel(app: Application) : AndroidViewModel(app) {
    private val link = PhoneLink(app)

    val snapshot: StateFlow<Snapshot?> = SnapshotRepository.snapshot
    val phoneConnected: StateFlow<Boolean> = SnapshotRepository.phoneConnected

    private val _status = MutableStateFlow<CommandStatus>(CommandStatus.Idle)
    val status: StateFlow<CommandStatus> = _status.asStateFlow()

    private val _here = MutableStateFlow<Presenter.Here?>(null)
    val here: StateFlow<Presenter.Here?> = _here.asStateFlow()

    val restored: StateFlow<Boolean> = SnapshotRepository.restored

    init {
        // Disk read and JSON parse: never on the main thread, so the first frame is not held up.
        viewModelScope.launch(Dispatchers.Default) { SnapshotRepository.restore(app) }
    }

    /** Called when the app comes to the front: read what the Data Layer holds and who is connected. */
    fun onResume() {
        viewModelScope.launch { link.syncNow() }
        refreshHere()
    }

    fun dismissStatus() {
        _status.value = CommandStatus.Idle
    }

    fun requestRefresh() {
        viewModelScope.launch { link.requestRefresh() }
    }

    @Volatile private var ambientNow = false
    @Volatile private var findingNow = false

    /**
     * Tells the phone whether this app is on screen, so it sends every few seconds
     * while it is and only meaningful changes while it is not (docs/design/WATCH_APPS.md,
     * Cadence). The argument follows the app's state: "ambient" in always-on mode, "finding" while the
     * Direction screen is open (about every 2 s), none otherwise; every repeat carries it, because a plain
     * `visible` would end the faster cadence. Fire and forget, and outside the view model's scope so a "hidden"
     * sent while the activity closes still goes out. A lost one is harmless: the phone
     * forgets "visible" after 150 s by itself.
     */
    fun presence(visible: Boolean) {
        val cmd = if (visible) Commands.build(Commands.Cmd.Visible, Commands.presenceArg(ambientNow, findingNow)) else Commands.build(Commands.Cmd.Hidden)
        presenceSender.post(cmd)
    }

    // Presence messages leave one at a time in the order they were made (see OrderedSender). Outside viewModelScope,
    // so a "hidden" sent as the activity closes still goes out.
    private val presenceSender = OrderedSender<Commands.Built>(background) { link.send(it) }

    override fun onCleared() {
        presenceSender.close()
    }

    /** Always-on mode started or ended; tells the phone. */
    fun setAmbient(on: Boolean) {
        ambientNow = on
        presence(visible = true)
    }

    /**
     * The Direction screen is open and awake ([on]) or is not any more. Tells the phone when the state changes,
     * unless [announce] is false (the app is leaving the screen, and `hidden` goes out instead).
     */
    fun setFinding(on: Boolean, announce: Boolean = true) {
        if (findingNow == on) return
        findingNow = on
        if (announce) presence(visible = true)
    }

    fun send(cmd: Commands.Cmd, arg: String? = null) {
        val built = Commands.build(cmd, arg)
        _status.value = CommandStatus.Sending(built.id, cmd)
        viewModelScope.launch {
            if (!link.send(built)) {
                _status.value = CommandStatus.NotSent(cmd)
                return@launch
            }
            val answer = withTimeoutOrNull(ANSWER_TIMEOUT_MS) {
                // Either the phone's snapshot carries the result, or its listener refused directly.
                merge(
                    snapshot.map { it?.lastCommand },
                    SnapshotRepository.externalResult,
                ).first { it?.id == built.id }
            }
            _status.value = if (answer == null) CommandStatus.NoAnswer(built.id, cmd)
            else CommandStatus.Done(built.id, cmd, answer.ok, answer.message)
        }
    }

    /** Last known location of the watch; used only for distance and direction. Never requested actively. */
    fun refreshHere() {
        viewModelScope.launch(Dispatchers.Default) { _here.value = LastLocation.get(getApplication()) }
    }

    companion object {
        const val ANSWER_TIMEOUT_MS = 20_000L
        private val background = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    }
}
