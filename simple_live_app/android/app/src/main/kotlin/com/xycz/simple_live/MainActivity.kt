package com.xycz.simple_live

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * 只做一件事：给 Dart 提供「后台播放」前台服务的开关通道。
 *
 * - start：启动 PlaybackService（必须在 App 处于前台时调用，
 *   Android 12+ 禁止从后台启动前台服务）
 * - stop：停止服务并移除通知
 * - ensureNotificationPermission：Android 13+ 申请通知权限
 *   （没有通知权限时前台服务仍能跑，但通知不显示，OEM 更容易回收）
 */
class MainActivity : FlutterActivity() {

    companion object {
        private const val CHANNEL = "com.xycz.simple_live/background_playback"
        private const val NOTIFICATION_PERMISSION_REQUEST = 10010
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "start" -> {
                        val title = call.argument<String>("title").orEmpty()
                        PlaybackService.start(this, title)
                        result.success(true)
                    }
                    "stop" -> {
                        PlaybackService.stop(this)
                        result.success(true)
                    }
                    "ensureNotificationPermission" -> {
                        ensureNotificationPermission()
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun ensureNotificationPermission() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            return
        }
        val granted = ContextCompat.checkSelfPermission(
            this,
            Manifest.permission.POST_NOTIFICATIONS
        ) == PackageManager.PERMISSION_GRANTED
        if (!granted) {
            ActivityCompat.requestPermissions(
                this,
                arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                NOTIFICATION_PERMISSION_REQUEST
            )
        }
    }
}
