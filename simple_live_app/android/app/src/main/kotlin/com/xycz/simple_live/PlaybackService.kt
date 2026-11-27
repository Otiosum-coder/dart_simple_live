package com.xycz.simple_live

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.RectF
import android.media.MediaMetadata
import android.media.session.MediaSession
import android.media.session.PlaybackState
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.SystemClock
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/**
 * 「允许后台播放」使用的前台服务 + 媒体控件。
 *
 * Android 8.0 起，后台长时任务必须跑在前台服务里（并且必须显示一条通知），
 * 否则播放中的进程会被降级成缓存进程，被系统省电策略或 OEM（realme 的
 * o-stop / bgLimit）随时回收 —— 现象就是"后台播放十几分钟被杀、再打开回到首页"。
 *
 * 本服务只负责"保活 + 媒体通知"，不碰播放器本身，播放依旧由 Dart 侧的 media_kit 负责：
 * 播放/暂停/停止按钮不会直接操作播放器，而是通过 [onCommand] 回调把命令回传给 Dart，
 * 由 Dart 调用 player.play()/pause()/stop()，再把真实状态通过 updateState 回写到这里。
 *
 * 通知使用 Notification.MediaStyle 绑定 MediaSession token，锁屏/通知栏会显示
 * 播放/暂停、停止、点击回 App，以及主播头像封面。
 */
class PlaybackService : Service() {

