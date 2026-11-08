// Orbitly for Wear OS. A separate Gradle project on purpose: the phone app
// (../app) is a Flutter project, the watch app is plain Kotlin + Compose.
// See ../docs/design/WATCH_APPS.md and ../docs/user/watch.md.
plugins {
    id("com.android.application") apply false
    id("org.jetbrains.kotlin.plugin.compose") apply false
}
