# R8 / ProGuard rules for the OpenFamily release build. Intentionally
# conservative: when a keep rule is in doubt it is included (MOB-006).

# Flutter embedding and generated plugin registrant (the Flutter Gradle plugin
# adds most of these; repeated here for safety).
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.util.** { *; }
-keep class io.flutter.view.** { *; }
-keep class io.flutter.embedding.** { *; }
-keep class io.flutter.plugins.** { *; }
-keep class io.flutter.plugins.GeneratedPluginRegistrant { *; }
-dontwarn io.flutter.embedding.**
# Deferred components / Play Core are not used.
-dontwarn com.google.android.play.core.**

# Vendored background_locator_2: native services/receivers are referenced from
# the manifest and from persisted callback handles; it also serializes with
# Gson via reflection.
-keep class yukams.app.background_locator_2.** { *; }
-keepclassmembers class yukams.app.background_locator_2.** { *; }

# Gson (reflection-based serialization) and generic signatures/annotations.
-keepattributes Signature
-keepattributes *Annotation*
-keepattributes InnerClasses,EnclosingMethod
-keep class com.google.gson.** { *; }
-keep class * extends com.google.gson.TypeAdapter
-keep class * implements com.google.gson.TypeAdapterFactory
-keep class * implements com.google.gson.JsonSerializer
-keep class * implements com.google.gson.JsonDeserializer

# flutter_secure_storage (EncryptedSharedPreferences / Tink).
-keep class com.it_nomads.fluttersecurestorage.** { *; }
-keep class com.google.crypto.tink.** { *; }
-keep class androidx.security.crypto.** { *; }
-dontwarn com.google.errorprone.annotations.**
-dontwarn javax.annotation.**
-dontwarn org.checkerframework.**
-dontwarn com.google.crypto.tink.**

# Google Play services location / activity recognition (used reflectively by
# GMS and by the plugin).
-keep class com.google.android.gms.location.** { *; }
-keep class com.google.android.gms.common.** { *; }

# UnifiedPush / WebPush connector callbacks resolved by the OS via manifest.
-keep class org.unifiedpush.** { *; }
-dontwarn org.unifiedpush.**

# Biometrics / androidx.work / lifecycle are covered by their consumer rules.
-keep class app.openfamily.** { *; }

# Keep Kotlin metadata for reflection-based libraries.
-keep class kotlin.Metadata { *; }
-dontwarn kotlin.**
