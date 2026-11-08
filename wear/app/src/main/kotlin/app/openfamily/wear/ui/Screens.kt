package app.openfamily.wear.ui

import android.content.Intent
import android.net.Uri
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.rotate
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.wear.compose.foundation.lazy.items
import androidx.wear.compose.material.Button
import androidx.wear.compose.material.ButtonDefaults
import androidx.wear.compose.material.Chip
import androidx.wear.compose.material.ChipDefaults
import androidx.wear.compose.material.CompactChip
import androidx.wear.compose.material.MaterialTheme
import androidx.wear.compose.material.Text
import app.openfamily.wear.CommandStatus
import app.openfamily.wear.WearViewModel
import app.openfamily.wear.data.Snapshot
import app.openfamily.wear.logic.Commands
import app.openfamily.wear.logic.Format
import app.openfamily.wear.logic.Geo
import app.openfamily.wear.logic.Presenter
import app.openfamily.wear.logic.QuickReplies
import app.openfamily.wear.logic.Sos
import app.openfamily.wear.logic.SosState
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import androidx.wear.remote.interactions.RemoteActivityHelper
import java.util.Locale
import java.util.concurrent.Executors

private fun now() = System.currentTimeMillis()
private val remoteExecutor by lazy { Executors.newSingleThreadExecutor() }

@Composable
private fun MenuChip(label: String, secondary: String? = null, badge: String? = null, danger: Boolean = false, onClick: () -> Unit) {
    val ambient = LocalAmbient.current
    Chip(
        onClick = onClick,
        modifier = Modifier.fillMaxWidth(),
        label = { Text(label, maxLines = 2) },
        secondaryLabel = secondary?.let { { Text(it, maxLines = 2) } },
        icon = badge?.let { { Text(it, color = if (danger) Brand.Sos else Brand.Lime, style = MaterialTheme.typography.title3) } },
        colors = if (ambient) ChipDefaults.outlinedChipColors()
        else if (danger) ChipDefaults.chipColors(backgroundColor = Brand.Sos.copy(alpha = 0.35f))
        else ChipDefaults.secondaryChipColors(),
    )
}

@Composable
fun HomeScreen(vm: WearViewModel, go: (String) -> Unit) {
    val s by vm.snapshot.collectAsState()
    val connected by vm.phoneConnected.collectAsState()
    val ambient = LocalAmbient.current
    val snap = s
    ScreenList {
        item { LinkBanner(snap, connected, now()) }
        if (snap == null || !snap.signedIn) {
            item { Text("Sign in on your phone, then open Orbitly there.", textAlign = TextAlign.Center, style = MaterialTheme.typography.body2) }
            return@ScreenList
        }
        if (ambient) {
            val nearest = Presenter.nearest(snap, vm.here.value)
            item {
                Text(nearest?.name ?: "Nobody yet", style = MaterialTheme.typography.title2, textAlign = TextAlign.Center)
                if (nearest != null) Text(Presenter.subtitle(nearest, now()), textAlign = TextAlign.Center, style = MaterialTheme.typography.body2)
            }
            return@ScreenList
        }
        item { MenuChip("People", "${snap.members.size} in ${snap.scope.name.ifEmpty { "your circles" }}", "●") { go("people") } }
        item { MenuChip("I'm OK", "Tell your circle", "✓") { go("checkin") } }
        item { MenuChip("SOS", "Hold to send", "!", danger = true) { go("sos") } }
        item { MenuChip(Presenter.sharingLabel(snap), if (snap.sharing == Snapshot.Sharing.Paused) "Tap to resume" else "Tap to pause", "◉") { go("sharing") } }
        item { MenuChip("Chat", if (snap.unread > 0) "${snap.unread} new" else "Quick replies", if (snap.unread > 0) "${snap.unread}" else "✉") { go("chat") } }
        val active = snap.alerts.count { it.active }
        item { MenuChip("Alerts", if (active > 0) "$active active" else "None right now", if (active > 0) "$active" else "△", danger = active > 0) { go("alerts") } }
    }
}

