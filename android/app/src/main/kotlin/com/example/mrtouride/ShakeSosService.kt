package com.example.mrtouride

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.location.LocationManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import kotlin.math.sqrt

/**
 * Phone-wide shake-to-SOS. A foreground service (Android's requirement for
 * continuous sensor use) watches the accelerometer even when the app is
 * closed or the screen is off:
 *   • three HARD jolts inside 1.2s → a loud 5-second countdown notification
 *     with a big Cancel action (the "popup" that works everywhere);
 *   • not cancelled in time → the SOS SMS auto-sends via the carrier with
 *     last-known GPS, and a result notification confirms it;
 *   • the running state is broadcast to the app so an in-app dialog can
 *     mirror the countdown when the app is open.
 */
class ShakeSosService : Service(), SensorEventListener {
    companion object {
        const val CH_STATUS = "mrtouride_shake"
        const val CH_ALERT = "mrtouride_shake_alert"
        const val ACT_CANCEL = "com.example.mrtouride.SHAKE_CANCEL"
        const val EVT_BROADCAST = "com.example.mrtouride.SHAKE_EVT"
        // Tuning: HARD shake only — ~4.2g spikes, three of them inside 1.2s.
        const val G_THRESHOLD = 4.2
        const val WINDOW_MS = 1200L
        const val MIN_GAP_MS = 200L
        const val COUNTDOWN_S = 5
        const val COOLDOWN_MS = 30_000L

        fun start(ctx: Context) {
            val i = Intent(ctx, ShakeSosService::class.java)
            if (Build.VERSION.SDK_INT >= 26) ctx.startForegroundService(i)
            else ctx.startService(i)
        }

        fun stop(ctx: Context) =
            ctx.stopService(Intent(ctx, ShakeSosService::class.java))

        fun enabled(ctx: Context): Boolean =
            ctx.getSharedPreferences("FlutterSharedPreferences", MODE_PRIVATE)
                .getBoolean("flutter.hill.shake", false)
    }

    private val handler = Handler(Looper.getMainLooper())
    private var sensors: SensorManager? = null
    private val jolts = ArrayList<Long>()
    private var countingDown = false
    private var cooldownUntil = 0L
    private var countdownLeft = 0
    private var ticker: Runnable? = null

    private val cancelReceiver = object : android.content.BroadcastReceiver() {
        override fun onReceive(c: Context, i: Intent) {
            if (i.action == ACT_CANCEL) cancelCountdown()
        }
    }

