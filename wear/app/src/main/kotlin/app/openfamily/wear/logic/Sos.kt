package app.openfamily.wear.logic

/**
 * Press-and-hold SOS with a cancellable countdown. Pure state machine so it can
 * be unit tested; the screen drives it with a ticker and a finger-down signal.
 */
data class SosState(val phase: Phase = Phase.Idle, val holdMs: Long = 0, val secondsLeft: Int = COUNTDOWN_SECONDS) {
    enum class Phase { Idle, Holding, Countdown, Sending }

    companion object {
        const val HOLD_MS = 1500L
        const val COUNTDOWN_SECONDS = 5
    }
}

object Sos {
    /** Finger is down for another [dtMs]. Arms (starts the countdown) once held long enough. */
    fun hold(s: SosState, dtMs: Long): SosState {
        if (s.phase == SosState.Phase.Countdown || s.phase == SosState.Phase.Sending) return s
        val total = s.holdMs + dtMs
        return if (total >= SosState.HOLD_MS) SosState(SosState.Phase.Countdown, SosState.HOLD_MS, SosState.COUNTDOWN_SECONDS)
        else SosState(SosState.Phase.Holding, total, SosState.COUNTDOWN_SECONDS)
    }

    /** Finger lifted before the hold finished: nothing is armed. */
    fun release(s: SosState): SosState = if (s.phase == SosState.Phase.Holding) SosState() else s

    /** One second of the countdown elapsed. */
    fun tick(s: SosState): SosState {
        if (s.phase != SosState.Phase.Countdown) return s
        val left = s.secondsLeft - 1
        return if (left <= 0) s.copy(phase = SosState.Phase.Sending, secondsLeft = 0) else s.copy(secondsLeft = left)
    }

    fun cancel(@Suppress("UNUSED_PARAMETER") s: SosState): SosState = SosState()

    fun shouldSend(s: SosState): Boolean = s.phase == SosState.Phase.Sending
}
