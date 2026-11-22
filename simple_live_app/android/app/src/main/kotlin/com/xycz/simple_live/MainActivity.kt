package com.xycz.simple_live

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/**
 * 给 Dart 提供「后台播放」前台服务 + 媒体控件的桥接。
 *
 * MethodChannel（Dart -> 原生）:
 * - start：启动 PlaybackService（必须在 App 处于前台时调用，
 *   Android 12+ 禁止从后台启动前台服务）
 * - stop：停止服务并移除通知
 * - updateState：把真实播放状态（playing/paused/buffering）回写进 MediaSession/通知
 * - updateMetadata：把主播名/直播标题/头像字节回写进通知封面
 * - ensureNotificationPermission：Android 13+ 申请通知权限
 *
 * EventChannel（原生 -> Dart）:
 * - 媒体通知/锁屏上的播放、暂停、停止、上一台、下一台按钮回传
 *   "play" / "pause" / "stop" / "previous" / "next"
 */
class MainActivity : FlutterActivity() {

    companion object {
        private const val CHANNEL = "com.xycz.simple_live/background_playback"
        private const val EVENT_CHANNEL = "com.xycz.simple_live/background_playback_events"
        private const val NOTIFICATION_PERMISSION_REQUEST = 10010
    }

    private var playbackEventSink: EventChannel.EventSink? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "start" -> {
                        val title = call.argument<String>("title").orEmpty()
                        val artist = call.argument<String>("artist").orEmpty()
                        val source = call.argument<String>("source").orEmpty()
                        val startedAtMillis =
                            (call.argument<Number>("startedAtMillis"))?.toLong() ?: 0L
                        val avatar = call.argument<ByteArray>("avatar")
                        val platformIcon = call.argument<ByteArray>("platformIcon")
                        PlaybackService.start(
                            this, title, artist, source, startedAtMillis, avatar,
                            platformIcon
                        )
                        result.success(true)
                    }
                    "stop" -> {
                        PlaybackService.stop(this)
                        result.success(true)
                    }
                    "updateState" -> {
                        val state = call.argument<String>("state").orEmpty()
                        PlaybackService.updateState(this, state)
                        result.success(true)
                    }
                    "updateMetadata" -> {
                        val title = call.argument<String>("title").orEmpty()
                        val artist = call.argument<String>("artist").orEmpty()
                        val source = call.argument<String>("source").orEmpty()
                        val startedAtMillis =
                            (call.argument<Number>("startedAtMillis"))?.toLong() ?: 0L
                        val avatar = call.argument<ByteArray>("avatar")
                        val platformIcon = call.argument<ByteArray>("platformIcon")
                        PlaybackService.updateMetadata(
                            this, title, artist, source, startedAtMillis, avatar,
                            platformIcon
                        )
                        result.success(true)
                    }
                    "ensureNotificationPermission" -> {
                        ensureNotificationPermission()
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, EVENT_CHANNEL)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    playbackEventSink = events
                    // 媒体按钮 -> Dart：把命令通过 EventChannel 推给 Dart 播放器
                    PlaybackService.onCommand = { command -> events?.success(command) }
                }

                override fun onCancel(arguments: Any?) {
                    playbackEventSink = null
                    PlaybackService.onCommand = null
                }
            })
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        playbackEventSink = null
        PlaybackService.onCommand = null
        super.cleanUpFlutterEngine(flutterEngine)
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
