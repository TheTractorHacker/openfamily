package yukams.app.background_locator_2.provider

import android.location.Location
import android.os.Build
import com.google.android.gms.location.LocationResult
import yukams.app.background_locator_2.Keys
import java.util.HashMap

class LocationParserUtil {
    companion object {
        /**
         * Ground speed in m/s, or -1 when the fix carries none. Android's
         * Location.getSpeed() returns 0.0 when no speed is present (common on
         * network and fused fixes), which would otherwise be sent as a real
         * "stopped" reading. The Dart side already treats a negative speed as
         * unknown.
         */
        fun speedOf(location: Location): Float =
            if (location.hasSpeed()) location.speed else -1f

        /** Speed accuracy in m/s, or -1 when the platform does not provide one. */
        fun speedAccuracyOf(location: Location): Float =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && location.hasSpeedAccuracy()) {
                location.speedAccuracyMetersPerSecond
            } else {
                -1f
            }

        fun getLocationMapFromLocation(location: Location): HashMap<Any, Any> {
            val speedAccuracy = speedAccuracyOf(location)
            var isMocked = false
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.JELLY_BEAN_MR2) {
                isMocked = location.isFromMockProvider
            }

            val map = HashMap<Any, Any>()
            map[Keys.ARG_IS_MOCKED] = isMocked
            map[Keys.ARG_LATITUDE] = location.latitude
            map[Keys.ARG_LONGITUDE] = location.longitude
            map[Keys.ARG_ACCURACY] = location.accuracy
            map[Keys.ARG_ALTITUDE] = location.altitude
            map[Keys.ARG_SPEED] = speedOf(location)
            map[Keys.ARG_SPEED_ACCURACY] = speedAccuracy
            map[Keys.ARG_HEADING] = location.bearing
            map[Keys.ARG_TIME] = location.time.toDouble()
            map[Keys.ARG_PROVIDER] = location.provider ?: ""
            return map
        }

        fun getLocationMapFromLocation(location: LocationResult?): HashMap<Any, Any>? {
            val firstLocation = location?.lastLocation ?: return null

            val speedAccuracy = speedAccuracyOf(firstLocation)
            var isMocked = false
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.JELLY_BEAN_MR2) {
                isMocked = firstLocation.isFromMockProvider
            }

            val map = HashMap<Any, Any>()
            map[Keys.ARG_IS_MOCKED] = isMocked
            map[Keys.ARG_LATITUDE] = firstLocation.latitude
            map[Keys.ARG_LONGITUDE] = firstLocation.longitude
            map[Keys.ARG_ACCURACY] = firstLocation.accuracy
            map[Keys.ARG_ALTITUDE] = firstLocation.altitude
            map[Keys.ARG_SPEED] = speedOf(firstLocation)
            map[Keys.ARG_SPEED_ACCURACY] = speedAccuracy
            map[Keys.ARG_HEADING] = firstLocation.bearing
            map[Keys.ARG_TIME] = firstLocation.time.toDouble()
            return map
        }
    }
}