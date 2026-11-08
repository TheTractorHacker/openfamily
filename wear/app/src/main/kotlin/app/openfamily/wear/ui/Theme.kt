package app.openfamily.wear.ui

import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.ui.graphics.Color
import androidx.wear.compose.material.Colors
import androidx.wear.compose.material.MaterialTheme

/** Brand colors from the phone app (app_theme.dart): lime accent, sky satellite, night surfaces. */
object Brand {
    val Lime = Color(0xFFA3E635)
    val Sky = Color(0xFF38BDF8)
    val Night = Color(0xFF000000)
    val Surface = Color(0xFF2A2D33)
    val Ink = Color(0xFFF4F5F7)
    val Muted = Color(0xFF9CA3AF)
    val Sos = Color(0xFFE53935)
    val Warn = Color(0xFFFF9500)
    val Ok = Color(0xFF2ECC71)
}

/** True while the watch is in ambient (low power) mode: black, no color fills, no animation. */
val LocalAmbient = compositionLocalOf { false }

@Composable
fun OrbitlyTheme(ambient: Boolean = false, content: @Composable () -> Unit) {
    val colors = Colors(
        primary = Brand.Lime,
        primaryVariant = Color(0xFF78B400),
        secondary = Brand.Sky,
        background = Brand.Night,
        surface = Brand.Surface,
        error = Brand.Sos,
        onPrimary = Color(0xFF111827),
        onSecondary = Color(0xFF111827),
        onBackground = Brand.Ink,
        onSurface = Brand.Ink,
        onSurfaceVariant = Brand.Muted,
        onError = Color.White,
    )
    CompositionLocalProvider(LocalAmbient provides ambient) {
        MaterialTheme(colors = colors, content = content)
    }
}
