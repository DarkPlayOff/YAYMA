package io.github.darkplayoff.yayma

import android.os.Bundle
import androidx.core.content.FileProvider
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import android.net.Uri
import android.net.wifi.WifiManager
import android.os.PowerManager
import android.content.Context
import android.content.Intent
import android.provider.Settings
import java.io.File

class MainActivity : AudioServiceActivity() {
    private val CHANNEL = "io.github.darkplayoff.yayma/wifilock"
    private val UPDATER_CHANNEL = "io.github.darkplayoff.yayma/updater"
    private var wifiLock: WifiManager.WifiLock? = null
    private var wakeLock: PowerManager.WakeLock? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        initRustls(this.applicationContext)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "acquire" -> {
                    acquireLock()
                    result.success(null)
                }
                "release" -> {
                    releaseLock()
                    result.success(null)
                }
                "requestIgnoreBatteryOptimizations" -> {
                    requestIgnoreBatteryOptimizations()
                    result.success(null)
                }
                else -> {
                    result.notImplemented()
                }
            }
        }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, UPDATER_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "getSupportedAbis" -> result.success(android.os.Build.SUPPORTED_ABIS.toList())
                "canInstallPackages" -> result.success(canInstallPackages())
                "requestInstallPermission" -> {
                    requestInstallPermission()
                    result.success(null)
                }
                "installApk" -> {
                    val path = call.argument<String>("path")
                    if (path == null) {
                        result.error("invalid_args", "Missing APK path", null)
                    } else {
                        try {
                            installApk(path)
                            result.success(null)
                        } catch (e: Exception) {
                            result.error("install_failed", e.message, null)
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun canInstallPackages(): Boolean =
        packageManager.canRequestPackageInstalls()

    private fun requestInstallPermission() {
        if (canInstallPackages()) return
        try {
            val intent = Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES).apply {
                data = Uri.parse("package:$packageName")
            }
            startActivity(intent)
        } catch (e: Exception) {
            // Some ROMs may not expose this settings screen; ignore.
        }
    }

    private fun installApk(path: String) {
        val file = File(path)
        require(file.exists()) { "APK not found: $path" }
        val uri = FileProvider.getUriForFile(this, "$packageName.fileprovider", file)
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, "application/vnd.android.package-archive")
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        startActivity(intent)
    }

    private fun requestIgnoreBatteryOptimizations() {
        val powerManager = applicationContext.getSystemService(Context.POWER_SERVICE) as PowerManager
        if (powerManager.isIgnoringBatteryOptimizations(packageName)) return
        try {
            val intent = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS).apply {
                data = Uri.parse("package:$packageName")
            }
            startActivity(intent)
        } catch (e: Exception) {
            // Some OEM ROMs (or devices without this system UI) reject the intent; ignore.
        }
    }

    private fun acquireLock() {
        if (wifiLock == null) {
            val wifiManager = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
            val lockType = if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.Q) {
                WifiManager.WIFI_MODE_FULL_HIGH_PERF
            } else {
                @Suppress("DEPRECATION")
                WifiManager.WIFI_MODE_FULL
            }
            wifiLock = wifiManager.createWifiLock(lockType, "Yayma:WifiLock")
        }
        if (wifiLock?.isHeld == false) {
            wifiLock?.acquire()
        }

        if (wakeLock == null) {
            val powerManager = applicationContext.getSystemService(Context.POWER_SERVICE) as PowerManager
            wakeLock = powerManager.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "Yayma:WakeLock")
        }
        if (wakeLock?.isHeld == false) {
            wakeLock?.acquire()
        }
    }

    private fun releaseLock() {
        if (wifiLock?.isHeld == true) {
            wifiLock?.release()
        }
        if (wakeLock?.isHeld == true) {
            wakeLock?.release()
        }
    }

    private external fun initRustls(context: android.content.Context)

    companion object {
        init {
            System.loadLibrary("yayma")
        }
    }
}
