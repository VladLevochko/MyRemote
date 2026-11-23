package dev.myremote.app.core.trackpad

import dev.myremote.app.core.protocol.MouseButton
import kotlin.math.hypot

/** What the trackpad wants sent to the agent. */
sealed interface TrackpadAction {
    /** Relative cursor movement in Mac screen points (`pointer`). */
    data class Move(val dx: Double, val dy: Double) : TrackpadAction

    /** Scroll in pixels, already in the protocol's sign convention (`scroll`). */
    data class Scroll(val dx: Double, val dy: Double) : TrackpadAction

    /** `click` with `count` 1 or 2. */
    data class Click(val button: MouseButton, val count: Int) : TrackpadAction
}

/**
 * Pointer acceleration: slow finger movement maps close to 1:1 for precision, fast movement is
 * amplified so one swipe can cross a TV-sized screen.
 *
 * The gain rises smoothly (smoothstep) from [minGain] at [lowSpeed] to [maxGain] at [highSpeed]
 * and is constant outside that range, so it never decreases as speed increases.
 * Speeds are in dp per millisecond.
 */
class PointerAcceleration(
    val minGain: Double = 1.2,
    val maxGain: Double = 5.0,
    val lowSpeed: Double = 0.1,
    val highSpeed: Double = 1.6,
) {
    init {
        require(minGain > 0 && maxGain >= minGain && lowSpeed >= 0 && highSpeed > lowSpeed)
    }

    fun gain(speedDpPerMs: Double): Double {
        val x = ((speedDpPerMs - lowSpeed) / (highSpeed - lowSpeed)).coerceIn(0.0, 1.0)
        val eased = x * x * (3 - 2 * x)
        return minGain + (maxGain - minGain) * eased
    }

    /** Scales a finger delta in dp, measured over [dtMs], into Mac screen points. */
    fun apply(dxDp: Double, dyDp: Double, dtMs: Long): Pair<Double, Double> {
        val g = gain(hypot(dxDp, dyDp) / dtMs.coerceAtLeast(1))
        return dxDp * g to dyDp * g
    }
}

/**
 * Limits output to one delta per [minIntervalMs] by summing whatever arrives in between. Nothing
 * is dropped: the sum of everything returned equals the sum of everything added, once
 * [flush] has been called.
 */
class DeltaCoalescer(private val minIntervalMs: Long) {
    private var x = 0.0
    private var y = 0.0
    private var lastEmitMs: Long? = null

    val hasPending: Boolean get() = x != 0.0 || y != 0.0

    /** Time at which [poll] will release the pending delta, or null if nothing is pending. */
    val dueAtMs: Long? get() = if (hasPending) (lastEmitMs?.plus(minIntervalMs) ?: Long.MIN_VALUE) else null

    /** Adds a delta and returns the accumulated one if the interval allows sending now. */
    fun add(dx: Double, dy: Double, nowMs: Long): Pair<Double, Double>? {
        x += dx
        y += dy
        return poll(nowMs)
    }

    /** Returns the accumulated delta if there is one and the interval has elapsed. */
    fun poll(nowMs: Long): Pair<Double, Double>? {
        val last = lastEmitMs
        if (!hasPending || (last != null && nowMs - last < minIntervalMs)) return null
        return take(nowMs)
    }

    /** Returns whatever is pending regardless of the interval. Used when a gesture ends. */
    fun flush(nowMs: Long): Pair<Double, Double>? = if (hasPending) take(nowMs) else null

    private fun take(nowMs: Long): Pair<Double, Double> {
        val out = x to y
        x = 0.0
        y = 0.0
        lastEmitMs = nowMs
        return out
    }
}

data class TrackpadConfig(
    /** Movement below this, in dp, still counts as a tap and does not move the cursor. */
    val tapSlopDp: Double = 10.0,
    /** Longest press, in ms, that still counts as a tap. */
    val tapTimeoutMs: Long = 250,
    /** A second tap must start within this long after the first one ended to form a double tap. */
    val doubleTapWindowMs: Long = 250,
    /** A second tap must land within this distance, in dp, of the first. */
    val doubleTapSlopDp: Double = 48.0,
    /** Minimum spacing of `pointer`/`scroll` messages: 16 ms is about 60 per second. */
    val minIntervalMs: Long = 16,
    /** Scroll pixels per dp of two-finger movement. */
    val scrollGain: Double = 3.0,
    /**
     * When true the content follows the fingers, like a touchscreen or a Mac trackpad's default:
     * dragging two fingers up produces positive `dy` (wheel down), revealing what is below.
     */
    val naturalScroll: Boolean = true,
    val acceleration: PointerAcceleration = PointerAcceleration(),
)

