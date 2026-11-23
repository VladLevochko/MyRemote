package dev.myremote.app.core.net

import dev.myremote.app.core.discovery.Endpoint
import dev.myremote.app.core.protocol.AgentInfo
import dev.myremote.app.core.protocol.RemoteState

sealed interface ConnectionState {
    /** Not trying to connect: before [RemoteClient.connect] or after [RemoteClient.disconnect]. */
    data object Disconnected : ConnectionState

    /**
     * Resolving the agent's address, opening the socket or waiting for `welcome`.
     *
     * @param attempt 1-based count of consecutive attempts since the last successful connection.
     * @param lastFailure why the previous attempt or session ended, or null for a fresh start.
     *   Lets the UI keep saying what is wrong while the next attempt is under way.
     */
    data class Connecting(val attempt: Int, val lastFailure: FailureReason? = null) : ConnectionState

    /** `welcome` received. [state] follows the agent's `state` pushes. */
    data class Connected(val agent: AgentInfo, val state: RemoteState, val endpoint: Endpoint) : ConnectionState

    /**
     * The last attempt or session ended with [reason].
     *
     * [retryInMs] is the backoff delay before the next automatic attempt, or null when the client
     * has stopped because retrying cannot help (see [FailureReason.terminal]).
     */
    data class Failed(val reason: FailureReason, val retryInMs: Long?) : ConnectionState
}

sealed interface FailureReason {
    /** True when the client stops instead of reconnecting. */
    val terminal: Boolean get() = false

    /**
     * The agent rejected the token. The pairing is no longer valid (for example after
     * "Reset pairing" on the Mac), so the user has to pair again. Never retried.
     */
    data object Unauthorized : FailureReason {
        override val terminal get() = true
    }

    /** The agent does not speak protocol v1. Never retried. */
    data object UnsupportedVersion : FailureReason {
        override val terminal get() = true
    }

    /**
     * The server's certificate is not the paired one. Nothing was sent to it. Retried, because the
     * next attempt may resolve to a different host (a stale last-known address can belong to
     * another machine), but if it persists the user has to pair again.
     */
    data class PinMismatch(val actualFingerprint: String) : FailureReason

    /** No `pong` within the contract's 10 s. */
    data object HeartbeatTimeout : FailureReason

    /** The socket opened but `welcome` did not arrive in time. */
    data object HandshakeTimeout : FailureReason

    /** The agent closed the WebSocket with [code]. */
    data class ClosedByServer(val code: Int) : FailureReason

    /** Could not connect, or the connection broke. */
    data class Network(val detail: String) : FailureReason
}

/** Outcome of a `cmd`, `key` or `text` sent with an `id`. */
sealed interface CommandResult {
    data object Ok : CommandResult

    /** `ack` with `ok=false`; [error] is one of [dev.myremote.app.core.protocol.AckErrors] or a newer value. */
    data class Rejected(val error: String) : CommandResult

    /** No `ack` within the timeout. */
    data object Timeout : CommandResult

    /** There is no live, welcomed connection, or it was lost before the `ack` arrived. */
    data object NotConnected : CommandResult
}

/** Reconnect delays from PROTOCOL.md section 4.5: 1 s, 2 s, 4 s ... capped at 15 s. */
class Backoff(private val initialMs: Long = 1_000, private val maxMs: Long = 15_000) {
    /** @param failures number of consecutive failures before this one, starting at 0. */
    fun delayMs(failures: Int): Long {
        require(failures >= 0)
        if (failures >= 30) return maxMs
        return minOf(initialMs shl failures, maxMs)
    }
}

/** Protocol timings. Defaults are the contract's; tests may shorten the ones the contract leaves open. */
data class RemoteTimings(
    /** Contract: the client pings every 5 s. */
    val pingIntervalMs: Long = 5_000,
    /** Contract: no `pong` within 10 s of a `ping` means the connection is dead. */
    val pongTimeoutMs: Long = 10_000,
    /** Not in the contract: how long to wait for `welcome` after starting an attempt. */
    val handshakeTimeoutMs: Long = 10_000,
    /** Not in the contract: how long to wait for an `ack`. */
    val ackTimeoutMs: Long = 3_000,
    val backoff: Backoff = Backoff(),
)
