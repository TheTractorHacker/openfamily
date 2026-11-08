package app.openfamily.wear.tile

import androidx.wear.watchface.complications.data.ComplicationData
import androidx.wear.watchface.complications.data.ComplicationType
import androidx.wear.watchface.complications.data.LongTextComplicationData
import androidx.wear.watchface.complications.data.PlainComplicationText
import androidx.wear.watchface.complications.data.ShortTextComplicationData
import androidx.wear.watchface.complications.datasource.ComplicationRequest
import androidx.wear.watchface.complications.datasource.SuspendingComplicationDataSourceService
import app.openfamily.wear.data.LastLocation
import app.openfamily.wear.data.Snapshot
import app.openfamily.wear.data.SnapshotRepository
import app.openfamily.wear.logic.Format
import app.openfamily.wear.logic.Presenter

/**
 * Watch-face complication: nearest member, unread count and sharing state.
 * Updated only when the phone sends a new snapshot (UPDATE_PERIOD_SECONDS = 0).
 */
class NearestComplicationService : SuspendingComplicationDataSourceService() {
    override fun getPreviewData(type: ComplicationType): ComplicationData? = when (type) {
        ComplicationType.SHORT_TEXT -> short("Sam", "2 min", "Nearest: Sam, 2 min ago")
        ComplicationType.LONG_TEXT -> long("Sam, 2 min ago", "Sharing on", "Nearest: Sam, 2 min ago. Sharing on")
        else -> null
    }

    override suspend fun onComplicationRequest(request: ComplicationRequest): ComplicationData? {
        SnapshotRepository.restore(this)
        val s = SnapshotRepository.snapshot.value
        val now = System.currentTimeMillis()
        val nearest = s?.takeIf { it.signedIn }?.let { Presenter.nearest(it, LastLocation.get(this)) }
        val age = nearest?.let { Format.age(now, it.fixAt).removeSuffix(" ago").replace(" min", "m").replace(" h", "h").replace(" d", "d") }
        val paused = s?.sharing == Snapshot.Sharing.Paused
        return when (request.complicationType) {
            ComplicationType.SHORT_TEXT -> when {
                s == null || !s.signedIn -> short("--", "Orbitly", "Open Orbitly on your phone")
                s.unread > 0 -> short("${s.unread} new", "Chat", "${s.unread} unread messages")
                paused -> short("Paused", "Sharing", "Location sharing is paused")
                nearest != null -> short(nearest.name.take(7), age, "Nearest: ${nearest.name}, ${Format.age(now, nearest.fixAt)}")
                else -> short("On", "Sharing", "Location sharing is on")
            }
            ComplicationType.LONG_TEXT -> {
                val who = nearest?.let { "${it.name}, ${Format.age(now, it.fixAt)}" } ?: "No one yet"
                val extra = listOfNotNull(
                    if (paused) "Sharing paused" else "Sharing on",
                    s?.unread?.takeIf { it > 0 }?.let { "$it new" },
                ).joinToString(" · ")
                long(who, extra, "Nearest: $who. $extra")
            }
            else -> null
        }
    }

    private fun short(text: String, title: String?, desc: String) =
        ShortTextComplicationData.Builder(PlainComplicationText.Builder(text).build(), PlainComplicationText.Builder(desc).build())
            .setTitle(title?.let { PlainComplicationText.Builder(it).build() })
            .build()

    private fun long(text: String, title: String, desc: String) =
        LongTextComplicationData.Builder(PlainComplicationText.Builder(text).build(), PlainComplicationText.Builder(desc).build())
            .setTitle(PlainComplicationText.Builder(title).build())
            .build()
}
