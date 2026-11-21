package com.uata.uata_app

import android.app.Activity
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.Bitmap
import android.graphics.PixelFormat
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.ImageReader
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.IBinder
import android.util.DisplayMetrics
import android.view.WindowManager
import java.io.ByteArrayOutputStream

/**
 * Screen capture for "analyse over the trading app": runs only after the user accepted Android's own
 * screen-sharing prompt, always with a visible notification, and only takes a picture when asked
 * (the user's button or the automatic analysis the user switched on). Pictures stay on the device.
 * It never touches other apps: no taps, no typing, no reading of their data.
 */
class ScreenCaptureService : Service() {
    companion object {
        const val EXTRA_CODE = "code"
        const val EXTRA_DATA = "data"
        private const val CHANNEL = "uata_screen"
        private const val NOTIFICATION_ID = 7102

        @Volatile var running = false
            private set
        private var projection: MediaProjection? = null
        private var display: VirtualDisplay? = null
        private var reader: ImageReader? = null
        private var thread: HandlerThread? = null

        /** The latest screen frame as PNG, or null when not running / no frame yet. */
        fun capture(): ByteArray? {
            val r = reader ?: return null
            val image = r.acquireLatestImage() ?: return null
            try {
                val plane = image.planes[0]
                val pixelStride = plane.pixelStride
                val rowPadding = plane.rowStride - pixelStride * image.width
                val padded = Bitmap.createBitmap(image.width + rowPadding / pixelStride, image.height, Bitmap.Config.ARGB_8888)
                padded.copyPixelsFromBuffer(plane.buffer)
                val bmp = Bitmap.createBitmap(padded, 0, 0, image.width, image.height)
                val out = ByteArrayOutputStream()
                bmp.compress(Bitmap.CompressFormat.PNG, 100, out)
                padded.recycle()
                bmp.recycle()
                return out.toByteArray()
            } finally {
                image.close()
            }
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, ScreenCaptureService::class.java))
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val code = intent?.getIntExtra(EXTRA_CODE, Activity.RESULT_CANCELED) ?: Activity.RESULT_CANCELED
        @Suppress("DEPRECATION")
        val data: Intent? = intent?.getParcelableExtra(EXTRA_DATA)
        if (code != Activity.RESULT_OK || data == null) {
            stopSelf()
            return START_NOT_STICKY
        }
        startInForeground()
        val mpm = getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
        val mp = mpm.getMediaProjection(code, data)
        if (mp == null) {
            stopSelf()
            return START_NOT_STICKY
        }
        val t = HandlerThread("uata-screen").also { it.start() }
        val handler = Handler(t.looper)
        mp.registerCallback(object : MediaProjection.Callback() {
            override fun onStop() {
                release()
                stopSelf()
            }
        }, handler)
        val metrics = DisplayMetrics()
        @Suppress("DEPRECATION")
        (getSystemService(Context.WINDOW_SERVICE) as WindowManager).defaultDisplay.getRealMetrics(metrics)
        val ir = ImageReader.newInstance(metrics.widthPixels, metrics.heightPixels, PixelFormat.RGBA_8888, 2)
        display = mp.createVirtualDisplay("uata-screen", metrics.widthPixels, metrics.heightPixels, metrics.densityDpi,
            DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR, ir.surface, null, handler)
        projection = mp
        reader = ir
        thread = t
        running = true
        return START_NOT_STICKY
    }

    private fun startInForeground() {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= 26) {
            nm.createNotificationChannel(NotificationChannel(CHANNEL, "Screen reading", NotificationManager.IMPORTANCE_LOW))
        }
        val n: Notification = (if (Build.VERSION.SDK_INT >= 26) Notification.Builder(this, CHANNEL) else
            @Suppress("DEPRECATION") Notification.Builder(this))
            .setContentTitle("UATA")
            .setContentText("Reading the chart on your screen when you ask — analysis only, no trading")
            .setSmallIcon(R.mipmap.ic_launcher)
            .setOngoing(true)
            .build()
        if (Build.VERSION.SDK_INT >= 29) {
            startForeground(NOTIFICATION_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION)
        } else {
            startForeground(NOTIFICATION_ID, n)
        }
    }

    private fun release() {
        running = false
        display?.release()
        display = null
        reader?.close()
        reader = null
        projection = null
        thread?.quitSafely()
        thread = null
    }

    override fun onDestroy() {
        projection?.stop()
        release()
        super.onDestroy()
    }
}
