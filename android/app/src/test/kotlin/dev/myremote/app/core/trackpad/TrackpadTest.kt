package dev.myremote.app.core.trackpad

import dev.myremote.app.core.protocol.MouseButton
import kotlin.math.hypot
import kotlin.random.Random
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class PointerAccelerationTest {
    private val acceleration = PointerAcceleration()

    @Test
    fun gainNeverDecreasesAsSpeedIncreases() {
        var previous = 0.0
        var speed = 0.0
        while (speed <= 5.0) {
            val gain = acceleration.gain(speed)
            assertTrue("gain dropped at speed $speed: $previous -> $gain", gain >= previous)
            previous = gain
            speed += 0.001
        }
    }

    @Test
    fun gainIsBoundedAndReachesBothBounds() {
        assertEquals(acceleration.minGain, acceleration.gain(0.0), 0.0)
        assertEquals(acceleration.minGain, acceleration.gain(acceleration.lowSpeed), 0.0)
        assertEquals(acceleration.maxGain, acceleration.gain(acceleration.highSpeed), 0.0)
        assertEquals(acceleration.maxGain, acceleration.gain(1_000.0), 0.0)
        assertTrue(acceleration.gain((acceleration.lowSpeed + acceleration.highSpeed) / 2) > acceleration.minGain)
    }

    @Test
    fun aLongerMovementInTheSameTimeAlwaysMovesTheCursorFurther() {
        var previous = 0.0
        var distance = 0.05
        while (distance <= 60.0) {
            val (dx, dy) = acceleration.apply(distance, 0.0, dtMs = 8)
            assertEquals(0.0, dy, 0.0)
            assertTrue("output not strictly increasing at $distance dp", dx > previous)
            previous = dx
            distance += 0.05
        }
    }

    @Test
    fun theSameMovementDoneFasterMovesTheCursorAtLeastAsFar() {
        var previous = Double.MAX_VALUE
        for (dt in 1L..200L) {
            val (dx, _) = acceleration.apply(10.0, 0.0, dt)
            assertTrue("slower movement (dt=$dt) went further", dx <= previous)
            previous = dx
        }
    }

    @Test
    fun directionIsPreservedAndZeroTimeDoesNotBlowUp() {
        val (dx, dy) = acceleration.apply(-3.0, 4.0, dtMs = 10)
        assertTrue(dx < 0 && dy > 0)
        assertEquals(-3.0 / 4.0, dx / dy, 1e-12)
        val (zx, zy) = acceleration.apply(3.0, 4.0, dtMs = 0)
        assertTrue(zx.isFinite() && zy.isFinite())
    }
}

class DeltaCoalescerTest {
    @Test
    fun totalDisplacementIsPreservedExactlyWhateverTheEventTiming() {
        val random = Random(42)
        repeat(50) {
            val coalescer = DeltaCoalescer(minIntervalMs = 16)
            var inX = 0.0
            var inY = 0.0
            var outX = 0.0
            var outY = 0.0
            var now = 1_000L
            repeat(400) {
                // Quarter-unit steps keep every partial sum exactly representable.
                val dx = random.nextInt(-40, 41) / 4.0
                val dy = random.nextInt(-40, 41) / 4.0
                now += random.nextLong(0, 12)
                inX += dx
                inY += dy
                coalescer.add(dx, dy, now)?.let { (x, y) ->
                    outX += x
                    outY += y
                }
            }
            coalescer.flush(now)?.let { (x, y) ->
                outX += x
                outY += y
            }
            assertEquals(inX, outX, 0.0)
            assertEquals(inY, outY, 0.0)
            assertNull("nothing may be left after flush", coalescer.flush(now))
        }
    }

    @Test
    fun emitsAtMostOncePerInterval() {
        val coalescer = DeltaCoalescer(minIntervalMs = 16)
        val emitTimes = ArrayList<Long>()
        // A 240 Hz touch stream for one second.
        var now = 0L
        var step = 0
        while (now < 1_000) {
            if (coalescer.add(1.0, 0.5, now) != null) emitTimes += now
            now = (++step * 1000L) / 240
        }
        assertTrue("got ${emitTimes.size} messages in one second", emitTimes.size <= 63)
        assertTrue("coalescing should not starve the stream either: ${emitTimes.size}", emitTimes.size >= 50)
        assertTrue(emitTimes.zipWithNext().all { (a, b) -> b - a >= 16 })
    }

