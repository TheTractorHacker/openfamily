package app.openfamily.wear.data

import android.hardware.GeomagneticField
import app.openfamily.wear.logic.DeclinationCache

/**
 * Magnetic declination (degrees east of true north) at a place, from the model built into Android
 * (GeomagneticField). It needs no permission and sends nothing anywhere; the position comes from [LastLocation].
 */
object Declination {
    private val cache = DeclinationCache { lat, lon, nowMs ->
        GeomagneticField(lat.toFloat(), lon.toFloat(), 0f, nowMs).declination
    }

    /** Null if the model could not be evaluated; the compass then shows magnetic north and says so. */
    fun at(lat: Double, lon: Double, nowMs: Long = System.currentTimeMillis()): Float? = cache.get(lat, lon, nowMs)
}