@Composable
fun PeopleScreen(vm: WearViewModel, open: (String) -> Unit) {
    val s by vm.snapshot.collectAsState()
    val here by vm.here.collectAsState()
    val rows = s?.let { Presenter.rows(it, now(), here) }.orEmpty()
    ScreenList(title = "People") {
        if (rows.isEmpty()) item { Text("No one to show yet.", textAlign = TextAlign.Center) }
        items(rows.size) { i ->
            val r = rows[i]
            Chip(
                onClick = { open(r.id) },
                modifier = Modifier.fillMaxWidth(),
                icon = { Avatar(r.initials, r.color) },
                label = { Text(r.name, maxLines = 1) },
                secondaryLabel = { Text(listOf(r.subtitle, r.battery).filter { it.isNotEmpty() }.joinToString(" · "), maxLines = 2) },
                colors = if (LocalAmbient.current) ChipDefaults.outlinedChipColors() else ChipDefaults.secondaryChipColors(),
            )
        }
    }
}

@Composable
fun PersonScreen(vm: WearViewModel, id: String, openCompass: () -> Unit) {
    val s by vm.snapshot.collectAsState()
    val here by vm.here.collectAsState()
    val m = s?.members?.firstOrNull { it.id == id }
    val ctx = LocalContext.current
    ScreenList {
        if (m == null) {
            item { Text("This person is no longer in the list.", textAlign = TextAlign.Center) }
            return@ScreenList
        }
        item { Avatar(m.initials, m.color, 44.dp) }
        item { Text(m.name, style = MaterialTheme.typography.title2, textAlign = TextAlign.Center) }
        item { Text(Presenter.subtitle(m, now()), textAlign = TextAlign.Center) }
        if (m.address.isNotEmpty() && !(m.state == Snapshot.State.AtPlace && m.address == m.place)) {
            item { Text(m.address, style = MaterialTheme.typography.body2, textAlign = TextAlign.Center) }
        }
        item {
            val parts = buildList {
                add("Seen ${Format.age(now(), m.fixAt ?: s?.ts)}")
                if (m.battery >= 0) add("Battery ${m.battery}%")
            }
            Text(parts.joinToString(" · "), style = MaterialTheme.typography.caption1, color = MaterialTheme.colors.onSurfaceVariant, textAlign = TextAlign.Center)
        }
        val d = here?.let { Presenter.distanceTo(m, it) }
        if (m.hasPosition && !m.isYou) {
            item {
                MenuChip("Direction", d?.let { Geo.formatDistance(it, metric = isMetric()) } ?: "Distance and bearing", "↗") { openCompass() }
            }
        }
        if (m.hasPosition) {
            item {
                CompactChip(
                    onClick = {
                        // The watch has no map: ask the paired phone to show the place in its map app.
                        val geo = Uri.parse("geo:${m.lat},${m.lon}?q=${m.lat},${m.lon}(${Uri.encode(m.name)})")
                        val intent = Intent(Intent.ACTION_VIEW).addCategory(Intent.CATEGORY_BROWSABLE).setData(geo)
                        runCatching { RemoteActivityHelper(ctx, remoteExecutor).startRemoteActivity(intent, null) }
                    },
                    label = { Text("Open on phone") },
                )
            }
        }
    }
}

@Composable
fun isMetric(): Boolean = remember { Locale.getDefault().country !in setOf("US", "GB", "LR", "MM") }

@Composable
fun CompassScreen(vm: WearViewModel, id: String) {
    val s by vm.snapshot.collectAsState()
    val here by vm.here.collectAsState()
    val m = s?.members?.firstOrNull { it.id == id }
    val ambient = LocalAmbient.current
    val heading by rememberHeading(enabled = !ambient)
    ScreenList(title = m?.name) {
        val h = here
        if (m == null || !m.hasPosition) {
            item { Text("No position for this person yet.", textAlign = TextAlign.Center) }
        } else if (h == null) {
            item { Text("Allow location for Orbitly on this watch to see distance and direction.", textAlign = TextAlign.Center, style = MaterialTheme.typography.body2) }
        } else {
            val dist = Geo.distanceM(h.lat, h.lon, m.lat!!, m.lon!!)
            val bearing = Geo.bearingDeg(h.lat, h.lon, m.lat, m.lon)
            val rel = Geo.relativeDeg(bearing, heading)
            item {
                Arrow(rel, if (ambient) Color.White else Brand.Lime)
            }
            item { Text(Geo.formatDistance(dist, isMetric()), style = MaterialTheme.typography.title2) }
            item {
                Text(
                    "${Geo.compassWord(bearing)} of you" + if (heading == null) " (no compass)" else "",
                    style = MaterialTheme.typography.body2, textAlign = TextAlign.Center,
                )
            }
        }
    }
}