    @Test
    fun subFrameMovementIsAccumulatedNotDropped() {
        val coalescer = DeltaCoalescer(minIntervalMs = 16)
        assertEquals(1.0 to 1.0, coalescer.add(1.0, 1.0, nowMs = 100))
        assertNull(coalescer.add(0.25, 0.0, nowMs = 104))
        assertNull(coalescer.add(0.25, -0.5, nowMs = 108))
        assertEquals(116L, coalescer.dueAtMs)
        assertNull(coalescer.poll(nowMs = 115))
        assertEquals(0.5 to -0.5, coalescer.poll(nowMs = 116))
        assertNull(coalescer.dueAtMs)
        assertNull(coalescer.poll(nowMs = 200))
    }
}

class TrackpadGestureProcessorTest {
    private val config = TrackpadConfig()
    private val pad = TrackpadGestureProcessor(config)
    private val left1 = TrackpadAction.Click(MouseButton.Left, 1)
    private val left2 = TrackpadAction.Click(MouseButton.Left, 2)
    private val right1 = TrackpadAction.Click(MouseButton.Right, 1)

    private fun tap(id: Long, x: Double, y: Double, downAt: Long, upAt: Long): List<TrackpadAction> =
        pad.onDown(id, x, y, downAt) + pad.onUp(id, upAt)

    /** Drags finger [id] in a straight line and returns everything produced, including on lift. */
    private fun drag(id: Long, fromX: Double, fromY: Double, toX: Double, toY: Double, startAt: Long, steps: Int, stepMs: Long): List<TrackpadAction> {
        val out = ArrayList<TrackpadAction>()
        out += pad.onDown(id, fromX, fromY, startAt)
        for (i in 1..steps) {
            val f = i.toDouble() / steps
            out += pad.onMove(id, fromX + (toX - fromX) * f, fromY + (toY - fromY) * f, startAt + i * stepMs)
        }
        out += pad.onUp(id, startAt + (steps + 1) * stepMs)
        return out
    }

    @Test
    fun tapBecomesOneLeftClickOnceTheDoubleTapWindowHasPassed() {
        assertEquals(emptyList<TrackpadAction>(), tap(1, 100.0, 100.0, downAt = 0, upAt = 60))
        assertEquals(60 + config.doubleTapWindowMs + 1, pad.nextDeadlineMs())
        assertEquals(emptyList<TrackpadAction>(), pad.onTick(60 + config.doubleTapWindowMs))
        assertEquals(listOf(left1), pad.onTick(60 + config.doubleTapWindowMs + 1))
        assertNull(pad.nextDeadlineMs())
        assertEquals(emptyList<TrackpadAction>(), pad.onTick(10_000))
    }

    @Test
    fun aSlightlyWobblyTapIsStillATapAndDoesNotMoveTheCursor() {
        val out = pad.onDown(1, 100.0, 100.0, 0) +
            pad.onMove(1, 103.0, 104.0, 20) +
            pad.onMove(1, 105.0, 106.0, 40) +
            pad.onUp(1, 70) +
            pad.onTick(1_000)
        assertEquals(listOf(left1), out)
    }

    @Test
    fun doubleTapBecomesExactlyOneDoubleClickAndNoSingleClick() {
        val out = tap(1, 100.0, 100.0, downAt = 0, upAt = 50) +
            tap(2, 110.0, 95.0, downAt = 180, upAt = 230) +
            pad.onTick(5_000)
        assertEquals(listOf(left2), out)
        assertNull(pad.nextDeadlineMs())
    }

    @Test
    fun twoSeparateTapsFarApartInTimeAreTwoSingleClicks() {
        val out = tap(1, 100.0, 100.0, downAt = 0, upAt = 50) +
            pad.onTick(400) +
            tap(2, 100.0, 100.0, downAt = 900, upAt = 950) +
            pad.onTick(2_000)
        assertEquals(listOf(left1, left1), out)
    }

    @Test
    fun aSecondTapSomewhereElseIsNotADoubleClick() {
        val out = tap(1, 20.0, 20.0, downAt = 0, upAt = 50) +
            tap(2, 250.0, 200.0, downAt = 150, upAt = 200) +
            pad.onTick(2_000)
        assertEquals(listOf(left1, left1), out)
    }

    @Test
    fun tapThenDragClicksOnceThenMoves() {
        val out = tap(1, 100.0, 100.0, downAt = 0, upAt = 50) +
            drag(2, 100.0, 100.0, 200.0, 100.0, startAt = 150, steps = 20, stepMs = 16)
        assertEquals(left1, out.first())
        assertTrue(out.drop(1).isNotEmpty())
        assertTrue(out.drop(1).all { it is TrackpadAction.Move })
    }

    @Test
    fun tapThenLongPressClicksOnceWhenTheSecondPressStopsBeingATap() {
        val out = ArrayList<TrackpadAction>()
        out += tap(1, 100.0, 100.0, downAt = 0, upAt = 50)
        out += pad.onDown(2, 100.0, 100.0, 150)
        assertEquals(150 + config.tapTimeoutMs + 1, pad.nextDeadlineMs())
        out += pad.onTick(150 + config.tapTimeoutMs + 1)
        assertEquals(listOf(left1), out)
        assertEquals(emptyList<TrackpadAction>(), pad.onUp(2, 2_000) + pad.onTick(5_000))
    }

