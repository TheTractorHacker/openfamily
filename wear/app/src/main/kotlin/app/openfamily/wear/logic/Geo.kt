package app.openfamily.wear.logic

import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.pow
import kotlin.math.roundToInt
import kotlin.math.sin
import kotlin.math.sqrt

object Geo {
    private const val EARTH_M = 6_371_000.0

    /** Great-circle distance in metres. */
    fun distanceM(lat1: Double, lon1: Double, lat2: Double, lon2: Double): Double {
        val p1 = Math.toRadians(lat1)
        val p2 = Math.toRadians(lat2)
        val dp = p2 - p1
        val dl = Math.toRadians(lon2 - lon1)
        val a = sin(dp / 2).pow(2) + cos(p1) * cos(p2) * sin(dl / 2).pow(2)
        return 2 * EARTH_M * atan2(sqrt(a), sqrt(1 - a))
    }

    /** Initial bearing from point 1 to point 2, degrees clockwise from north, 0..360. */
    fun bearingDeg(lat1: Double, lon1: Double, lat2: Double, lon2: Double): Double {
        val p1 = Math.toRadians(lat1)
        val p2 = Math.toRadians(lat2)
        val dl = Math.toRadians(lon2 - lon1)
        val y = sin(dl) * cos(p2)
        val x = cos(p1) * sin(p2) - sin(p1) * cos(p2) * cos(dl)
        return (Math.toDegrees(atan2(y, x)) + 360.0) % 360.0
    }

    /** "80 m", "1.4 km", "0.3 mi", "250 ft". */
    fun formatDistance(meters: Double, metric: Boolean): String {
        if (metric) {
            return when {
                meters < 100 -> "${meters.roundToInt()} m"
                meters < 950 -> "${(meters / 10).roundToInt() * 10} m"
                else -> "%.1f km".format(java.util.Locale.ROOT, meters / 1000)
            }
        }
        val feet = meters * 3.28084
        return if (feet < 1000) {
            if (feet < 100) "${feet.roundToInt()} ft" else "${(feet / 10).roundToInt() * 10} ft"
        } else "%.1f mi".format(java.util.Locale.ROOT, meters / 1609.344)
    }

    private val POINTS = arrayOf("N", "NE", "E", "SE", "S", "SW", "W", "NW")

    fun compassWord(deg: Double): String = POINTS[(((deg % 360 + 360) % 360 + 22.5) / 45).toInt() % 8]

    /** Arrow rotation: where the person is relative to where the watch is pointing. */
    fun relativeDeg(bearing: Double, heading: Double?): Double =
        ((bearing - (heading ?: 0.0)) % 360 + 360) % 360
}
