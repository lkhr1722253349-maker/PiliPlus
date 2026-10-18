package com.example.piliplus

import android.content.res.Configuration
import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.Build
import android.os.Bundle
import android.view.WindowManager.LayoutParams
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import com.ryanheise.audioservice.AudioServiceActivity

class MainActivity : AudioServiceActivity() {
    private val listeningNetworkChannel = "com.example.piliplus/listening_network"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, listeningNetworkChannel)
            .setMethodCallHandler { call, result ->
                if (call.method != "isMeteredWifi") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                val manager = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
                val network = manager.activeNetwork
                val capabilities = network?.let(manager::getNetworkCapabilities)
                val isWifi = capabilities?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true
                result.success(
                    isWifi && capabilities?.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED) != true,
                )
            }
    }

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        if (AndroidHelper.isFoldable) {
            AndroidHelper.ToDart.onConfigurationChanged?.run()
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            window.attributes.layoutInDisplayCutoutMode =
                LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
        }
    }

    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        AndroidHelper.ToDart.onUserLeaveHint?.run()
    }

    override fun onPictureInPictureModeChanged(isInPictureInPictureMode: Boolean, newConfig: Configuration?) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        AndroidHelper.isPipMode = isInPictureInPictureMode
    }
}
