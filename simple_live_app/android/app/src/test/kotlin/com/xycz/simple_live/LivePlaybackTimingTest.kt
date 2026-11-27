package com.xycz.simple_live

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class LivePlaybackTimingTest {
    private val start = 1_790_000_000_000L

    @Test
    fun unknownStartDoesNotInventALiveDuration() {
        for (invalid in listOf(0L, -1L)) {
            assertNull(LivePlaybackTiming.elapsedMillis(invalid, start))
            assertNull(LivePlaybackTiming.durationMillis(invalid, start))
            assertNull(LivePlaybackTiming.nextRefreshDelayMillis(invalid, start))
        }
    }

    @Test
    fun elapsedUsesBroadcastStartNotWhenPlaybackOpened() {
        val now = start + (3 * 60 + 15) * 60_000L + 45_123L
        assertEquals(11_745_123L, LivePlaybackTiming.elapsedMillis(start, now))
        // 分母只比已播多一小时余量，进度条才不会一开始就顶满。
        assertEquals(11_745_123L + 3_600_000L, LivePlaybackTiming.durationMillis(start, now))
        assertEquals(3_600_000L - 11_745_123L % 3_600_000L,
            LivePlaybackTiming.nextRefreshDelayMillis(start, now))
    }

    @Test
    fun durationExtendsAtEachHeadroomBoundary() {
        val atBoundary = start + 3_600_000L
        assertEquals(3_600_000L, LivePlaybackTiming.elapsedMillis(start, atBoundary))
        assertEquals(7_200_000L, LivePlaybackTiming.durationMillis(start, atBoundary))
        assertEquals(3_600_000L, LivePlaybackTiming.nextRefreshDelayMillis(start, atBoundary))
    }

    @Test
    fun longBroadcastKeepsPositionBelowDuration() {
        val now = start + 27 * 3_600_000L + 5 * 60_000L
        val elapsed = LivePlaybackTiming.elapsedMillis(start, now)!!
        val duration = LivePlaybackTiming.durationMillis(start, now)!!
        assertEquals(elapsed + 3_600_000L, duration)
        assert(duration > elapsed)
    }

    @Test
    fun futureStartIsClampedInsteadOfShowingNegativePosition() {
        assertEquals(0L, LivePlaybackTiming.elapsedMillis(start, start - 30_000L))
        assertEquals(3_600_000L, LivePlaybackTiming.durationMillis(start, start - 30_000L))
        assertEquals(3_600_000L, LivePlaybackTiming.nextRefreshDelayMillis(start, start - 30_000L))
    }
}
