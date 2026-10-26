package app.openfamily

import android.os.Bundle
import androidx.core.view.WindowCompat
import io.flutter.embedding.android.FlutterFragmentActivity

class MainActivity : FlutterFragmentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        // Deliberately opt in to edge-to-edge (Android 15+ enforces it for
        // targetSdk 35+; this keeps older versions identical). The Flutter UI
        // pads for the status bar, cutout and gesture bar via MediaQuery.
        WindowCompat.setDecorFitsSystemWindows(window, false)
        super.onCreate(savedInstanceState)
    }
}
