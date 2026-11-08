package app.openfamily.wear.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.wear.compose.foundation.lazy.ScalingLazyColumn
import androidx.wear.compose.foundation.lazy.ScalingLazyListScope
import androidx.wear.compose.foundation.lazy.rememberScalingLazyListState
import androidx.wear.compose.material.MaterialTheme
import androidx.wear.compose.material.PositionIndicator
import androidx.wear.compose.material.Scaffold
import androidx.wear.compose.material.Text
import androidx.wear.compose.material.TimeText
import androidx.wear.compose.material.Vignette
import androidx.wear.compose.material.VignettePosition
import app.openfamily.wear.CommandStatus
import app.openfamily.wear.data.Snapshot
import app.openfamily.wear.logic.Format
import app.openfamily.wear.logic.Presenter

/** Standard screen: round-aware scrolling list, clock on top, scroll indicator. */
@Composable
fun ScreenList(
    title: String? = null,
    content: ScalingLazyListScope.() -> Unit,
) {
    val state = rememberScalingLazyListState()
    val ambient = LocalAmbient.current
    Scaffold(
        timeText = { TimeText() },
        vignette = { if (!ambient) Vignette(vignettePosition = VignettePosition.TopAndBottom) },
        positionIndicator = { if (!ambient) PositionIndicator(scalingLazyListState = state) },
    ) {
        ScalingLazyColumn(
            modifier = Modifier.fillMaxWidth(),
            state = state,
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            if (title != null) item { Text(title, style = MaterialTheme.typography.title3, textAlign = TextAlign.Center, modifier = Modifier.padding(bottom = 4.dp)) }
            content()
        }
    }
}

@Composable
fun Avatar(initials: String, color: Int, size: Dp = 32.dp) {
    val ambient = LocalAmbient.current
    Box(
        modifier = Modifier.size(size).background(if (ambient) Color.Black else Color(color), CircleShape),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            initials.take(2),
            color = Color.White,
            fontSize = (size.value * 0.4f).sp,
            fontWeight = FontWeight.Bold,
            maxLines = 1,
            overflow = TextOverflow.Clip,
        )
    }
}

/** One line telling the user how fresh the data is, and that the phone is away if it is. */
@Composable
fun LinkBanner(snapshot: Snapshot?, phoneConnected: Boolean, nowMs: Long) {
    val link = Presenter.link(snapshot, phoneConnected, nowMs)
    val text = when (val l = link) {
        Presenter.Link.NoData -> "Open Orbitly on your phone"
        Presenter.Link.Connected -> "Updated ${Format.age(nowMs, snapshot?.ts)}"
        is Presenter.Link.Offline -> "Phone not connected · ${l.ageText}"
    }
    val warn = link !is Presenter.Link.Connected
    Text(
        text,
        style = MaterialTheme.typography.caption2,
        color = if (warn) Brand.Warn else MaterialTheme.colors.onSurfaceVariant,
        textAlign = TextAlign.Center,
        modifier = Modifier.fillMaxWidth(),
    )
}

/** Shows the progress and outcome of a command (sending, answered, not sent). */
@Composable
fun StatusBlock(status: CommandStatus, okText: String, failHint: String = "") {
    val (headline, detail, color) = when (status) {
        CommandStatus.Idle -> Triple("", "", Color.Unspecified)
        is CommandStatus.Sending -> Triple("Sending...", "", MaterialTheme.colors.onBackground)
        is CommandStatus.Done ->
            if (status.ok) Triple(okText, "", Brand.Ok)
            else Triple("Not sent", status.message.ifEmpty { "The phone could not do it." } + " $failHint", Brand.Sos)
        is CommandStatus.NotSent -> Triple("Not sent", "The phone is not connected. $failHint", Brand.Sos)
        is CommandStatus.NoAnswer -> Triple("No answer", "The phone did not confirm. $failHint", Brand.Warn)
    }
    if (headline.isEmpty()) return
    Column(horizontalAlignment = Alignment.CenterHorizontally, modifier = Modifier.fillMaxWidth().padding(horizontal = 8.dp)) {
        Text(headline, color = color, style = MaterialTheme.typography.title3, textAlign = TextAlign.Center)
        if (detail.isNotBlank()) Text(detail.trim(), style = MaterialTheme.typography.body2, textAlign = TextAlign.Center)
    }
}
