package com.example.mrtouride

import android.content.Intent
import android.content.pm.PackageManager
import android.media.audiofx.Visualizer
import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.File
import kotlin.math.abs
import kotlin.math.min

class MainActivity : FlutterActivity() {
    // Live audio→haptics: a Visualizer attached to the whole app output
    // (session 0) reads the sound the app is playing — including the
    // YouTube WebView — and streams a bass/energy pair to Flutter ~20x/sec.
    private var visualizer: Visualizer? = null
    private var feelSink: EventChannel.EventSink? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // ── Live audio-energy stream (for YouTube / any in-app audio) ──────
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, "mrtouride/audiofeel")
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(args: Any?, sink: EventChannel.EventSink?) {
                    feelSink = sink
                    startVisualizer()
                }
                override fun onCancel(args: Any?) {
                    stopVisualizer()
                    feelSink = null
                }
            })

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "mrtouride/installer")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    // Where the in-app updater stores downloaded builds.
                    "getDownloadDir" -> result.success(cacheDir.absolutePath)
                    // VR/MR eligibility facts: OS level + motion sensors.
                    "deviceInfo" -> result.success(mapOf(
                        "sdk" to Build.VERSION.SDK_INT,
                        "model" to "${Build.MANUFACTURER} ${Build.MODEL}",
                        "gyro" to packageManager.hasSystemFeature(
                            PackageManager.FEATURE_SENSOR_GYROSCOPE),
                        "accel" to packageManager.hasSystemFeature(
                            PackageManager.FEATURE_SENSOR_ACCELEROMETER),
                    ))
                    // Hand a downloaded APK to the system package installer.
                    "installApk" -> {
                        val path = call.argument<String>("path")
                        if (path == null) {
                            result.error("bad_args", "path required", null)
                            return@setMethodCallHandler
                        }
                        try {
                            val uri = FileProvider.getUriForFile(
                                this, "$packageName.fileprovider", File(path)
                            )
                            startActivity(Intent(Intent.ACTION_VIEW).apply {
                                setDataAndType(uri, "application/vnd.android.package-archive")
                                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            })
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("install_failed", e.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    // Attach a Visualizer to the global mix (audio session 0) and push
    // {bass, energy} (0..1) to Flutter on every waveform callback.
    // Session-0 capture returns ERROR_NO_INIT (-3) until real audio is
    // routing through the mix, so we retry a few times as the video starts.
    private var visRetries = 0
    private fun startVisualizer() {
        if (visualizer != null) return
        try {
            val v = Visualizer(0)
            v.captureSize = Visualizer.getCaptureSizeRange()[1] // 1024
            v.setDataCaptureListener(object : Visualizer.OnDataCaptureListener {
                override fun onWaveFormDataCapture(vz: Visualizer?, wave: ByteArray?, rate: Int) {
                    if (wave == null) return
                    var sum = 0.0; var peak = 0.0; var slow = 0.0; var bassSum = 0.0
                    for (b in wave) {
                        val s = ((b.toInt() and 0xFF) - 128) / 128.0 // -1..1
                        sum += s * s
                        val a = abs(s)
                        if (a > peak) peak = a
                        slow += (a - slow) * 0.12 // low-pass → bass-ish
                        bassSum += slow
                    }
                    val n = wave.size
                    val rms = Math.sqrt(sum / n)
                    val bass = min(1.0, (bassSum / n) * 3.2)
                    val energy = min(1.0, rms * 2.6 + peak * 0.25)
                    mainHandler.post {
                        feelSink?.success(mapOf("bass" to bass, "energy" to energy))
                    }
                }
                override fun onFftDataCapture(vz: Visualizer?, fft: ByteArray?, rate: Int) {}
            }, (Visualizer.getMaxCaptureRate() * 3 / 4).coerceAtMost(20000), true, false)

            // enabled=true can return NO_INIT if audio isn't flowing yet.
            v.enabled = true
            if (!v.enabled) throw IllegalStateException("no_audio_yet")
            visualizer = v
            visRetries = 0
        } catch (e: Exception) {
            try { visualizer?.release() } catch (_: Exception) {}
            visualizer = null
            if (visRetries < 12) {           // retry ~6s as the video buffers
                visRetries++
                mainHandler.postDelayed({ if (feelSink != null) startVisualizer() }, 500)
            } else {
                visRetries = 0
                mainHandler.post {
                    feelSink?.error("visualizer_failed",
                        "Live feel isn't available on this device.", null)
                }
            }
        }
    }

    private fun stopVisualizer() {
        visRetries = 99 // stop any pending retry
        try { visualizer?.enabled = false; visualizer?.release() } catch (_: Exception) {}
        visualizer = null
        visRetries = 0
    }

    override fun onPause() {
        super.onPause()
        // Free the mic/visualizer when backgrounded; Flutter re-listens on resume.
        if (feelSink != null) stopVisualizer()
    }
}
