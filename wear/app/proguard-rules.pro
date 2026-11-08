# The Data Layer listener and the tile/complication services are found through
# the manifest; their consumer rules already keep them. These are belt and braces.
-keep class app.openfamily.wear.data.DataLayerService { *; }
-keep class app.openfamily.wear.tile.** { *; }
-dontwarn kotlin.**
# The Compose and Wear libraries ship their own consumer rules. Keep line numbers for readable crash reports.
-keepattributes SourceFile,LineNumberTable
