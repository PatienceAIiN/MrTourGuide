package com.example.mrtouride

import android.app.PendingIntent
import android.content.Context
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

        // ── Direct SMS send (Safety SOS / trip beacon) ───────────────────
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

        // ── BLE SOS relay: broadcast/scan "MTSOS" packets phone-to-phone ────
        // When someone sends an SOS with no signal, their phone advertises a
        // tiny BLE packet (lat/lon). Any nearby phone with this app relays it
        // to Flutter, which alerts its user — a human relay when towers fail.
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, "mrtouride/blesos")
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(args: Any?, sink: EventChannel.EventSink?) {
                    bleSink = sink; startBleScan()
                }
                override fun onCancel(args: Any?) { stopBleScan(); bleSink = null }
            })
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "mrtouride/blesos-ctl")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "advertise" -> {
                        val lat = call.argument<Double>("lat") ?: 0.0
                        val lon = call.argument<Double>("lon") ?: 0.0
                        result.success(startBleAdvertise(lat, lon))
                    }
                    "stopAdvertise" -> { stopBleAdvertise(); result.success(true) }
                    else -> result.notImplemented()
                }
            }

        // ── Phone-wide shake-to-SOS service control + event mirror ─────────
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "mrtouride/shakesvc")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "start" -> { ShakeSosService.start(this); result.success(true) }
                    "stop" -> { ShakeSosService.stop(this); result.success(true) }
                    "cancel" -> {
                        sendBroadcast(Intent(ShakeSosService.ACT_CANCEL)
                            .setPackage(packageName))
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, "mrtouride/shakesvc-events")
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(args: Any?, sink: EventChannel.EventSink?) {
                    shakeEvtSink = sink
                    val recv = object : android.content.BroadcastReceiver() {
                        override fun onReceive(c: Context, i: Intent) {
                            mainHandler.post {
                                shakeEvtSink?.success(mapOf(
                                    "evt" to (i.getStringExtra("evt") ?: ""),
                                    "left" to i.getIntExtra("left", 0)))
                            }
                        }
                    }
                    shakeEvtReceiver = recv
                    if (Build.VERSION.SDK_INT >= 33) {
                        registerReceiver(recv,
                            android.content.IntentFilter(ShakeSosService.EVT_BROADCAST),
                            RECEIVER_NOT_EXPORTED)
                    } else {
                        @Suppress("UnspecifiedRegisterReceiverFlag")
                        registerReceiver(recv,
                            android.content.IntentFilter(ShakeSosService.EVT_BROADCAST))
                    }
                }
                override fun onCancel(args: Any?) {
                    try { shakeEvtReceiver?.let { unregisterReceiver(it) } } catch (_: Exception) {}
                    shakeEvtReceiver = null
                    shakeEvtSink = null
                }
            })

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

    // Shake service event mirror plumbing.
    private var shakeEvtSink: EventChannel.EventSink? = null
    private var shakeEvtReceiver: android.content.BroadcastReceiver? = null

    // ── BLE SOS relay plumbing ──────────────────────────────────────────────
    private var bleSink: EventChannel.EventSink? = null
    private var bleAdvertiser: android.bluetooth.le.BluetoothLeAdvertiser? = null
    private var bleScanner: android.bluetooth.le.BluetoothLeScanner? = null
    private var bleAdvCallback: android.bluetooth.le.AdvertiseCallback? = null
    private var bleScanCallback: android.bluetooth.le.ScanCallback? = null
    private val bleMfgId = 0x4D54 // "MT"

    private fun blePermsOk(): Boolean {
        if (Build.VERSION.SDK_INT < 31) return true
        val need = arrayOf(android.Manifest.permission.BLUETOOTH_ADVERTISE,
                           android.Manifest.permission.BLUETOOTH_SCAN)
        val missing = need.filter {
            checkSelfPermission(it) != PackageManager.PERMISSION_GRANTED }
        if (missing.isEmpty()) return true
        requestPermissions(missing.toTypedArray(), 7303)
        return false
    }

    private fun bleAdapter() =
        (getSystemService(BLUETOOTH_SERVICE) as android.bluetooth.BluetoothManager).adapter

    private fun startBleAdvertise(lat: Double, lon: Double): Boolean {
        if (!blePermsOk()) return false
        return try {
            val adapter = bleAdapter() ?: return false
            if (!adapter.isEnabled) return false
            stopBleAdvertise()
            bleAdvertiser = adapter.bluetoothLeAdvertiser ?: return false
            // Payload: "S" + lat + lon as 4-byte floats → 9 bytes.
            val buf = java.nio.ByteBuffer.allocate(9)
            buf.put('S'.code.toByte()); buf.putFloat(lat.toFloat()); buf.putFloat(lon.toFloat())
            val cb = object : android.bluetooth.le.AdvertiseCallback() {}
            bleAdvCallback = cb
            bleAdvertiser?.startAdvertising(
                android.bluetooth.le.AdvertiseSettings.Builder()
                    .setAdvertiseMode(android.bluetooth.le.AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY)
                    .setTxPowerLevel(android.bluetooth.le.AdvertiseSettings.ADVERTISE_TX_POWER_HIGH)
                    .setConnectable(false).build(),
                android.bluetooth.le.AdvertiseData.Builder()
                    .addManufacturerData(bleMfgId, buf.array()).build(), cb)
            true
        } catch (_: Exception) { false }
    }

    private fun stopBleAdvertise() {
        try { bleAdvCallback?.let { bleAdvertiser?.stopAdvertising(it) } } catch (_: Exception) {}
        bleAdvCallback = null
    }

    private fun startBleScan() {
        if (!blePermsOk()) return
        try {
            val adapter = bleAdapter() ?: return
            if (!adapter.isEnabled) return
            stopBleScan()
            bleScanner = adapter.bluetoothLeScanner ?: return
            val cb = object : android.bluetooth.le.ScanCallback() {
                override fun onScanResult(type: Int, r: android.bluetooth.le.ScanResult?) {
                    val data = r?.scanRecord?.getManufacturerSpecificData(bleMfgId) ?: return
                    if (data.size < 9 || data[0] != 'S'.code.toByte()) return
                    val buf = java.nio.ByteBuffer.wrap(data, 1, 8)
                    val lat = buf.float.toDouble(); val lon = buf.float.toDouble()
                    mainHandler.post {
                        bleSink?.success(mapOf("lat" to lat, "lon" to lon,
                            "rssi" to (r.rssi)))
                    }
                }
            }
            bleScanCallback = cb
            bleScanner?.startScan(
                listOf(android.bluetooth.le.ScanFilter.Builder()
                    .setManufacturerData(bleMfgId, byteArrayOf('S'.code.toByte()),
                        byteArrayOf(0xFF.toByte())).build()),
                android.bluetooth.le.ScanSettings.Builder()
                    .setScanMode(android.bluetooth.le.ScanSettings.SCAN_MODE_BALANCED).build(), cb)
        } catch (_: Exception) {}
    }

    private fun stopBleScan() {
        try { bleScanCallback?.let { bleScanner?.stopScan(it) } } catch (_: Exception) {}
        bleScanCallback = null
    }

    // Pending SMS while the SEND_SMS permission dialog is up.
    private var pendingSms: Triple<String, String, MethodChannel.Result>? = null

    private fun sendSmsNow(to: String, body: String): Boolean {
        // Resolve a WORKING SmsManager even on dual-SIM phones where the
        // context-level manager has no default subscription bound.
        val sm = run {
            @Suppress("DEPRECATION")
            val subId = try {
                android.telephony.SubscriptionManager.getDefaultSmsSubscriptionId()
            } catch (_: Exception) { -1 }
            try {
                if (subId >= 0) {
                    if (Build.VERSION.SDK_INT >= 31)
                        getSystemService(android.telephony.SmsManager::class.java)
                            .createForSubscriptionId(subId)
                    else android.telephony.SmsManager.getSmsManagerForSubscriptionId(subId)
                } else if (Build.VERSION.SDK_INT >= 31)
                    getSystemService(android.telephony.SmsManager::class.java)
                else android.telephony.SmsManager.getDefault()
            } catch (_: Exception) {
                @Suppress("DEPRECATION")
                try { android.telephony.SmsManager.getDefault() } catch (_: Exception) { null }
            }
        } ?: return false
        return try {
            // Report REAL carrier delivery with a toast via a sentIntent.
            val action = "com.example.mrtouride.SMS_SENT_${System.currentTimeMillis()}"
            registerReceiver(object : android.content.BroadcastReceiver() {
                override fun onReceive(c: Context, i: Intent) {
                    try { unregisterReceiver(this) } catch (_: Exception) {}
                    mainHandler.post {
                        android.widget.Toast.makeText(this@MainActivity,
                            if (resultCode == RESULT_OK) "✓ Message sent via carrier"
                            else "Message failed to send (carrier error)",
                            android.widget.Toast.LENGTH_LONG).show()
                    }
                }
            }, android.content.IntentFilter(action),
               if (Build.VERSION.SDK_INT >= 33) Context.RECEIVER_NOT_EXPORTED else 0)
            val parts = sm.divideMessage(body)
            val sentIntents = ArrayList<PendingIntent>(parts.size)
            for (i in 0 until parts.size) sentIntents.add(
                PendingIntent.getBroadcast(this, 7400 + i, Intent(action),
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE or
                    PendingIntent.FLAG_ONE_SHOT))
            sm.sendMultipartTextMessage(to, null, parts, sentIntents, null)
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
