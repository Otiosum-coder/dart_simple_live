package com.xycz.simple_live

/**
 * 直播没有可 seek 的总时长：用「已播 + 余量」作为进度条分母，
 * 已播时长作为播放位置并按 1x 速度由系统自行外推，进度条就会实时走时。
 */
internal object LivePlaybackTiming {
    /** 进度条分母相对已播时长的余量；到点后自动延长，避免长播把进度条顶满。 */
    private const val HEADROOM_MILLIS = 3_600_000L

    fun elapsedMillis(startedAtMillis: Long, nowMillis: Long): Long? {
        if (startedAtMillis <= 0L) return null
        // 服务端与设备时钟有偏差时，不显示负数。
        return (nowMillis - startedAtMillis).coerceAtLeast(0L)
    }

    fun durationMillis(startedAtMillis: Long, nowMillis: Long): Long? {
        val elapsed = elapsedMillis(startedAtMillis, nowMillis) ?: return null
        return elapsed + HEADROOM_MILLIS
    }

    /** 下一次延长分母的时间：已播时长跨过整点余量时。 */
    fun nextRefreshDelayMillis(startedAtMillis: Long, nowMillis: Long): Long? {
        val elapsed = elapsedMillis(startedAtMillis, nowMillis) ?: return null
        return HEADROOM_MILLIS - elapsed % HEADROOM_MILLIS
    }
}