    override fun onCreate() {
        super.onCreate()
        makeChannels()
        startForeground(7320, statusNotification())
        sensors = getSystemService(SENSOR_SERVICE) as SensorManager
        sensors?.registerListener(this,
            sensors?.getDefaultSensor(Sensor.TYPE_ACCELEROMETER),
            SensorManager.SENSOR_DELAY_GAME)
        if (Build.VERSION.SDK_INT >= 33) {
            registerReceiver(cancelReceiver,
                android.content.IntentFilter(ACT_CANCEL), RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("UnspecifiedRegisterReceiverFlag")
            registerReceiver(cancelReceiver,
                android.content.IntentFilter(ACT_CANCEL))
        }
    }

    override fun onStartCommand(i: Intent?, f: Int, id: Int): Int {
        // Respect the toggle even across service restarts.
        if (!enabled(this)) { stopSelf(); return START_NOT_STICKY }
        return START_STICKY
    }

    override fun onDestroy() {
        try { sensors?.unregisterListener(this) } catch (_: Exception) {}
        try { unregisterReceiver(cancelReceiver) } catch (_: Exception) {}
        ticker?.let { handler.removeCallbacks(it) }
        removeOverlay()
        super.onDestroy()
    }

    override fun onBind(p: Intent?): IBinder? = null
    override fun onAccuracyChanged(s: Sensor?, a: Int) {}

    override fun onSensorChanged(e: SensorEvent) {
        val now = System.currentTimeMillis()
        if (countingDown || now < cooldownUntil) return
        val g = sqrt((e.values[0] * e.values[0] + e.values[1] * e.values[1] +
                e.values[2] * e.values[2]).toDouble()) / 9.81
        if (g < G_THRESHOLD) return
        jolts.removeAll { now - it > WINDOW_MS }
        if (jolts.isNotEmpty() && now - jolts.last() < MIN_GAP_MS) return
        jolts.add(now)
        if (jolts.size >= 3) {
            jolts.clear()
            startCountdown()
        }
    }

    // ── 5-second cancellable countdown ─────────────────────────────────────
    // The popup is a SYSTEM OVERLAY (like an incoming call) so it appears on
    // top of WHATEVER is on screen — home screen, another app, anything —
    // when "display over other apps" is granted. The heads-up notification
    // runs in parallel as the fallback for when the overlay isn't allowed.
    private var overlay: android.view.View? = null
    private var overlayText: android.widget.TextView? = null

    private fun startCountdown() {
        countingDown = true
        countdownLeft = COUNTDOWN_S
        sendEvt("triggered")
        showOverlay()
        val tick = object : Runnable {
            override fun run() {
                if (!countingDown) return
                if (countdownLeft <= 0) {
                    countingDown = false
                    cooldownUntil = System.currentTimeMillis() + COOLDOWN_MS
                    nm().cancel(7321)
                    removeOverlay()
                    sendEvt("sending")
                    sendSos()
                    return
                }
                nm().notify(7321, countdownNotification(countdownLeft))
                overlayText?.text = "Sending SOS in $countdownLeft…"
                vibrate(250)
                countdownLeft--
                handler.postDelayed(this, 1000)
            }
        }
        ticker = tick
        handler.post(tick)
    }

    private fun cancelCountdown() {
        if (!countingDown) return
        countingDown = false
        cooldownUntil = System.currentTimeMillis() + 5000
        ticker?.let { handler.removeCallbacks(it) }
        nm().cancel(7321)
        removeOverlay()
        sendEvt("cancelled")
    }

    // ── System-overlay popup (shows over any app / launcher) ───────────────
    private fun showOverlay() {
        if (overlay != null) return
        if (!android.provider.Settings.canDrawOverlays(this)) return
        try {
            val ctx = this
            val card = android.widget.LinearLayout(ctx).apply {
                orientation = android.widget.LinearLayout.VERTICAL
                setPadding(60, 50, 60, 50)
                background = android.graphics.drawable.GradientDrawable().apply {
                    setColor(0xFF1D1128.toInt())
                    cornerRadius = 48f
                    setStroke(3, 0xFFE53935.toInt())
                }
            }
            overlayText = android.widget.TextView(ctx).apply {
                text = "Sending SOS in $countdownLeft…"
                setTextColor(0xFFFFFFFF.toInt())
                textSize = 22f
                gravity = android.view.Gravity.CENTER
                setTypeface(typeface, android.graphics.Typeface.BOLD)
            }
            val sub = android.widget.TextView(ctx).apply {
                text = "Shake detected. Cancel if this was accidental."
                setTextColor(0xB3FFFFFF.toInt())
                textSize = 14f
                gravity = android.view.Gravity.CENTER
                setPadding(0, 16, 0, 34)
            }
            val cancel = android.widget.Button(ctx).apply {
                text = "CANCEL"
                textSize = 18f
                setTextColor(0xFFFFFFFF.toInt())
                background = android.graphics.drawable.GradientDrawable().apply {
                    setColor(0xFF00897B.toInt())
                    cornerRadius = 40f
                }
                setPadding(40, 26, 40, 26)
                setOnClickListener { cancelCountdown() }
            }
            card.addView(overlayText)
            card.addView(sub)
            card.addView(cancel, android.widget.LinearLayout.LayoutParams(
                android.view.ViewGroup.LayoutParams.MATCH_PARENT,
                android.view.ViewGroup.LayoutParams.WRAP_CONTENT))
            val lp = android.view.WindowManager.LayoutParams(
                android.view.WindowManager.LayoutParams.MATCH_PARENT,
                android.view.WindowManager.LayoutParams.WRAP_CONTENT,
                if (Build.VERSION.SDK_INT >= 26)
                    android.view.WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
                else @Suppress("DEPRECATION")
                    android.view.WindowManager.LayoutParams.TYPE_SYSTEM_ALERT,
                android.view.WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                    android.view.WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                    android.view.WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON,
                android.graphics.PixelFormat.TRANSLUCENT).apply {
                gravity = android.view.Gravity.CENTER
                horizontalMargin = 0.06f
            }
            (getSystemService(WINDOW_SERVICE) as android.view.WindowManager)
                .addView(card, lp)
            overlay = card
        } catch (_: Exception) {
            overlay = null; overlayText = null
        }
    }

    private fun removeOverlay() {
        try {
            overlay?.let {
                (getSystemService(WINDOW_SERVICE) as android.view.WindowManager)
                    .removeView(it)
            }
        } catch (_: Exception) {}
        overlay = null
        overlayText = null
    }

    // ── SOS send (same carrier path as the Safety page) ────────────────────
    private fun sendSos() {
        val prefs = getSharedPreferences("FlutterSharedPreferences", MODE_PRIVATE)
        val contact = prefs.getString("flutter.hill.contact", "") ?: ""
        val to = if (contact.isNotBlank()) contact else "112"
        val body = "SOS — I need help. ${lastLocation()} " +
            "(sent by shake, Mr.Tour Guide Safety)"
        var sent = false
        if (checkSelfPermission(Manifest.permission.SEND_SMS) ==
                PackageManager.PERMISSION_GRANTED) {
            try {
                @Suppress("DEPRECATION")
                val sm = if (Build.VERSION.SDK_INT >= 31)
                    getSystemService(android.telephony.SmsManager::class.java)
                else android.telephony.SmsManager.getDefault()
                sm.sendMultipartTextMessage(to, null, sm.divideMessage(body), null, null)
                sent = true
            } catch (_: Exception) {}
        }
        sendEvt(if (sent) "sent" else "failed")
        nm().notify(7322, resultNotification(
            if (sent) "SOS sent" else "SOS could not auto-send",
            if (sent) "Your location went to $to by SMS."
            else "Open the app and use the SOS button."))
    }

    private fun lastLocation(): String {
        try {
            if (checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) !=
                PackageManager.PERMISSION_GRANTED) return "Location unknown."
            val lm = getSystemService(LOCATION_SERVICE) as LocationManager
            for (p in listOf(LocationManager.GPS_PROVIDER,
                    LocationManager.NETWORK_PROVIDER, LocationManager.PASSIVE_PROVIDER)) {
                val l = try { lm.getLastKnownLocation(p) } catch (_: Exception) { null }
                if (l != null) return "My location: https://maps.google.com/?q=${l.latitude},${l.longitude}"
            }
        } catch (_: Exception) {}
        return "Location unknown."
    }