    companion object {
        private const val CHANNEL_ID = "simple_live_background_playback"
        private const val NOTIFICATION_ID = 10010
        private const val MEDIA_SESSION_TAG = "SimpleLivePlayback"

        private const val EXTRA_TITLE = "title"
        private const val EXTRA_ARTIST = "artist"
        private const val EXTRA_SOURCE = "source"
        private const val EXTRA_STARTED_AT = "startedAtMillis"
        private const val EXTRA_AVATAR = "avatar"
        private const val EXTRA_PLATFORM_ICON = "platformIcon"
        private const val EXTRA_STATE = "state"

        /** 启动/更新后台播放（幂等：重复调用只更新通知内容） */
        const val ACTION_START = "com.xycz.simple_live.action.PLAYBACK_START"
        const val ACTION_PLAY = "com.xycz.simple_live.action.PLAYBACK_PLAY"
        const val ACTION_PAUSE = "com.xycz.simple_live.action.PLAYBACK_PAUSE"
        const val ACTION_PREVIOUS = "com.xycz.simple_live.action.PLAYBACK_PREVIOUS"
        const val ACTION_NEXT = "com.xycz.simple_live.action.PLAYBACK_NEXT"
        const val ACTION_STOP = "com.xycz.simple_live.action.PLAYBACK_STOP"
        const val ACTION_TOGGLE = "com.xycz.simple_live.action.PLAYBACK_TOGGLE"
        const val ACTION_UPDATE_STATE = "com.xycz.simple_live.action.PLAYBACK_UPDATE_STATE"
        const val ACTION_UPDATE_METADATA = "com.xycz.simple_live.action.PLAYBACK_UPDATE_METADATA"

        /** 当前活着的服务实例（同一进程内供 MainActivity 转发状态用） */
        @Volatile
        var instance: PlaybackService? = null
            private set

        /** 媒体按钮/通知动作回传给 Dart 的回调，值域: "play" / "pause" / "stop" / "previous" / "next" */
        @Volatile
        var onCommand: ((String) -> Unit)? = null

        /** 启动后台播放（幂等：重复调用只更新通知内容） */
        fun start(
            context: Context,
            title: String,
            artist: String,
            source: String,
            startedAtMillis: Long,
            avatar: ByteArray?,
            platformIcon: ByteArray?
        ) {
            val intent = Intent(context, PlaybackService::class.java).apply {
                action = ACTION_START
                putExtra(EXTRA_TITLE, title)
                putExtra(EXTRA_ARTIST, artist)
                putExtra(EXTRA_SOURCE, source)
                putExtra(EXTRA_STARTED_AT, startedAtMillis)
                putExtra(EXTRA_AVATAR, avatar)
                putExtra(EXTRA_PLATFORM_ICON, platformIcon)
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

        /** Dart 回写播放状态: "playing" / "paused" / "buffering" */
        fun updateState(context: Context, state: String) {
            instance?.applyState(state)
        }

        /** Dart 回写媒体元信息（标题=直播标题，artist=主播名，source=平台名，startedAtMillis=开播时间，avatar=头像字节） */
        fun updateMetadata(
            context: Context,
            title: String,
            artist: String,
            source: String,
            startedAtMillis: Long,
            avatar: ByteArray?,
            platformIcon: ByteArray?
        ) {
            instance?.applyMetadata(
                title, artist, source, startedAtMillis, avatar, platformIcon
            )
        }
    }

    private var mediaSession: MediaSession? = null
    private var title: String = ""
    private var artist: String = ""
    private var sourceName: String = ""
    private var startedAtMillis: Long = 0L
    private var avatarBitmap: Bitmap? = null
    private var platformBitmap: Bitmap? = null
    private var artworkBitmap: Bitmap? = null
    private var playbackState: Int = PlaybackState.STATE_PAUSED
    private var isForeground = false
    private val durationHandler = Handler(Looper.getMainLooper())
    private val durationRefresh = Runnable {
        if (isForeground) publish()
    }

    override fun onCreate() {
        super.onCreate()
        instance = this
        createMediaSession()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                onCommand?.invoke("stop")
                stopPlayback()
                return START_NOT_STICKY
            }
            ACTION_PLAY -> dispatchCommand("play", playOptimistic = true)
            ACTION_PAUSE -> dispatchCommand("pause", playOptimistic = false)
            ACTION_PREVIOUS -> dispatchNavigation("previous")
            ACTION_NEXT -> dispatchNavigation("next")
            ACTION_TOGGLE -> {
                val playNext = playbackState != PlaybackState.STATE_PLAYING
                dispatchCommand(if (playNext) "play" else "pause", playOptimistic = playNext)
            }
            ACTION_UPDATE_STATE -> {
                setStateInternal(intent.getStringExtra(EXTRA_STATE).orEmpty())
            }
            ACTION_UPDATE_METADATA -> {
                setMetadataInternal(
                    intent.getStringExtra(EXTRA_TITLE).orEmpty(),
                    intent.getStringExtra(EXTRA_ARTIST).orEmpty(),
                    intent.getStringExtra(EXTRA_SOURCE).orEmpty(),
                    intent.getLongExtra(EXTRA_STARTED_AT, 0L),
                    intent.getByteArrayExtra(EXTRA_AVATAR),
                    intent.getByteArrayExtra(EXTRA_PLATFORM_ICON)
                )
            }
            else -> {
                // ACTION_START 或空：启动/更新。首次进入默认视为正在播放。
                intent?.getStringExtra(EXTRA_TITLE)?.let { title = it }
                intent?.getStringExtra(EXTRA_ARTIST)?.let { artist = it }
                intent?.getStringExtra(EXTRA_SOURCE)?.let { sourceName = it }
                startedAtMillis = intent?.getLongExtra(EXTRA_STARTED_AT, 0L) ?: 0L
                avatarBitmap = intent?.getByteArrayExtra(EXTRA_AVATAR)?.let { decodeBitmap(it) }
                platformBitmap =
                    intent?.getByteArrayExtra(EXTRA_PLATFORM_ICON)?.let { decodeBitmap(it) }
                refreshArtwork()
                if (!isForeground) {
                    playbackState = PlaybackState.STATE_PLAYING
                }
            }
        }
        publish()
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        durationHandler.removeCallbacks(durationRefresh)
        mediaSession?.isActive = false
        mediaSession?.release()
        mediaSession = null
        instance = null
        isForeground = false
        super.onDestroy()
    }

    // region MediaSession

