package app.openfamily.wear.tile

import android.content.ComponentName
import androidx.concurrent.futures.CallbackToFutureAdapter
import androidx.wear.protolayout.ActionBuilders
import androidx.wear.protolayout.ColorBuilders.argb
import androidx.wear.protolayout.DimensionBuilders.dp
import androidx.wear.protolayout.DimensionBuilders.sp
import androidx.wear.protolayout.LayoutElementBuilders
import androidx.wear.protolayout.ModifiersBuilders
import androidx.wear.protolayout.ResourceBuilders
import androidx.wear.protolayout.TimelineBuilders
import androidx.wear.protolayout.LayoutElementBuilders.FontStyle
import androidx.wear.tiles.RequestBuilders
import androidx.wear.tiles.TileBuilders
import androidx.wear.tiles.TileService
import app.openfamily.wear.data.LastLocation
import app.openfamily.wear.data.Snapshot
import app.openfamily.wear.data.SnapshotRepository
import app.openfamily.wear.logic.Format
import app.openfamily.wear.logic.Geo
import app.openfamily.wear.logic.Presenter
import com.google.common.util.concurrent.ListenableFuture

/**
 * "Circle" tile: the people nearest to you (or most recently seen, when the
 * watch has no location). Redrawn only when the phone sends a new snapshot.
 */
class CircleTileService : TileService() {
    override fun onTileRequest(requestParams: RequestBuilders.TileRequest): ListenableFuture<TileBuilders.Tile> =
        // The system calls this on the main thread; the first call reads disk and parses JSON, so do it elsewhere.
        CallbackToFutureAdapter.getFuture { c ->
            worker.execute { try { c.set(buildTile()) } catch (t: Throwable) { c.setException(t) } }
            "orbitly-tile"
        }

    private fun buildTile(): TileBuilders.Tile {
        SnapshotRepository.restore(this)
        val snap = SnapshotRepository.snapshot.value
        val here = LastLocation.get(this)
        val layout = buildLayout(snap, here, System.currentTimeMillis(), java.util.Locale.getDefault().country !in setOf("US", "GB"))
        return TileBuilders.Tile.Builder()
            .setResourcesVersion(RES_VERSION)
            .setTileTimeline(TimelineBuilders.Timeline.fromLayoutElement(layout))
            // Content is pushed by the phone; the tile never refreshes on a timer.
            .setFreshnessIntervalMillis(0)
            .build()
    }

    override fun onTileResourcesRequest(requestParams: RequestBuilders.ResourcesRequest): ListenableFuture<ResourceBuilders.Resources> =
        CallbackToFutureAdapter.getFuture { c -> c.set(ResourceBuilders.Resources.Builder().setVersion(RES_VERSION).build()); "orbitly-res" }

    private fun buildLayout(snap: Snapshot?, here: Presenter.Here?, nowMs: Long, metric: Boolean): LayoutElementBuilders.LayoutElement {
        val col = LayoutElementBuilders.Column.Builder()
            .setHorizontalAlignment(LayoutElementBuilders.HORIZONTAL_ALIGN_CENTER)
            .addContent(text("Orbitly", 12f, LIME, bold = true))
        if (snap == null || !snap.signedIn) {
            col.addContent(text("Open Orbitly on your phone", 14f, INK))
        } else {
            val people = Presenter.sorted(snap.members.filter { !it.isYou && it.hasPosition }, here).take(3)
            if (people.isEmpty()) col.addContent(text("No one to show yet", 14f, INK))
            for (m in people) {
                val dist = here?.let { Presenter.distanceTo(m, it) }?.let { Geo.formatDistance(it, metric) }
                col.addContent(text(m.name.take(14), 15f, INK, bold = true))
                col.addContent(text(listOfNotNull(dist, Format.age(nowMs, m.fixAt)).joinToString(" · "), 11f, MUTED))
            }
            if (snap.unread > 0) col.addContent(text("${snap.unread} new messages", 11f, LIME))
        }
        val open = ModifiersBuilders.Clickable.Builder()
            .setId("open")
            .setOnClick(ActionBuilders.LaunchAction.Builder().setAndroidActivity(
                ActionBuilders.AndroidActivity.Builder().setPackageName(packageName).setClassName("app.openfamily.wear.MainActivity").build()).build())
            .build()
        return LayoutElementBuilders.Box.Builder()
            .setWidth(androidx.wear.protolayout.DimensionBuilders.expand())
            .setHeight(androidx.wear.protolayout.DimensionBuilders.expand())
            .setHorizontalAlignment(LayoutElementBuilders.HORIZONTAL_ALIGN_CENTER)
            .setVerticalAlignment(LayoutElementBuilders.VERTICAL_ALIGN_CENTER)
            .setModifiers(ModifiersBuilders.Modifiers.Builder().setClickable(open).setPadding(
                ModifiersBuilders.Padding.Builder().setAll(dp(8f)).build()).build())
            .addContent(col.build())
            .build()
    }

    private fun text(s: String, size: Float, color: Int, bold: Boolean = false) =
        LayoutElementBuilders.Text.Builder()
            .setText(s)
            .setMaxLines(1)
            .setFontStyle(
                FontStyle.Builder().setSize(sp(size)).setColor(argb(color))
                    .setWeight(if (bold) LayoutElementBuilders.FONT_WEIGHT_BOLD else LayoutElementBuilders.FONT_WEIGHT_NORMAL).build(),
            )
            .build()

    private companion object {
        val worker: java.util.concurrent.Executor by lazy { java.util.concurrent.Executors.newSingleThreadExecutor() }
        const val RES_VERSION = "1"
        const val LIME = 0xFFA3E635.toInt()
        const val INK = 0xFFF4F5F7.toInt()
        const val MUTED = 0xFF9CA3AF.toInt()
    }
}
