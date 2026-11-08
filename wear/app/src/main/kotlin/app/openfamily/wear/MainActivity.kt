package app.openfamily.wear

import android.Manifest
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.viewModels
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.repeatOnLifecycle
import androidx.lifecycle.lifecycleScope
import androidx.wear.ambient.AmbientLifecycleObserver
import app.openfamily.wear.ui.OrbitlyTheme
import app.openfamily.wear.ui.WearApp
import kotlinx.coroutines.launch

class MainActivity : ComponentActivity() {
    private val vm: WearViewModel by viewModels()
    private var ambient by mutableStateOf(false)

    private val ambientCallback = object : AmbientLifecycleObserver.AmbientLifecycleCallback {
        override fun onEnterAmbient(ambientDetails: AmbientLifecycleObserver.AmbientDetails) { ambient = true }
        override fun onExitAmbient() { ambient = false }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        lifecycle.addObserver(AmbientLifecycleObserver(this, ambientCallback))
        // Refresh from the Data Layer each time the app is shown. No timers, no polling.
        lifecycleScope.launch { repeatOnLifecycle(Lifecycle.State.RESUMED) { vm.onResume() } }
        setContent {
            // Location is optional and only used for distance and direction.
            val askLocation = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { vm.refreshHere() }
            OrbitlyTheme(ambient = ambient) {
                WearApp(vm, requestLocation = { askLocation.launch(Manifest.permission.ACCESS_FINE_LOCATION) })
            }
        }
    }
}
