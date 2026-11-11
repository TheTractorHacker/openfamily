import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.plugin.compose")
}

// ---- Version: same source as the phone app -------------------------------
// CI passes the release tag's name and code (the formula lives in
// .github/workflows/apk.yml and wear.yml, identical in both). For a local
// build both come from app/pubspec.yaml ("version: 1.2.3+4"), the file the phone
// build reads, so the two never drift apart.
fun pubspecVersion(): Pair<String, Int> {
    val f = rootProject.file("../app/pubspec.yaml")
    val m = Regex("""(?m)^version:\s*([0-9]+\.[0-9]+\.[0-9]+)(?:\+([0-9]+))?""").find(f.readText())
        ?: error("version not found in app/pubspec.yaml")
    return m.groupValues[1] to (m.groupValues[2].toIntOrNull() ?: 1)
}

val (pubName, pubCode) = pubspecVersion()
val wearVersionName = (project.findProperty("WEAR_VERSION_NAME") as String?) ?: pubName
val wearVersionCode = (project.findProperty("WEAR_VERSION_CODE") as String?)?.toInt() ?: pubCode

val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties()
if (keystorePropertiesFile.exists()) {
    FileInputStream(keystorePropertiesFile).use { keystoreProperties.load(it) }
}

android {
    namespace = "app.openfamily.wear"
    compileSdk = 36

    defaultConfig {
        // Same applicationId as the phone app: the Wearable Data Layer only
        // connects apps with the same id and signature (docs/design/WATCH_APPS.md).
        applicationId = "app.orbitly"
        minSdk = 30
        targetSdk = 35
        versionCode = wearVersionCode
        versionName = wearVersionName
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    buildFeatures { compose = true }

    signingConfigs {
        if (keystorePropertiesFile.exists()) {
            create("release") {
                keyAlias = keystoreProperties.getProperty("keyAlias") ?: error("keyAlias missing")
                keyPassword = keystoreProperties.getProperty("keyPassword") ?: error("keyPassword missing")
                storeFile = file(keystoreProperties.getProperty("storeFile") ?: error("storeFile missing"))
                storePassword = keystoreProperties.getProperty("storePassword") ?: error("storePassword missing")
            }
        }
    }

    buildTypes {
        release {
            // Signed when wear/key.properties exists (CI writes it from the same
            // secrets as the phone APK). Otherwise the APK is built unsigned,
            // which is fine for CI smoke builds and cannot be installed.
            if (keystorePropertiesFile.exists()) {
                signingConfig = signingConfigs.getByName("release")
            }
            // Never debuggable, minified with R8 (full mode is the default in AGP 8+) and resource-shrunk.
            isDebuggable = false
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
    }

    lint { abortOnError = false }

    testOptions { unitTests.isReturnDefaultValues = true }
}

composeCompiler {
    // The data and logic classes hold List/Map and are immutable in practice; tell the Compose
    // compiler so composables taking them are skipped when nothing changed.
    stabilityConfigurationFiles.add(rootProject.layout.projectDirectory.file("stability_config.conf"))
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    implementation(platform("androidx.compose:compose-bom:2025.12.01"))
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.ui:ui-tooling-preview")
    implementation("androidx.compose.foundation:foundation")
    implementation("androidx.wear.compose:compose-material:1.5.6")
    implementation("androidx.wear.compose:compose-foundation:1.5.6")
    implementation("androidx.wear.compose:compose-navigation:1.5.6")
    implementation("androidx.activity:activity-compose:1.12.1")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.9.4")
    implementation("androidx.core:core-ktx:1.17.0")
    // Installs the baseline profile (assets/dexopt/baseline.prof) on first run so the hot paths are precompiled.
    implementation("androidx.profileinstaller:profileinstaller:1.4.1")
    implementation("androidx.wear:wear:1.4.0")
    implementation("androidx.wear:wear-remote-interactions:1.1.0")
    implementation("androidx.wear.tiles:tiles:1.5.0")
    implementation("androidx.wear.protolayout:protolayout:1.3.0")
    implementation("androidx.wear.protolayout:protolayout-material:1.3.0")
    implementation("androidx.wear.protolayout:protolayout-expression:1.3.0")
    implementation("androidx.wear.watchface:watchface-complications-data-source-ktx:1.3.0")
    implementation("com.google.android.gms:play-services-wearable:19.0.0")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-play-services:1.10.2")
    debugImplementation("androidx.compose.ui:ui-tooling")

    testImplementation("junit:junit:4.13.2")
    // android.jar ships stubs of org.json that throw on the JVM; tests need the real one.
    testImplementation("org.json:json:20250517")
}
