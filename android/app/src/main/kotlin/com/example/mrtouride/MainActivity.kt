package com.example.mrtouride

import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
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
}