    private fun createMediaSession() {
        val session = MediaSession(this, MEDIA_SESSION_TAG)
        session.setFlags(
            MediaSession.FLAG_HANDLES_MEDIA_BUTTONS or
                MediaSession.FLAG_HANDLES_TRANSPORT_CONTROLS
        )
        session.setCallback(object : MediaSession.Callback() {
            override fun onPlay() {
                dispatchCommand("play", playOptimistic = true)
                publish()
            }

            override fun onPause() {
                dispatchCommand("pause", playOptimistic = false)
                publish()
            }

            override fun onSkipToPrevious() {
                dispatchNavigation("previous")
                publish()
            }

            override fun onSkipToNext() {
                dispatchNavigation("next")
                publish()
            }

            override fun onStop() {
                onCommand?.invoke("stop")
                stopPlayback()
            }
        })
        mediaSession = session
        session.isActive = true
    }

    /** 只更新本地状态并回传命令，不直接刷新通知（由调用方统一 publish） */
    private fun dispatchCommand(command: String, playOptimistic: Boolean) {
        playbackState =
            if (playOptimistic) PlaybackState.STATE_PLAYING else PlaybackState.STATE_PAUSED
        onCommand?.invoke(command)
    }

    /** 上一台/下一台不是暂停语义：保持「正在播放」的乐观状态并回传切台命令。 */
    private fun dispatchNavigation(command: String) {
        playbackState = PlaybackState.STATE_PLAYING
        onCommand?.invoke(command)
    }

    private fun applyState(state: String) {
        setStateInternal(state)
        publish()
    }

    private fun setStateInternal(state: String) {
        playbackState = when (state) {
            "playing" -> PlaybackState.STATE_PLAYING
            "paused" -> PlaybackState.STATE_PAUSED
            "buffering" -> PlaybackState.STATE_BUFFERING
            else -> playbackState
        }
    }

    private fun applyMetadata(
        newTitle: String,
        newArtist: String,
        newSource: String,
        newStartedAtMillis: Long,
        avatar: ByteArray?,
        platformIcon: ByteArray?
    ) {
        setMetadataInternal(
            newTitle, newArtist, newSource, newStartedAtMillis, avatar, platformIcon
        )
        publish()
    }

    private fun setMetadataInternal(
        newTitle: String,
        newArtist: String,
        newSource: String,
        newStartedAtMillis: Long,
        avatar: ByteArray?,
        platformIcon: ByteArray?
    ) {
        title = newTitle
        artist = newArtist
        sourceName = newSource
        startedAtMillis = newStartedAtMillis
        // 每次元数据都是完整快照：头像/平台图标为空时要清空，避免切台后残留上一个主播的图。
        avatarBitmap = avatar?.let { decodeBitmap(it) }
        platformBitmap = platformIcon?.let { decodeBitmap(it) }
        refreshArtwork()
    }

    private fun publish() {
        val nowMillis = System.currentTimeMillis()
        pushPlaybackState(nowMillis)
        pushMetadata(nowMillis)
        pushNotification(nowMillis)
        // 位置+1x 速度由系统外推进度；整点余量到期时延长分母。
        // 任意发布都会重排同一个回调，不叠加计时任务。
        durationHandler.removeCallbacks(durationRefresh)
        if (isForeground) {
            LivePlaybackTiming.nextRefreshDelayMillis(startedAtMillis, nowMillis)?.let {
                durationHandler.postDelayed(durationRefresh, it)
            }
        }
    }

    private fun pushPlaybackState(nowMillis: Long) {
        val playing = playbackState == PlaybackState.STATE_PLAYING
        val state = PlaybackState.Builder()
            .setActions(
                PlaybackState.ACTION_PLAY or
                    PlaybackState.ACTION_PAUSE or
                    PlaybackState.ACTION_PLAY_PAUSE or
                    PlaybackState.ACTION_SKIP_TO_PREVIOUS or
                    PlaybackState.ACTION_SKIP_TO_NEXT or
                    PlaybackState.ACTION_STOP
            )
            .setState(
                playbackState,
                LivePlaybackTiming.elapsedMillis(startedAtMillis, nowMillis)
                    ?: PlaybackState.PLAYBACK_POSITION_UNKNOWN,
                if (playing) 1f else 0f,
                SystemClock.elapsedRealtime()
            )
            .build()
        mediaSession?.setPlaybackState(state)
    }