@Composable
private fun Arrow(deg: Double, color: Color) {
    Canvas(Modifier.size(72.dp)) {
        val c = Offset(size.width / 2, size.height / 2)
        rotate(deg.toFloat(), c) {
            val w = Stroke(width = 8.dp.toPx(), cap = StrokeCap.Round)
            drawLine(color, Offset(c.x, size.height * 0.9f), Offset(c.x, size.height * 0.1f), strokeWidth = w.width, cap = StrokeCap.Round)
            drawLine(color, Offset(c.x, size.height * 0.1f), Offset(c.x - size.width * 0.22f, size.height * 0.36f), strokeWidth = w.width, cap = StrokeCap.Round)
            drawLine(color, Offset(c.x, size.height * 0.1f), Offset(c.x + size.width * 0.22f, size.height * 0.36f), strokeWidth = w.width, cap = StrokeCap.Round)
        }
        drawCircle(color.copy(alpha = 0.25f), radius = size.minDimension / 2, center = c, style = Stroke(2.dp.toPx()))
    }
}

@Composable
fun SosScreen(vm: WearViewModel) {
    var st by remember { mutableStateOf(SosState()) }
    val status by vm.status.collectAsState()
    val haptic = LocalHapticFeedback.current
    var sent by remember { mutableStateOf(false) }

    LaunchedEffect(st.phase) {
        when (st.phase) {
            SosState.Phase.Countdown -> {
                haptic.performHapticFeedback(HapticFeedbackType.LongPress)
                while (true) {
                    delay(1000)
                    st = Sos.tick(st)
                    if (st.phase != SosState.Phase.Countdown) break
                    haptic.performHapticFeedback(HapticFeedbackType.TextHandleMove)
                }
            }
            SosState.Phase.Sending -> if (!sent) {
                sent = true
                haptic.performHapticFeedback(HapticFeedbackType.LongPress)
                vm.send(Commands.Cmd.Sos)
            }
            else -> {}
        }
    }

    ScreenList {
        when {
            st.phase == SosState.Phase.Sending -> {
                item { StatusBlock(status, "SOS sent to your circle", "Call emergency services if it is urgent.") }
                item { Text("Emergency services were NOT contacted.", style = MaterialTheme.typography.caption1, textAlign = TextAlign.Center) }
                item { CompactChip(onClick = { st = SosState(); sent = false; vm.dismissStatus() }, label = { Text("Done") }) }
            }
            st.phase == SosState.Phase.Countdown -> {
                item { Text("Sending SOS in", textAlign = TextAlign.Center) }
                item { Text("${st.secondsLeft}", style = MaterialTheme.typography.display1, color = Brand.Sos) }
                item { Button(onClick = { st = Sos.cancel(st); haptic.performHapticFeedback(HapticFeedbackType.LongPress) }, colors = ButtonDefaults.secondaryButtonColors()) { Text("Cancel") } }
            }
            else -> {
                item {
                    HoldButton(progress = st.holdMs.toFloat() / SosState.HOLD_MS, onHold = { dt -> st = Sos.hold(st, dt); st }, onRelease = { st = Sos.release(st) })
                }
                item { Text("Press and hold, then you have 5 seconds to cancel.", style = MaterialTheme.typography.caption1, textAlign = TextAlign.Center) }
                item { Text("Tells your family. Emergency services are NOT called.", style = MaterialTheme.typography.caption1, textAlign = TextAlign.Center, color = MaterialTheme.colors.onSurfaceVariant) }
            }
        }
    }
}

@Composable
private fun HoldButton(progress: Float, onHold: (Long) -> SosState, onRelease: () -> Unit) {
    val haptic = LocalHapticFeedback.current
    Box(
        modifier = Modifier
            .size(84.dp)
            .pointerInput(Unit) {
                detectTapGestures(onPress = {
                    coroutineScope {
                        val job = launch {
                            while (true) {
                                delay(50)
                                if (onHold(50).phase == SosState.Phase.Countdown) break
                            }
                        }
                        tryAwaitRelease()
                        job.cancel()
                        onRelease()
                    }
                })
            },
        contentAlignment = Alignment.Center,
    ) {
        Canvas(Modifier.fillMaxSize()) {
            drawCircle(Brand.Sos)
            drawArc(
                Color.White, -90f, 360f * progress.coerceIn(0f, 1f), false,
                topLeft = Offset(6.dp.toPx(), 6.dp.toPx()), size = Size(size.width - 12.dp.toPx(), size.height - 12.dp.toPx()),
                style = Stroke(5.dp.toPx(), cap = StrokeCap.Round),
            )
        }
        Text("SOS", color = Color.White, style = MaterialTheme.typography.title2)
    }
    LaunchedEffect(progress > 0f) { if (progress > 0f) haptic.performHapticFeedback(HapticFeedbackType.TextHandleMove) }
}

