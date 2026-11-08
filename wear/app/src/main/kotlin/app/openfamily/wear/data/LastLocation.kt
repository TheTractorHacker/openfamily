package app.openfamily.wear.data

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.PackageManager
import android.location.LocationManager
import app.openfamily.wear.logic.Presenter

/** The watch's last known fix, if the user allowed location. Reads what the system already has; never starts GPS. */
object LastLocation {
    @SuppressLint("MissingPermission")
    fun get(context: Context): Presenter.Here? {
        val app = context.applicationContext
        if (app.checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) != PackageManager.PERMISSION_GRANTED &&
            app.checkSelfPermission(Manifest.permission.ACCESS_COARSE_LOCATION) != PackageManager.PERMISSION_GRANTED
        ) return null
        val lm = app.getSystemService(LocationManager::class.java) ?: return null
        val best = runCatching { lm.getProviders(true).mapNotNull { lm.getLastKnownLocation(it) }.maxByOrNull { it.time } }.getOrNull()
        return best?.let { Presenter.Here(it.latitude, it.longitude) }
    }
}
