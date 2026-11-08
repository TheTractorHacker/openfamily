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
import app.openfamily.wear.data.SnapshotRepository
import app.openfamily.wear.logic.Commands
import app.openfamily.wear.ui.OrbitlyTheme
import app.openfamily.wear.ui.WearApp
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

class MainActivity : ComponentActivity() {
    private val vm: WearViewModel by viewModels()
    private var ambient by mutableStateOf(false)

    private val ambientCallback = object : AmbientLifecycleObserver.AmbientLifecycleCallback {
        override fun onEnterAmbient(ambientDetails: AmbientLifecycleObserver.AmbientDetails) {
            ambient = true
            vm.presence(visible = true, ambient = true)
        }
        override fun onExitAmbient() {
            ambient = false
            vm.presence(visible = true)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        lifecycle.addObserver(AmbientLifecycleObserver(this, ambientCallback))
        // Refresh from the Data Layer each time the app is shown, and tell the phone it is on screen
        // (repeated once a minute while it is, not in ambient mode). Nothing else runs on a timer.
        lifecycleScope.launch {
            repeatOnLifecycle(Lifecycle.State.RESUMED) {
                vm.onResume()
                try {
                    while (true) {
                        if (!ambient) vm.presence(visible = true)
                        delay(Commands.VISIBLE_REPEAT_MS)
                    }
                } finally {
                    vm.presence(visible = false)
                    // The tile and complication may have been held back while the app was open.
                    SnapshotRepository.flushSurfaces(applicationContext)
                }
            }
        }
        setContent {
            // Location is optional and only used for distance and direction.
            val askLocation = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { vm.refreshHere() }
            OrbitlyTheme(ambient = ambient) {
                WearApp(vm, requestLocation = { askLocation.launch(Manifest.permission.ACCESS_FINE_LOCATION) })
            }
        }
    }
}
