import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties()
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

val allowDebugSigning =
    (project.findProperty("OPENFAMILY_ALLOW_DEBUG_SIGNING") as String?) == "true"

android {
    namespace = "app.openfamily"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "app.openfamily"
        multiDexEnabled = true
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml (or `--build-number` on CI).
        // When using split APKs, 1000 * ABI_VERSION is added automatically by
        // Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (keystorePropertiesFile.exists()) {
            create("release") {
                keyAlias = keystoreProperties.getProperty("keyAlias")
                    ?: error("keyAlias missing from key.properties")
                keyPassword = keystoreProperties.getProperty("keyPassword")
                    ?: error("keyPassword missing from key.properties")
                storeFile = file(
                    keystoreProperties.getProperty("storeFile")
                        ?: error("storeFile missing from key.properties"),
                )
                storePassword = keystoreProperties.getProperty("storePassword")
                    ?: error("storePassword missing from key.properties")
            }
        }
    }

    buildTypes {
        release {
            // Release builds MUST be signed with the real upload key supplied
            // through android/key.properties (CI writes it from secrets).
            // There is no silent fallback to the debug key (MOB-006): without
            // key.properties the release build fails (see the taskGraph check
            // below). A local, non-distributable release test build can opt in
            // explicitly with -POPENFAMILY_ALLOW_DEBUG_SIGNING=true.
            signingConfig = when {
                keystorePropertiesFile.exists() ->
                    signingConfigs.getByName("release")
                allowDebugSigning -> {
                    logger.warn(
                        "WARNING: signing the release build with the DEBUG " +
                            "key (OPENFAMILY_ALLOW_DEBUG_SIGNING). Do not distribute it.",
                    )
                    signingConfigs.getByName("debug")
                }
                else -> null
            }
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }
}

gradle.taskGraph.whenReady {
    val releaseRequested = allTasks.any {
        it.project == project &&
            it.name in setOf("assembleRelease", "bundleRelease", "packageRelease")
    }
    if (releaseRequested && !keystorePropertiesFile.exists() && !allowDebugSigning) {
        throw GradleException(
            "Release signing is not configured: android/key.properties is missing. " +
                "Create it with storePassword, keyPassword, keyAlias and storeFile " +
                "(see docs/android-release.md), or pass " +
                "-POPENFAMILY_ALLOW_DEBUG_SIGNING=true for a local, non-distributable build.",
        )
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}

// unifiedpush/webpush pull JVM tink; flutter_secure_storage pulls tink-android.
// Both ship the same classes, so drop the JVM artifact on Android.
configurations.configureEach {
    exclude(group = "com.google.crypto.tink", module = "tink")
}
