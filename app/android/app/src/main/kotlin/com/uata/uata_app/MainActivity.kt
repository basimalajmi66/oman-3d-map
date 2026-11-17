package com.uata.uata_app

import com.chaquo.python.Python
import com.chaquo.python.android.AndroidPlatform
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * Hosts the Flutter UI and starts the embedded local engine.
 *
 * Channel "uata/engine":
 *   start({port}) -> {port, data_dir}
 * The engine (backend/uata, run by Chaquopy) listens on 127.0.0.1 only and keeps
 * all data in the app's private storage (filesDir/uata). No trading capability.
 */
class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "uata/engine").setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    val port = call.argument<Int>("port") ?: 8765
                    val dataDir = File(filesDir, "uata").absolutePath
                    // Python start-up and the first DB migration take a moment: keep them off the UI thread.
                    Thread {
                        try {
                            if (!Python.isStarted()) Python.start(AndroidPlatform(applicationContext))
                            Python.getInstance().getModule("uata.android_entry").callAttr("start", dataDir, port)
                            runOnUiThread { result.success(mapOf("port" to port, "data_dir" to dataDir)) }
                        } catch (e: Throwable) {
                            runOnUiThread { result.error("ENGINE_START_FAILED", e.message ?: e.toString(), null) }
                        }
                    }.start()
                }
                else -> result.notImplemented()
            }
        }
    }
}