@Composable
fun CheckInScreen(vm: WearViewModel) {
    val status by vm.status.collectAsState()
    var asked by remember { mutableStateOf(false) }
    ScreenList(title = "I'm OK") {
        if (!asked) {
            item { Text("Tell your circle you are fine, with where you are.", textAlign = TextAlign.Center, style = MaterialTheme.typography.body2) }
            item { Button(onClick = { asked = true; vm.send(Commands.Cmd.CheckIn) }) { Text("Send") } }
        } else {
            item { StatusBlock(status, "Sent. Your circle knows you are OK") }
            if (status !is CommandStatus.Sending) item { CompactChip(onClick = { asked = false; vm.dismissStatus() }, label = { Text("Back") }) }
        }
    }
}

@Composable
fun SharingScreen(vm: WearViewModel) {
    val s by vm.snapshot.collectAsState()
    val status by vm.status.collectAsState()
    var asked by remember { mutableStateOf(false) }
    val paused = s?.sharing == Snapshot.Sharing.Paused
    ScreenList(title = s?.let { Presenter.sharingLabel(it) } ?: "Sharing") {
        if (asked && status !is CommandStatus.Idle) item { StatusBlock(status, if (paused) "Sharing is paused" else "Sharing is on") }
        if (paused) {
            item { MenuChip("Resume sharing", null) { asked = true; vm.send(Commands.Cmd.Resume) } }
        } else {
            item { MenuChip("Pause 15 min", null) { asked = true; vm.send(Commands.Cmd.Pause, "15") } }
            item { MenuChip("Pause 1 hour", null) { asked = true; vm.send(Commands.Cmd.Pause, "60") } }
            item { MenuChip("Pause 4 hours", null) { asked = true; vm.send(Commands.Cmd.Pause, "240") } }
        }
    }
}

@Composable
fun ChatScreen(vm: WearViewModel) {
    val s by vm.snapshot.collectAsState()
    val status by vm.status.collectAsState()
    var asked by remember { mutableStateOf(false) }
    ScreenList(title = "Quick reply") {
        val unread = s?.unread ?: 0
        if (unread > 0) item { Text("$unread unread on your phone", color = Brand.Lime, style = MaterialTheme.typography.caption1) }
        if (asked && status !is CommandStatus.Idle) item { StatusBlock(status, "Sent") }
        items(QuickReplies.all.size) { i ->
            val r = QuickReplies.all[i]
            MenuChip(r.label, null) { asked = true; vm.send(Commands.Cmd.Reply, r.id) }
        }
    }
}

@Composable
fun AlertsScreen(vm: WearViewModel) {
    val s by vm.snapshot.collectAsState()
    ScreenList(title = "Alerts") {
        val alerts = s?.alerts.orEmpty()
        if (alerts.isEmpty()) item { Text("No alerts right now.", textAlign = TextAlign.Center) }
        items(alerts.size) { i ->
            val a = alerts[i]
            val kind = when (a.kind) { "sos" -> "SOS"; "help" -> "Needs help"; "check_in" -> "Check-in"; else -> "Alert" }
            Chip(
                onClick = { vm.send(Commands.Cmd.Ack, a.id) },
                modifier = Modifier.fillMaxWidth(),
                label = { Text("$kind from ${a.from}", maxLines = 2) },
                secondaryLabel = { Text(listOf(Format.age(now(), a.at), a.note, if (a.active) "Tap = seen" else "ended").filter { it.isNotEmpty() }.joinToString(" · "), maxLines = 3) },
                colors = if (a.active && a.kind != "check_in") ChipDefaults.chipColors(backgroundColor = Brand.Sos.copy(alpha = 0.35f)) else ChipDefaults.secondaryChipColors(),
            )
        }
    }
}
