# The Data Layer listener and the tile/complication services are found through
# the manifest; their consumer rules already keep them. These are belt and braces.
-keep class app.openfamily.wear.data.DataLayerService { *; }
-keep class app.openfamily.wear.tile.** { *; }
-dontwarn kotlin.**