    @Test
    fun longPressIsNotAClick() {
        assertEquals(emptyList<TrackpadAction>(), tap(1, 100.0, 100.0, downAt = 0, upAt = config.tapTimeoutMs + 1) + pad.onTick(5_000))
    }

    @Test
    fun twoFingerTapIsARightClickRegardlessOfLiftOrder() {
        val simultaneous = pad.onDown(1, 100.0, 100.0, 0) + pad.onDown(2, 160.0, 100.0, 10) +
            pad.onUp(1, 80) + pad.onUp(2, 90) + pad.onTick(5_000)
        assertEquals(listOf(right1), simultaneous)

        val reversed = pad.onDown(3, 100.0, 100.0, 6_000) + pad.onDown(4, 160.0, 100.0, 6_030) +
            pad.onMove(3, 102.0, 101.0, 6_040) +
            pad.onUp(4, 6_100) + pad.onUp(3, 6_120) + pad.onTick(9_000)
        assertEquals(listOf(right1), reversed)
    }

    @Test
    fun twoFingerLongPressIsNothing() {
        val out = pad.onDown(1, 100.0, 100.0, 0) + pad.onDown(2, 160.0, 100.0, 10) +
            pad.onUp(1, 600) + pad.onUp(2, 610) + pad.onTick(5_000)
        assertEquals(emptyList<TrackpadAction>(), out)
    }

    @Test
    fun oneFingerDragMovesTheCursorAndNeverClicks() {
        val out = drag(1, 50.0, 50.0, 250.0, 150.0, startAt = 0, steps = 50, stepMs = 8) + pad.onTick(5_000)
        assertTrue(out.isNotEmpty())
        assertTrue("only moves expected: $out", out.all { it is TrackpadAction.Move })
        val moves = out.filterIsInstance<TrackpadAction.Move>()
        val sumX = moves.sumOf { it.dx }
        val sumY = moves.sumOf { it.dy }
        assertTrue(sumX > 0 && sumY > 0)
        assertEquals("direction preserved", 0.5, sumY / sumX, 1e-9)

        // Each 8 ms step covers hypot(4, 2) dp, i.e. a constant speed, so the gain is one known value.
        val gain = config.acceleration.gain(hypot(4.0, 2.0) / 8)
        // The first tapSlopDp of travel only establish that this is a drag and are not sent.
        val slopSteps = 3 // 3 steps = 13.4 dp > 10 dp slop
        assertEquals((200.0 - slopSteps * 4.0) * gain, sumX, 1e-9)
        assertEquals((100.0 - slopSteps * 2.0) * gain, sumY, 1e-9)
    }

    @Test
    fun dragOutputIsCoalescedToAboutSixtyMessagesPerSecondWithoutLosingDistance() {
        // 1 second of movement sampled at 250 Hz.
        val out = drag(1, 0.0, 0.0, 500.0, 0.0, startAt = 0, steps = 250, stepMs = 4)
        val moves = out.filterIsInstance<TrackpadAction.Move>()
        assertTrue("sent ${moves.size} pointer messages for one second of movement", moves.size in 50..64)
        val gain = config.acceleration.gain(2.0 / 4)
        val slopSteps = 6 // 6 steps = 12 dp > 10 dp slop
        assertEquals((500.0 - slopSteps * 2.0) * gain, moves.sumOf { it.dx }, 1e-6)
    }

    @Test
    fun movementLeftOverBetweenFramesIsReleasedByTick() {
        pad.onDown(1, 0.0, 0.0, 0)
        pad.onMove(1, 20.0, 0.0, 10)
        assertEquals(1, pad.onMove(1, 30.0, 0.0, 20).size)
        // Arrives 4 ms after the previous message: held back, with a deadline for releasing it.
        assertEquals(emptyList<TrackpadAction>(), pad.onMove(1, 33.0, 0.0, 24))
        assertEquals(36L, pad.nextDeadlineMs())
        assertEquals(emptyList<TrackpadAction>(), pad.onTick(35))
        val released = pad.onTick(36).single() as TrackpadAction.Move
        assertEquals(3.0 * config.acceleration.gain(3.0 / 4), released.dx, 1e-9)
        assertNull(pad.nextDeadlineMs())
    }

