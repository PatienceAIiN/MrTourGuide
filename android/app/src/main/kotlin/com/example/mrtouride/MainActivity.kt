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

        // ── Direct SMS send (Hill Mode SOS / trip beacon) ───────────────────
        // Sends via the carrier with SmsManager — no SMS-app hop, works on
        // bare 2G signal with zero data. Requests SEND_SMS at first use.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "mrtouride/sms")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    // Permission state: granted | denied | blocked (never-ask-again)
                    "status" -> {
                        val granted = checkSelfPermission(android.Manifest.permission.SEND_SMS) ==
                            PackageManager.PERMISSION_GRANTED
                        result.success(when {
                            granted -> "granted"
                            shouldShowRequestPermissionRationale(
                                android.Manifest.permission.SEND_SMS) -> "denied"
                            else -> "blocked"
                        })
                        return@setMethodCallHandler
                    }
                    "openSettings" -> {
                        startActivity(Intent(
                            android.provider.Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                            android.net.Uri.parse("package:$packageName"))
                            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                        result.success(true)
                        return@setMethodCallHandler
                    }
                }
                if (call.method != "send") { result.notImplemented(); return@setMethodCallHandler }
                val to = call.argument<String>("to")
                val body = call.argument<String>("body")
                if (to.isNullOrBlank() || body.isNullOrBlank()) {
                    result.error("bad_args", "to/body required", null)
                    return@setMethodCallHandler
                }
                if (checkSelfPermission(android.Manifest.permission.SEND_SMS) !=
                        PackageManager.PERMISSION_GRANTED) {
                    pendingSms = Triple(to, body, result)
                    requestPermissions(arrayOf(android.Manifest.permission.SEND_SMS), 7301)
                    return@setMethodCallHandler
                }
                result.success(sendSmsNow(to, body))
            }

        // ── Trip-beacon alarms: exact, process-independent, reboot-proof ────
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "mrtouride/beacon")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "arm" -> {
                        val at = call.argument<Long>("at")
                            ?: call.argument<Int>("at")?.toLong()
                        if (at == null) { result.error("bad_args", "at required", null); return@setMethodCallHandler }
                        // Ensure SMS permission is in place NOW so the killed-app
                        // auto-alert can send without asking anyone.
                        if (checkSelfPermission(android.Manifest.permission.SEND_SMS) !=
                                PackageManager.PERMISSION_GRANTED) {
                            requestPermissions(arrayOf(android.Manifest.permission.SEND_SMS), 7302)
                        }
                        BeaconAlarmReceiver.arm(this, at)
                        result.success(true)
                    }
                    "cancel" -> { BeaconAlarmReceiver.cancel(this); result.success(true) }
                    else -> result.notImplemented()
                }
            }

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
            val samplingHz = v.samplingRate / 1000.0            // milliHz → Hz
            v.setDataCaptureListener(object : Visualizer.OnDataCaptureListener {
                override fun onWaveFormDataCapture(vz: Visualizer?, wave: ByteArray?, rate: Int) {}

                // FFT band analysis: split the spectrum so we can feel the
                // PHYSICAL scene (footsteps, vehicles, impacts, ambience) and
                // deliberately ignore human speech (the 300–3400 Hz vocal band).
                override fun onFftDataCapture(vz: Visualizer?, fft: ByteArray?, rate: Int) {
                    if (fft == null || fft.size < 4) return
                    val bins = fft.size / 2
                    val binHz = samplingHz / (bins * 2.0)   // Hz per bin
                    // Band energy accumulators
                    var low = 0.0     // 30–250 Hz: rumble, vehicle, footfall body
                    var lowMid = 0.0  // 250–500 Hz: footstep slap, texture
                    var vocal = 0.0   // 300–3400 Hz: human speech
                    var high = 0.0    // >3400 Hz: sibilance, hiss, sparkle
                    for (i in 1 until bins) {
                        val re = fft[2 * i].toInt()
                        val im = fft[2 * i + 1].toInt()
                        val mag = Math.sqrt((re * re + im * im).toDouble())
                        val hz = i * binHz
                        when {
                            hz < 250.0  -> low += mag
                            hz < 500.0  -> { lowMid += mag; if (hz >= 300) vocal += mag }
                            hz < 3400.0 -> vocal += mag
                            else        -> high += mag
                        }
                    }
                    // Normalise (magnitudes ~0..128 each bin); tuned empirically.
                    val lowN   = min(1.0, low   / 900.0)
                    val lowMidN= min(1.0, lowMid/ 700.0)
                    val vocalN = min(1.0, vocal / 2600.0)
                    val highN  = min(1.0, high  / 3000.0)
                    mainHandler.post {
                        feelSink?.success(mapOf(
                            "low" to lowN, "lowMid" to lowMidN,
                            "vocal" to vocalN, "high" to highN))
                    }
                }
            }, (Visualizer.getMaxCaptureRate() * 3 / 4).coerceAtMost(20000), false, true)

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

    // Pending SMS while the SEND_SMS permission dialog is up.
    private var pendingSms: Triple<String, String, MethodChannel.Result>? = null

    private fun sendSmsNow(to: String, body: String): Boolean {
        return try {
            @Suppress("DEPRECATION")
            val sm = if (Build.VERSION.SDK_INT >= 31)
                getSystemService(android.telephony.SmsManager::class.java)
            else android.telephony.SmsManager.getDefault()
            val parts = sm.divideMessage(body)
            sm.sendMultipartTextMessage(to, null, parts, null, null)
            true
        } catch (e: Exception) { false }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == 7301) {
            val p = pendingSms; pendingSms = null
            if (p != null) {
                if (grantResults.isNotEmpty() &&
                    grantResults[0] == PackageManager.PERMISSION_GRANTED) {
                    p.third.success(sendSmsNow(p.first, p.second))
                } else p.third.success(false)
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
