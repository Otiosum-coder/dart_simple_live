package com.xycz.simple_live

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat

/**
 * 「允许后台播放」使用的前台服务。
 *
 * Android 8.0 起，后台长时任务必须跑在前台服务里（并且必须显示一条通知），
 * 否则播放中的进程会被降级成缓存进程，被系统省电策略或 OEM（realme 的
 * o-stop / bgLimit）随时回收 —— 现象就是"后台播放十几分钟被杀、再打开回到首页"。
 *
 * 这里只负责"保活 + 一条低重要度通知"，不碰播放器本身，播放依旧由 Dart 侧的
 * media_kit 负责。通知渠道是 IMPORTANCE_LOW：静音、不弹横幅、无角标，
 * Android 14 起用户还可以直接划掉它而服务继续运行。
 */
class PlaybackService : Service() {

    companion object {
        private const val CHANNEL_ID = "simple_live_background_playback"
        private const val NOTIFICATION_ID = 10010
        private const val EXTRA_TITLE = "title"
        private const val ACTION_START = "com.xycz.simple_live.action.PLAYBACK_START"

        /** 启动后台播放（幂等：重复调用只更新通知内容） */
        fun start(context: Context, title: String) {
            val intent = Intent(context, PlaybackService::class.java).apply {
                action = ACTION_START
                putExtra(EXTRA_TITLE, title)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        /** 停止后台播放并移除通知 */
        fun stop(context: Context) {
            context.stopService(Intent(context, PlaybackService::class.java))
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val title = intent?.getStringExtra(EXTRA_TITLE).orEmpty()
        startInForeground(title)
        return START_NOT_STICKY
    }

    private fun startInForeground(title: String) {
        createChannel()
        val notification = buildNotification(title)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            // Android 14+ 要求前台服务声明类型，manifest 里也要有 mediaPlayback
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            return
        }
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (manager.getNotificationChannel(CHANNEL_ID) != null) {
            return
        }
        val channel = NotificationChannel(
            CHANNEL_ID,
            "后台播放",
            NotificationManager.IMPORTANCE_LOW
        ).apply {
            description = "在后台继续播放直播时显示"
            setShowBadge(false)
            enableVibration(false)
            setSound(null, null)
        }
        manager.createNotificationChannel(channel)
    }

    private fun buildNotification(title: String): Notification {
        val contentIntent = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
            },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val text = if (title.isEmpty()) "正在后台播放" else title
        val builder = NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_stat_playback)
            .setContentTitle("Simple Live")
            .setContentText(text)
            .setContentIntent(contentIntent)
            .setOngoing(true)
            .setSilent(true)
            .setShowWhen(false)
            .setOnlyAlertOnce(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setCategory(NotificationCompat.CATEGORY_TRANSPORT)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            builder.setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
        }
        return builder.build()
    }
}