/**
 * Turns raw touches on the trackpad surface into [TrackpadAction]s.
 *
 * - one finger dragging: cursor movement, accelerated and coalesced;
 * - one-finger tap: left click; two taps in quick succession: one double click;
 * - two-finger tap: right click;
 * - two fingers dragging: scroll, coalesced.
 *
 * A single tap is reported only once the double-tap window has passed, so that a double tap
 * produces exactly one `click` with `count: 2` and no stray single click before it. Because of
 * that, and because coalescing can leave movement waiting for its time slot, the owner must call
 * [onTick] no later than [nextDeadlineMs] when no touch event arrives before then.
 *
 * Coordinates are in dp and times in milliseconds of any monotonic clock. This class has no
 * Android dependencies and is not thread-safe.
 */
class TrackpadGestureProcessor(private val config: TrackpadConfig = TrackpadConfig()) {
    private class Finger(val startX: Double, val startY: Double) {
        var x = startX
        var y = startY
        var lastMoveMs = 0L

        fun travelled() = hypot(x - startX, y - startY)
    }

    private enum class Mode {
        /** No fingers down. */
        Idle,

        /** One finger down that has not moved beyond the slop: still a possible tap. */
        OneFingerPending,

        /** One finger moving the cursor. */
        Moving,

        /** Two fingers down that have not moved beyond the slop: still a possible two-finger tap. */
        TwoFingerPending,

        /** Two fingers scrolling. */
        Scrolling,

        /** Nothing more can come of this gesture; wait for all fingers to lift. */
        Spent,
    }

    private class PendingTap(val upMs: Long, val x: Double, val y: Double)

    private val fingers = LinkedHashMap<Long, Finger>()
    private var mode = Mode.Idle
    private var gestureStartMs = 0L
    private var lastX = 0.0
    private var lastY = 0.0

    /** A completed single tap waiting to see whether a second one follows. */
    private var pendingTap: PendingTap? = null

    /** The current one-finger press started soon enough after [pendingTap] to become a double tap. */
    private var secondTap = false

    private val moves = DeltaCoalescer(config.minIntervalMs)
    private val scrolls = DeltaCoalescer(config.minIntervalMs)

    fun onDown(id: Long, x: Double, y: Double, timeMs: Long): List<TrackpadAction> {
        val out = ArrayList<TrackpadAction>(1)
        val first = fingers.isEmpty()
        fingers[id] = Finger(x, y).also { it.lastMoveMs = timeMs }
        if (first) {
            gestureStartMs = timeMs
            mode = Mode.OneFingerPending
            val tap = pendingTap
            if (tap != null) {
                val near = hypot(x - tap.x, y - tap.y) <= config.doubleTapSlopDp
                if (near && timeMs - tap.upMs <= config.doubleTapWindowMs) {
                    secondTap = true
                } else {
                    resolvePendingTap(out)
                }
            }
            return out
        }

        // A further finger joined: whatever the first finger was doing ends here.
        resolvePendingTap(out)
        flushMoves(timeMs, out)
        mode = when {
            // A still one-finger press joined by a second finger: a possible two-finger tap.
            fingers.size == 2 && mode == Mode.OneFingerPending -> Mode.TwoFingerPending
            // The first finger was already moving, so this cannot be a tap: scroll straight away.
            fingers.size == 2 && mode == Mode.Moving -> Mode.Scrolling
            else -> {
                flushScrolls(timeMs, out)
                Mode.Spent
            }
        }
        anchorCentroid()
        return out
    }

    fun onMove(id: Long, x: Double, y: Double, timeMs: Long): List<TrackpadAction> {
        val finger = fingers[id] ?: return emptyList()
        val out = ArrayList<TrackpadAction>(1)
        val previousMs = finger.lastMoveMs
        finger.x = x
        finger.y = y
        finger.lastMoveMs = timeMs
        when (mode) {
            Mode.OneFingerPending -> if (finger.travelled() > config.tapSlopDp) {
                // The first tap, if any, stands on its own: this press became a drag.
                resolvePendingTap(out)
                mode = Mode.Moving
                lastX = x
                lastY = y
            }

            Mode.Moving -> {
                val (dx, dy) = config.acceleration.apply(x - lastX, y - lastY, timeMs - previousMs)
                lastX = x
                lastY = y
                moves.add(dx, dy, timeMs)?.let { out += TrackpadAction.Move(it.first, it.second) }
            }

            Mode.TwoFingerPending -> if (fingers.size < 2) {
                // One of the two fingers already lifted; a moving leftover finger is not a tap.
                if (finger.travelled() > config.tapSlopDp) mode = Mode.Spent
            } else if (fingers.values.any { it.travelled() > config.tapSlopDp }) {
                mode = Mode.Scrolling
                anchorCentroid()
            }

            Mode.Scrolling -> {
                val (cx, cy) = centroid()
                val sign = if (config.naturalScroll) -1.0 else 1.0
                val dx = (cx - lastX) * config.scrollGain * sign
                val dy = (cy - lastY) * config.scrollGain * sign
                lastX = cx
                lastY = cy
                scrolls.add(dx, dy, timeMs)?.let { out += TrackpadAction.Scroll(it.first, it.second) }
            }

            Mode.Idle, Mode.Spent -> Unit
        }
        return out
    }