    // ── Notifications ──────────────────────────────────────────────────────
    private fun nm() = getSystemService(NOTIFICATION_SERVICE) as NotificationManager

    private fun makeChannels() {
        if (Build.VERSION.SDK_INT < 26) return
        nm().createNotificationChannel(NotificationChannel(CH_STATUS,
            "Shake for SOS", NotificationManager.IMPORTANCE_MIN))
        nm().createNotificationChannel(NotificationChannel(CH_ALERT,
            "SOS countdown", NotificationManager.IMPORTANCE_HIGH).apply {
            enableVibration(true)
        })
    }

    private fun openAppIntent(): PendingIntent = PendingIntent.getActivity(
        this, 7323, packageManager.getLaunchIntentForPackage(packageName),
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)

    private fun statusNotification(): Notification =
        (if (Build.VERSION.SDK_INT >= 26) Notification.Builder(this, CH_STATUS)
         else @Suppress("DEPRECATION") Notification.Builder(this))
            .setSmallIcon(applicationInfo.icon)
            .setContentTitle("Shake for SOS is active")
            .setContentText("Shake hard 3× to send an emergency SOS")
            .setContentIntent(openAppIntent())
            .setOngoing(true)
            .build()

    private fun countdownNotification(left: Int): Notification {
        val cancel = PendingIntent.getBroadcast(this, 7324,
            Intent(ACT_CANCEL).setPackage(packageName),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        return (if (Build.VERSION.SDK_INT >= 26) Notification.Builder(this, CH_ALERT)
                else @Suppress("DEPRECATION") Notification.Builder(this))
            .setSmallIcon(applicationInfo.icon)
            .setContentTitle("Sending SOS in $left…")
            .setContentText("Shake detected. Tap CANCEL if accidental.")
            .setContentIntent(openAppIntent())
            .setOngoing(true)
            .setCategory(Notification.CATEGORY_ALARM)
            .addAction(Notification.Action.Builder(null, "CANCEL", cancel).build())
            .build()
    }

    private fun resultNotification(title: String, body: String): Notification =
        (if (Build.VERSION.SDK_INT >= 26) Notification.Builder(this, CH_ALERT)
         else @Suppress("DEPRECATION") Notification.Builder(this))
            .setSmallIcon(applicationInfo.icon)
            .setContentTitle(title)
            .setContentText(body)
            .setContentIntent(openAppIntent())
            .setAutoCancel(true)
            .build()

    private fun vibrate(ms: Long) {
        try {
            @Suppress("DEPRECATION")
            val v = if (Build.VERSION.SDK_INT >= 31)
                (getSystemService(VIBRATOR_MANAGER_SERVICE)
                    as android.os.VibratorManager).defaultVibrator
            else getSystemService(VIBRATOR_SERVICE) as android.os.Vibrator
            if (Build.VERSION.SDK_INT >= 26) {
                v.vibrate(android.os.VibrationEffect.createOneShot(ms, 255))
            } else @Suppress("DEPRECATION") v.vibrate(ms)
        } catch (_: Exception) {}
    }

    /// Mirror state into the app (in-app countdown dialog) when it's open.
    private fun sendEvt(what: String) {
        sendBroadcast(Intent(EVT_BROADCAST).setPackage(packageName)
            .putExtra("evt", what).putExtra("left", countdownLeft))
    }
}