    private fun pushMetadata(nowMillis: Long) {
        val titleText = if (artist.isEmpty()) "Simple Live" else artist
        val durationMillis = LivePlaybackTiming.durationMillis(startedAtMillis, nowMillis)
        val builder = MediaMetadata.Builder()
            // 主行=主播名，副行=平台 · 直播标题；时长在下方进度条实时走时。
            .putString(MediaMetadata.METADATA_KEY_TITLE, titleText)
            .putString(MediaMetadata.METADATA_KEY_DISPLAY_TITLE, titleText)
            .putString(MediaMetadata.METADATA_KEY_ARTIST, metadataSubtitle())
            .putString(MediaMetadata.METADATA_KEY_ALBUM, metadataAlbum())
            // 进度条分母 = 已播 + 余量。实时直播不可 seek，只用于显示。
            // MediaMetadata 的时长单位是毫秒，不能写成秒，否则系统会显示成几秒。
            .putLong(
                MediaMetadata.METADATA_KEY_DURATION,
                durationMillis ?: 0L
            )
        artworkBitmap?.let {
            builder.putBitmap(MediaMetadata.METADATA_KEY_ALBUM_ART, it)
            builder.putBitmap(MediaMetadata.METADATA_KEY_ART, it)
        }
        mediaSession?.setMetadata(builder.build())
    }

    private fun metadataSubtitle(): String {
        return when {
            sourceName.isNotEmpty() && title.isNotEmpty() -> "$sourceName · $title"
            title.isNotEmpty() -> title
            sourceName.isNotEmpty() -> "$sourceName · 正在直播"
            else -> "正在直播"
        }
    }

    private fun metadataAlbum(): String {
        return if (sourceName.isNotEmpty()) "$sourceName · 正在直播" else "正在直播"
    }

    private fun decodeBitmap(bytes: ByteArray): Bitmap? {
        return try {
            BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
        } catch (e: Exception) {
            null
        }
    }

    private fun refreshArtwork() {
        artworkBitmap = if (avatarBitmap != null || platformBitmap != null) {
            composeArtwork(avatarBitmap, platformBitmap)
        } else {
            null
        }
    }

    /** 头像居中裁成正方形，右下角叠一个白色圆底平台图标角标。 */
    private fun composeArtwork(avatar: Bitmap?, badge: Bitmap?): Bitmap {
        val size = 256
        val output = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(output)
        if (avatar != null) {
            canvas.drawBitmap(centerCrop(avatar, size, size), 0f, 0f, null)
        } else {
            canvas.drawColor(Color.rgb(38, 38, 38))
        }
        if (badge != null) {
            val badgeSize = (size * 0.34f).roundToInt()
            val margin = (size * 0.045f).roundToInt()
            val left = size - badgeSize - margin
            val top = size - badgeSize - margin
            val centerX = left + badgeSize / 2f
            val centerY = top + badgeSize / 2f
            val background = Paint(Paint.ANTI_ALIAS_FLAG).apply {
                color = Color.WHITE
                style = Paint.Style.FILL
            }
            canvas.drawCircle(centerX, centerY, badgeSize / 2f + margin * 0.35f, background)
            val fitted = fitCenter(badge, badgeSize, badgeSize)
            val dx = left + (badgeSize - fitted.width) / 2f
            val dy = top + (badgeSize - fitted.height) / 2f
            canvas.drawBitmap(fitted, dx, dy, null)
        }
        return output
    }

    private fun centerCrop(source: Bitmap, width: Int, height: Int): Bitmap {
        val scale = max(width.toFloat() / source.width, height.toFloat() / source.height)
        val scaledWidth = (source.width * scale).roundToInt().coerceAtLeast(width)
        val scaledHeight = (source.height * scale).roundToInt().coerceAtLeast(height)
        val scaled = Bitmap.createScaledBitmap(source, scaledWidth, scaledHeight, true)
        val x = (scaledWidth - width) / 2
        val y = (scaledHeight - height) / 2
        return Bitmap.createBitmap(scaled, x, y, width, height)
    }