    fun onUp(id: Long, timeMs: Long): List<TrackpadAction> {
        val finger = fingers.remove(id) ?: return emptyList()
        val out = ArrayList<TrackpadAction>(1)
        val quick = timeMs - gestureStartMs <= config.tapTimeoutMs
        when (mode) {
            Mode.OneFingerPending -> if (quick) {
                if (secondTap) {
                    pendingTap = null
                    secondTap = false
                    out += TrackpadAction.Click(MouseButton.Left, 2)
                } else {
                    pendingTap = PendingTap(timeMs, finger.x, finger.y)
                }
            } else {
                // A long press is not a tap, but an earlier tap still counts.
                resolvePendingTap(out)
            }

            Mode.Moving -> flushMoves(timeMs, out)

            Mode.TwoFingerPending -> if (fingers.isEmpty() && quick) {
                out += TrackpadAction.Click(MouseButton.Right, 1)
            }

            Mode.Scrolling -> {
                flushScrolls(timeMs, out)
                // Lifting two fingers is never perfectly simultaneous; ignore the straggler so
                // the cursor does not jump.
                mode = Mode.Spent
            }

            Mode.Idle, Mode.Spent -> Unit
        }
        if (fingers.isEmpty()) mode = Mode.Idle
        return out
    }

    /** The system took the gesture away. Pending movement is delivered; no click is produced. */
    fun onCancel(timeMs: Long): List<TrackpadAction> {
        val out = ArrayList<TrackpadAction>(1)
        flushMoves(timeMs, out)
        flushScrolls(timeMs, out)
        resolvePendingTap(out)
        fingers.clear()
        mode = Mode.Idle
        return out
    }

    /** Releases whatever has become due by [timeMs]. See [nextDeadlineMs]. */
    fun onTick(timeMs: Long): List<TrackpadAction> {
        val out = ArrayList<TrackpadAction>(1)
        val tap = pendingTap
        if (tap != null) {
            val expired = if (secondTap) {
                // Second press is being held too long to be a tap.
                timeMs - gestureStartMs > config.tapTimeoutMs
            } else {
                fingers.isEmpty() && timeMs - tap.upMs > config.doubleTapWindowMs
            }
            if (expired) resolvePendingTap(out)
        }
        moves.poll(timeMs)?.let { out += TrackpadAction.Move(it.first, it.second) }
        scrolls.poll(timeMs)?.let { out += TrackpadAction.Scroll(it.first, it.second) }
        return out
    }

    /** When [onTick] next has something to release, or null if it has nothing to wait for. */
    fun nextDeadlineMs(): Long? {
        val tap = pendingTap
        val tapDeadline = when {
            tap == null -> null
            secondTap -> gestureStartMs + config.tapTimeoutMs + 1
            fingers.isEmpty() -> tap.upMs + config.doubleTapWindowMs + 1
            else -> null
        }
        return listOfNotNull(tapDeadline, moves.dueAtMs, scrolls.dueAtMs).minOrNull()
    }

    private fun resolvePendingTap(out: MutableList<TrackpadAction>) {
        if (pendingTap != null) {
            pendingTap = null
            out += TrackpadAction.Click(MouseButton.Left, 1)
        }
        secondTap = false
    }

    private fun flushMoves(timeMs: Long, out: MutableList<TrackpadAction>) {
        moves.flush(timeMs)?.let { out += TrackpadAction.Move(it.first, it.second) }
    }

    private fun flushScrolls(timeMs: Long, out: MutableList<TrackpadAction>) {
        scrolls.flush(timeMs)?.let { out += TrackpadAction.Scroll(it.first, it.second) }
    }

    private fun centroid(): Pair<Double, Double> {
        var sx = 0.0
        var sy = 0.0
        for (f in fingers.values) {
            sx += f.x
            sy += f.y
        }
        return sx / fingers.size to sy / fingers.size
    }

    private fun anchorCentroid() {
        val (cx, cy) = centroid()
        lastX = cx
        lastY = cy
    }
}