    @Test
    fun twoFingerDragScrollsAndNeverClicksOrMovesTheCursor() {
        val out = ArrayList<TrackpadAction>()
        out += pad.onDown(1, 100.0, 300.0, 0)
        out += pad.onDown(2, 160.0, 300.0, 10)
        // Both fingers travel 100 dp up and 20 dp left over 400 ms.
        for (i in 1..25) {
            val t = 10 + i * 16L
            out += pad.onMove(1, 100.0 - i * 0.8, 300.0 - i * 4.0, t)
            out += pad.onMove(2, 160.0 - i * 0.8, 300.0 - i * 4.0, t)
        }
        out += pad.onUp(1, 430)
        // The straggling finger wanders before lifting: must not move the cursor.
        out += pad.onMove(2, 200.0, 250.0, 440)
        out += pad.onUp(2, 450)
        out += pad.onTick(5_000)

        assertTrue(out.isNotEmpty())
        assertTrue("only scrolls expected: $out", out.all { it is TrackpadAction.Scroll })
        val scrolls = out.filterIsInstance<TrackpadAction.Scroll>()
        // Natural scrolling: fingers up => positive dy (wheel down), fingers left => positive dx.
        // The centroid travel up to the moment the slop was crossed is not sent: that happens when
        // finger 1 makes its third step while finger 2 has made two, i.e. 2.5 steps of the centroid.
        assertEquals((100.0 - 2.5 * 4.0) * config.scrollGain, scrolls.sumOf { it.dy }, 1e-9)
        assertEquals((20.0 - 2.5 * 0.8) * config.scrollGain, scrolls.sumOf { it.dx }, 1e-9)
    }

    @Test
    fun scrollDirectionCanBeInverted() {
        val inverted = TrackpadGestureProcessor(config.copy(naturalScroll = false))
        val out = ArrayList<TrackpadAction>()
        out += inverted.onDown(1, 100.0, 300.0, 0)
        out += inverted.onDown(2, 160.0, 300.0, 5)
        for (i in 1..10) {
            out += inverted.onMove(1, 100.0, 300.0 - i * 5.0, 5 + i * 16L)
            out += inverted.onMove(2, 160.0, 300.0 - i * 5.0, 5 + i * 16L)
        }
        out += inverted.onUp(1, 200)
        out += inverted.onUp(2, 205)
        assertTrue(out.filterIsInstance<TrackpadAction.Scroll>().sumOf { it.dy } < 0)
    }

    @Test
    fun addingASecondFingerMidDragSwitchesFromMovingToScrolling() {
        val out = ArrayList<TrackpadAction>()
        out += pad.onDown(1, 100.0, 100.0, 0)
        for (i in 1..10) out += pad.onMove(1, 100.0 + i * 5.0, 100.0, i * 16L)
        val movesBefore = out.size
        assertTrue(out.all { it is TrackpadAction.Move })
        out += pad.onDown(2, 200.0, 160.0, 170)
        for (i in 1..10) {
            out += pad.onMove(1, 150.0, 100.0 + i * 5.0, 170 + i * 16L)
            out += pad.onMove(2, 200.0, 160.0 + i * 5.0, 170 + i * 16L)
        }
        out += pad.onUp(1, 400)
        out += pad.onUp(2, 410)
        val after = out.drop(movesBefore)
        assertTrue("no clicks at all: $out", out.none { it is TrackpadAction.Click })
        assertTrue("only scrolling once the second finger is down: $after", after.all { it is TrackpadAction.Scroll })
        // Fingers moved down, so with natural scrolling the wheel goes up: negative dy.
        assertTrue(after.filterIsInstance<TrackpadAction.Scroll>().sumOf { it.dy } < 0)
    }

    @Test
    fun threeFingersDoNothing() {
        val out = pad.onDown(1, 100.0, 100.0, 0) + pad.onDown(2, 150.0, 100.0, 5) + pad.onDown(3, 200.0, 100.0, 10) +
            pad.onMove(1, 100.0, 200.0, 50) + pad.onMove(2, 150.0, 200.0, 50) + pad.onMove(3, 200.0, 200.0, 50) +
            pad.onUp(1, 100) + pad.onUp(2, 105) + pad.onUp(3, 110) + pad.onTick(5_000)
        assertEquals(emptyList<TrackpadAction>(), out)
    }

    @Test
    fun cancelDeliversPendingMovementButNoClick() {
        pad.onDown(1, 0.0, 0.0, 0)
        pad.onMove(1, 20.0, 0.0, 10)
        pad.onMove(1, 30.0, 0.0, 20)
        pad.onMove(1, 33.0, 0.0, 24)
        val out = pad.onCancel(25)
        assertEquals(1, out.size)
        assertTrue(out.single() is TrackpadAction.Move)
        assertEquals(emptyList<TrackpadAction>(), pad.onTick(5_000))
        // The processor is usable again afterwards.
        assertEquals(listOf(left1), tap(2, 10.0, 10.0, 6_000, 6_050) + pad.onTick(9_000))
    }
}
