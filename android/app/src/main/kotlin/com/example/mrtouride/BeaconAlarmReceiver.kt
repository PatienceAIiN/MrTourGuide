package com.example.mrtouride

import android.Manifest
import android.app.AlarmManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.location.LocationManager
import android.os.Build

/**
 * Hill Mode trip-beacon safety net that lives OUTSIDE the app process.
 * AlarmManager fires this receiver even if the app was swiped away:
 *  - at the deadline: posts a loud "are you back safe?" notification;
 *  - at deadline + grace: if still not checked in, AUTO-SENDS the alert SMS
 *    to the saved contact via the carrier, with the last known location.
 * On BOOT_COMPLETED it re-arms pending alarms so a phone restart can't
 * silently kill the beacon.
 */
class BeaconAlarmReceiver : BroadcastReceiver() {
    companion object {
        const val GRACE_MS = 15 * 60 * 1000L // auto-alert 15 min after deadline

        private fun prefs(ctx: Context) =
            ctx.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)

        fun plan(ctx: Context) = prefs(ctx).getString("flutter.hill.plan", "") ?: ""
        fun contact(ctx: Context) = prefs(ctx).getString("flutter.hill.contact", "") ?: ""
        fun backBy(ctx: Context) = prefs(ctx).getLong("flutter.hill.backBy", 0L)

        fun pending(ctx: Context, action: String): PendingIntent =
            PendingIntent.getBroadcast(
                ctx, if (action == "remind") 7311 else 7312,
                Intent(ctx, BeaconAlarmReceiver::class.java).setAction(action),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)

        /** Arm both alarms (reminder at [at], auto-alert at [at]+grace). */
        fun arm(ctx: Context, at: Long) {
            val am = ctx.getSystemService(Context.ALARM_SERVICE) as AlarmManager
            val exactOk = Build.VERSION.SDK_INT < 31 || am.canScheduleExactAlarms()
            fun set(t: Long, pi: PendingIntent) {
                if (exactOk) am.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, t, pi)
                else am.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, t, pi)
            }
            set(at, pending(ctx, "remind"))
            set(at + GRACE_MS, pending(ctx, "alert"))
        }

        fun cancel(ctx: Context) {
            val am = ctx.getSystemService(Context.ALARM_SERVICE) as AlarmManager
            am.cancel(pending(ctx, "remind"))
            am.cancel(pending(ctx, "alert"))
        }
    }

    override fun onReceive(ctx: Context, intent: Intent) {
        val active = plan(ctx).isNotEmpty() && backBy(ctx) > 0L
        when (intent.action) {
            Intent.ACTION_BOOT_COMPLETED, "android.intent.action.QUICKBOOT_POWERON" -> {
                if (!active) return
                val at = backBy(ctx)
                val now = System.currentTimeMillis()
                if (at + GRACE_MS > now) arm(ctx, at)      // still pending → re-arm
                else sendAlert(ctx)                         // slept past it → alert now
            }
            "remind" -> if (active) notifyUser(ctx,
                "Are you back safe?",
                "Trip beacon: \"${plan(ctx)}\". Open Hill Mode to check in — " +
                "otherwise your contact is alerted automatically in 15 min.")
            "alert" -> if (active) sendAlert(ctx)
        }
    }

    private fun sendAlert(ctx: Context) {
        val to = contact(ctx)
        val body = "ALERT: I have not checked in from my trip: \"${plan(ctx)}\". " +
            lastLocation(ctx) + " — sent automatically by Mr.Tour Guide Hill Mode"
        var sent = false
        if (to.isNotEmpty() && ctx.checkSelfPermission(Manifest.permission.SEND_SMS) ==
                PackageManager.PERMISSION_GRANTED) {
            try {
                @Suppress("DEPRECATION")
                val sm = if (Build.VERSION.SDK_INT >= 31)
                    ctx.getSystemService(android.telephony.SmsManager::class.java)
                else android.telephony.SmsManager.getDefault()
                sm.sendMultipartTextMessage(to, null, sm.divideMessage(body), null, null)
                sent = true
            } catch (_: Exception) {}
        }
        notifyUser(ctx,
            if (sent) "Alert sent to $to" else "Couldn't auto-send alert",
            if (sent) "You didn't check in — your contact got your plan and last location."
            else "Open the app and check in, or send the alert manually.")
        // One-shot: clear the stored deadline so reboots don't re-fire.
        prefs(ctx).edit().remove("flutter.hill.backBy").apply()
    }

    private fun lastLocation(ctx: Context): String {
        try {
            if (ctx.checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) !=
                PackageManager.PERMISSION_GRANTED) return "Last location unknown"
            val lm = ctx.getSystemService(Context.LOCATION_SERVICE) as LocationManager
            for (p in listOf(LocationManager.GPS_PROVIDER, LocationManager.NETWORK_PROVIDER,
                             LocationManager.PASSIVE_PROVIDER)) {
                val l = try { lm.getLastKnownLocation(p) } catch (_: Exception) { null }
                if (l != null) return "Last location: https://maps.google.com/?q=${l.latitude},${l.longitude}"
            }
        } catch (_: Exception) {}
        return "Last location unknown"
    }

    private fun notifyUser(ctx: Context, title: String, body: String) {
        val nm = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= 26) {
            nm.createNotificationChannel(NotificationChannel(
                "mrtouride_beacon", "Trip beacon", NotificationManager.IMPORTANCE_HIGH))
        }
        val open = PendingIntent.getActivity(ctx, 7313,
            ctx.packageManager.getLaunchIntentForPackage(ctx.packageName),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val n = (if (Build.VERSION.SDK_INT >= 26)
                android.app.Notification.Builder(ctx, "mrtouride_beacon")
            else @Suppress("DEPRECATION") android.app.Notification.Builder(ctx))
            .setSmallIcon(ctx.applicationInfo.icon)
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(android.app.Notification.BigTextStyle().bigText(body))
            .setContentIntent(open)
            .setAutoCancel(true)
            .build()
        nm.notify(7314, n)
    }
}