    private fun fitCenter(source: Bitmap, maxWidth: Int, maxHeight: Int): Bitmap {
        val scale = min(
            maxWidth.toFloat() / source.width,
            maxHeight.toFloat() / source.height
        )
        val width = (source.width * scale).roundToInt().coerceIn(1, maxWidth)
        val height = (source.height * scale).roundToInt().coerceIn(1, maxHeight)
        return Bitmap.createScaledBitmap(source, width, height, true)
    }

    // endregion

    // region Notification

    private fun pushNotification(nowMillis: Long) {
        createChannel()
        val notification = buildNotification(nowMillis)
        if (!isForeground) {
            startForegroundCompat(notification)
            isForeground = true
        } else {
            val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            manager.notify(NOTIFICATION_ID, notification)
        }
    }

    private fun startForegroundCompat(notification: Notification) {
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

    private fun buildNotification(nowMillis: Long): Notification {
        val contentIntent = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
            },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val playing = playbackState == PlaybackState.STATE_PLAYING
        val toggleAction = if (playing) {
            buildAction(
                android.R.drawable.ic_media_pause,
                "暂停",
                servicePendingIntent(ACTION_PAUSE, 1)
            )
        } else {
            buildAction(
                android.R.drawable.ic_media_play,
                "播放",
                servicePendingIntent(ACTION_PLAY, 2)
            )
        }
        val previousAction = buildAction(
            android.R.drawable.ic_media_previous,
            "上一台",
            servicePendingIntent(ACTION_PREVIOUS, 4)
        )
        val nextAction = buildAction(
            android.R.drawable.ic_media_next,
            "下一台",
            servicePendingIntent(ACTION_NEXT, 5)
        )
        val stopAction = buildAction(
            android.R.drawable.ic_menu_close_clear_cancel,
            "停止",
            servicePendingIntent(ACTION_STOP, 3)
        )

        val titleText = if (artist.isEmpty()) "Simple Live" else artist
        val subtitleText = metadataSubtitle()

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        builder
            .setSmallIcon(R.drawable.ic_stat_playback)
            .setContentTitle(titleText)
            .setContentText(subtitleText)
            .setSubText(if (sourceName.isNotEmpty()) sourceName else "Simple Live")
            .setLargeIcon(artworkBitmap)
            .setContentIntent(contentIntent)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .setCategory(Notification.CATEGORY_TRANSPORT)
            .addAction(previousAction)
            .addAction(toggleAction)
            .addAction(nextAction)
            .addAction(stopAction)
            .setStyle(
                Notification.MediaStyle()
                    .setMediaSession(mediaSession?.sessionToken)
                    .setShowActionsInCompactView(0, 1, 2)
            )
        // 系统计时从直播间开播时刻算起，不是本机开始观看时刻；时钟偏差不倒计时。
        if (startedAtMillis > 0L) {
            builder.setWhen(minOf(startedAtMillis, nowMillis))
                .setShowWhen(true)
                .setUsesChronometer(true)
                .setChronometerCountDown(false)
        } else {
            builder.setShowWhen(false)
        }
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            @Suppress("DEPRECATION")
            builder.setPriority(Notification.PRIORITY_LOW)
        }
        return builder.build()
    }

    @Suppress("DEPRECATION")
    private fun buildAction(icon: Int, title: String, intent: PendingIntent): Notification.Action {
        return Notification.Action.Builder(icon, title, intent).build()
    }

    private fun servicePendingIntent(action: String, requestCode: Int): PendingIntent {
        val intent = Intent(this, PlaybackService::class.java).apply {
            this.action = action
        }
        return PendingIntent.getService(
            this,
            requestCode,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
    }

    private fun stopPlayback() {
        durationHandler.removeCallbacks(durationRefresh)
        startedAtMillis = 0L
        mediaSession?.isActive = false
        isForeground = false
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
        stopSelf()
    }

    // endregion
}
