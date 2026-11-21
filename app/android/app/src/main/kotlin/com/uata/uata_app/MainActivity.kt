package com.uata.uata_app

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.media.projection.MediaProjectionManager
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

/**
 * The trading assistant's Android shell. Besides Flutter it only provides screen capture after the user
 * accepted Android's screen-sharing prompt (see [ScreenCaptureService]). No trading capability.
 */
class MainActivity : FlutterActivity() {
    private val requestCode = 7103
    private var pending: MethodChannel.Result? = null
    private val worker = Executors.newSingleThreadExecutor()

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "uata/screen").setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    if (ScreenCaptureService.running) {
                        result.success(true)
                    } else {
                        pending?.success(false)
                        pending = result
                        val mpm = getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
                        @Suppress("DEPRECATION")
                        startActivityForResult(mpm.createScreenCaptureIntent(), requestCode)
                    }
                }
                "capture" -> worker.execute {
                    val png = try { ScreenCaptureService.capture() } catch (e: Exception) { null }
                    runOnUiThread { result.success(png) }
                }
                "running" -> result.success(ScreenCaptureService.running)
                "stop" -> {
                    ScreenCaptureService.stop(this)
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
    }

    @Deprecated("startActivityForResult is the API MediaProjection uses")
    override fun onActivityResult(code: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(code, resultCode, data)
        if (code != requestCode) return
        val r = pending
        pending = null
        if (resultCode != Activity.RESULT_OK || data == null) {
            r?.success(false)
            return
        }
        val svc = Intent(this, ScreenCaptureService::class.java)
            .putExtra(ScreenCaptureService.EXTRA_CODE, resultCode)
            .putExtra(ScreenCaptureService.EXTRA_DATA, data)
        if (Build.VERSION.SDK_INT >= 26) startForegroundService(svc) else startService(svc)
        // the projection is created by the service a moment later
        window.decorView.postDelayed({ r?.success(ScreenCaptureService.running) }, 700)
    }
}
