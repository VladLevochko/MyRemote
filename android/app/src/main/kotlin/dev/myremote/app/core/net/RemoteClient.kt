package dev.myremote.app.core.net

import dev.myremote.app.core.discovery.Endpoint
import dev.myremote.app.core.discovery.TargetResolver
import dev.myremote.app.core.protocol.ClientMessage
import dev.myremote.app.core.protocol.CloseCodes
import dev.myremote.app.core.protocol.CmdAction
import dev.myremote.app.core.protocol.ErrorCodes
import dev.myremote.app.core.protocol.KeyName
import dev.myremote.app.core.protocol.MouseButton
import dev.myremote.app.core.protocol.ProtocolCodec
import dev.myremote.app.core.protocol.ProtocolException
import dev.myremote.app.core.protocol.ServerMessage
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ConcurrentSkipListSet
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicLong
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.cancelChildren
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.channels.SendChannel
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull
import okhttp3.HttpUrl
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener

/** What the client needs from a stored pairing in order to authenticate both ways. */
data class ClientIdentity(
    /** Pinned SHA-256 fingerprint of the agent's certificate, 64 lowercase hex characters. */
    val fingerprint: String,
    /** Shared secret sent in `hello`. */
    val token: String,
    /** Human-readable name of this phone, sent in `hello`. */
    val deviceName: String,
)

/**
 * The protocol client: one WebSocket to the paired agent, kept alive and re-established
 * according to PROTOCOL.md.
 *
 * All timers run as coroutine delays in [scope], so a test dispatcher controls them, and [clock]
 * supplies the millisecond timestamps put into `ping`. Socket I/O happens on OkHttp's threads and
 * is funnelled into a single coroutine per connection, so connection state is only ever touched
 * from [scope].
 */
class RemoteClient(
    private val identity: ClientIdentity,
    private val resolver: TargetResolver,
    private val scope: CoroutineScope,
    private val clock: () -> Long = System::currentTimeMillis,
    private val timings: RemoteTimings = RemoteTimings(),
    private val httpClient: OkHttpClient = defaultHttpClient(),
) {
    private val _state = MutableStateFlow<ConnectionState>(ConnectionState.Disconnected)
    val state: StateFlow<ConnectionState> = _state.asStateFlow()

    private val lock = Any()
    private var loop: Job? = null
    private var generation = 0
    private val nextId = AtomicLong(0)

    /** The session that has completed `hello`/`welcome`, if any. */
    @Volatile
    private var live: Session? = null

    /** Starts connecting and keeps the connection up until [disconnect]. No-op if already running. */
    fun connect() {
        synchronized(lock) {
            if (loop?.isActive == true) return
            val gen = ++generation
            loop = scope.launch { runLoop(gen) }
        }
    }

    /** Closes the connection and stops reconnecting. */
    fun disconnect() {
        synchronized(lock) {
            generation++
            loop?.cancel()
            loop = null
            _state.value = ConnectionState.Disconnected
        }
    }

    /** Sends a `cmd` with an `id` and waits for its `ack`. */
    suspend fun command(action: CmdAction): CommandResult = request { id -> ClientMessage.Cmd(action, id) }

    /** Sends a `key` with an `id` and waits for its `ack`. */
    suspend fun key(key: KeyName): CommandResult = request { id -> ClientMessage.Key(key, id) }

    /** Sends a `text` with an `id` and waits for its `ack`. */
    suspend fun text(text: String): CommandResult = request { id -> ClientMessage.Text(text, id) }

    /** Fire-and-forget relative pointer movement. @return false if there is no live connection. */
    fun pointer(dx: Double, dy: Double): Boolean = sendNow(ClientMessage.Pointer(dx, dy))

    /** Fire-and-forget click at the current cursor position. */
    fun click(button: MouseButton, count: Int = 1): Boolean = sendNow(ClientMessage.Click(button, count))

    /** Fire-and-forget scroll. Positive [dy] scrolls like turning a mouse wheel down. */
    fun scroll(dx: Double, dy: Double): Boolean = sendNow(ClientMessage.Scroll(dx, dy))

    /**
     * Sends one extra `ping` and waits for the matching `pong`.
     *
     * @return the round trip in milliseconds of [clock], or null on timeout or without a connection.
     */
    suspend fun ping(timeoutMs: Long = timings.pongTimeoutMs): Long? {
        val session = live ?: return null
        val sentAt = clock()
        val t = session.nextPingT(sentAt)
        val waiter = CompletableDeferred<Boolean>()
        session.pingWaiters[t] = waiter
        try {
            if (session.closed || !session.send(ClientMessage.Ping(t))) return null
            val answered = withTimeoutOrNull(timeoutMs) { waiter.await() } ?: false
            return if (answered) clock() - sentAt else null
        } finally {
            session.pingWaiters.remove(t)
        }
    }

    private fun sendNow(message: ClientMessage): Boolean = live?.send(message) ?: false

    private suspend fun request(build: (id: Long) -> ClientMessage): CommandResult {
        val session = live ?: return CommandResult.NotConnected
        val id = nextId.incrementAndGet()
        val pending = CompletableDeferred<ServerMessage.Ack?>()
        session.pendingAcks[id] = pending
        try {
            if (session.closed || !session.send(build(id))) return CommandResult.NotConnected
            // The timeout runs on the caller's dispatcher, so it is virtual under a test dispatcher.
            val ack = withTimeoutOrNull(timings.ackTimeoutMs) { AckWait(pending.await()) }
                ?: return CommandResult.Timeout
            return when {
                ack.ack == null -> CommandResult.NotConnected
                ack.ack.ok -> CommandResult.Ok
                else -> CommandResult.Rejected(ack.ack.error ?: "")
            }
        } finally {
            session.pendingAcks.remove(id)
        }
    }

    /** Wrapper so a null ack ("connection lost") is distinguishable from withTimeoutOrNull's null. */
    private class AckWait(val ack: ServerMessage.Ack?)

    private fun publish(gen: Int, value: ConnectionState) {
        synchronized(lock) {
            if (gen == generation) _state.value = value
        }
    }

    private suspend fun runLoop(gen: Int) {
        var failures = 0
        var lastFailure: FailureReason? = null
        while (true) {
            publish(gen, ConnectionState.Connecting(attempt = failures + 1, lastFailure = lastFailure))
            val endpoint = resolver.resolve()
            val end = runSession(gen, endpoint)
            lastFailure = end.reason
            if (end.welcomed) failures = 0
            if (end.reason.terminal) {
                publish(gen, ConnectionState.Failed(end.reason, retryInMs = null))
                return
            }
            val delayMs = timings.backoff.delayMs(failures)
            failures++
            publish(gen, ConnectionState.Failed(end.reason, retryInMs = delayMs))
            delay(delayMs)
        }
    }

    private class SessionEnd(val reason: FailureReason, val welcomed: Boolean)

    private sealed interface Event {
        data object Open : Event

        data class Text(val text: String) : Event

        data class Closed(val code: Int) : Event

        data class Failure(val error: Throwable) : Event

        data object HandshakeTimeout : Event

        data object HeartbeatTimeout : Event
    }

    /** Runs one connection from socket open to its end and reports why it ended. */
    private suspend fun runSession(gen: Int, endpoint: Endpoint): SessionEnd = coroutineScope {
        val events = Channel<Event>(Channel.UNLIMITED)
        val trust = PinnedTrustManager(identity.fingerprint)
        val socket = try {
            val url = HttpUrl.Builder()
                .scheme("https") // OkHttp's spelling of wss
                .host(endpoint.host)
                .port(endpoint.port)
                .addPathSegment("ws")
                .build()
            httpClient.newBuilder()
                .sslSocketFactory(trust.newSslContext().socketFactory, trust)
                // The pinned fingerprint identifies the server; its certificate carries no usable name.
                .hostnameVerifier { _, _ -> true }
                .build()
                .newWebSocket(Request.Builder().url(url).build(), Listener(events))
        } catch (e: IllegalArgumentException) {
            return@coroutineScope SessionEnd(FailureReason.Network("invalid address ${endpoint.host}:${endpoint.port}"), false)
        }
        val session = Session(socket)
        var welcomed = false
        var end: SessionEnd? = null
        try {
            val handshakeTimer = launch {
                delay(timings.handshakeTimeoutMs)
                events.send(Event.HandshakeTimeout)
            }
            for (event in events) {
                val reason: FailureReason? = when (event) {
                    Event.Open -> {
                        // Contract: hello must be the first message, within 5 s of the socket opening.
                        session.send(ClientMessage.Hello(token = identity.token, device = identity.deviceName))
                        null
                    }

                    is Event.Text -> when (val message = decodeOrNull(event.text)) {
                        is ServerMessage.Welcome -> {
                            if (!welcomed) {
                                welcomed = true
                                handshakeTimer.cancel()
                                live = session
                                publish(gen, ConnectionState.Connected(message.agent, message.state, endpoint))
                                launch { heartbeat(session, events) }
                            }
                            null
                        }

                        is ServerMessage.State -> {
                            if (welcomed) {
                                (_state.value as? ConnectionState.Connected)?.let {
                                    publish(gen, it.copy(state = message.state))
                                }
                            }
                            null
                        }

                        is ServerMessage.Ack -> {
                            session.pendingAcks.remove(message.id)?.complete(message)
                            null
                        }

                        is ServerMessage.Pong -> {
                            session.onPong(message.t)
                            null
                        }

                        is ServerMessage.Error -> when (message.code) {
                            ErrorCodes.UNAUTHORIZED -> FailureReason.Unauthorized
                            ErrorCodes.UNSUPPORTED_VERSION -> FailureReason.UnsupportedVersion
                            // bad_request and anything newer: the agent keeps the connection open.
                            else -> null
                        }

                        // Unknown type or undecodable frame: ignored, as the contract requires.
                        is ServerMessage.Unknown, null -> null
                    }

                    is Event.Closed -> when (event.code) {
                        CloseCodes.UNAUTHORIZED -> FailureReason.Unauthorized
                        CloseCodes.UNSUPPORTED_VERSION -> FailureReason.UnsupportedVersion
                        else -> FailureReason.ClosedByServer(event.code)
                    }

                    is Event.Failure -> trust.rejectedFingerprint?.let { FailureReason.PinMismatch(it) }
                        ?: FailureReason.Network(event.error.message ?: event.error.javaClass.simpleName)

                    Event.HandshakeTimeout -> FailureReason.HandshakeTimeout
                    Event.HeartbeatTimeout -> FailureReason.HeartbeatTimeout
                }
                if (reason != null) {
                    end = SessionEnd(reason, welcomed)
                    break
                }
            }
            end ?: error("event channel closed unexpectedly")
        } finally {
            if (live === session) live = null
            session.close()
            val finished = end
            if (finished == null || finished.reason.terminal) {
                // Either the app is disconnecting on purpose (this coroutine was cancelled) or the
                // agent refused us and is closing: finish the WebSocket close handshake politely.
                socket.close(NORMAL_CLOSURE, null)
            } else {
                // The connection is broken or unresponsive: drop it without waiting.
                socket.cancel()
            }
            coroutineContext.cancelChildren()
        }
    }

    private suspend fun heartbeat(session: Session, events: SendChannel<Event>) = coroutineScope {
        while (true) {
            delay(timings.pingIntervalMs)
            val t = session.nextPingT(clock())
            session.unansweredPings.add(t)
            session.send(ClientMessage.Ping(t))
            launch {
                delay(timings.pongTimeoutMs)
                if (t in session.unansweredPings) events.send(Event.HeartbeatTimeout)
            }
        }
    }

    private fun decodeOrNull(text: String): ServerMessage? = try {
        ProtocolCodec.decodeServer(text)
    } catch (_: ProtocolException) {
        null
    }

    private class Session(private val socket: WebSocket) {
        val pendingAcks = ConcurrentHashMap<Long, CompletableDeferred<ServerMessage.Ack?>>()
        val pingWaiters = ConcurrentHashMap<Long, CompletableDeferred<Boolean>>()
        val unansweredPings = ConcurrentSkipListSet<Long>()

        @Volatile
        var closed = false
            private set

        private var lastPingT = Long.MIN_VALUE

        fun send(message: ClientMessage): Boolean = !closed && socket.send(ProtocolCodec.encode(message))

        /** Ping timestamps double as correlation keys, so they are kept strictly increasing. */
        @Synchronized
        fun nextPingT(now: Long): Long {
            lastPingT = maxOf(now, lastPingT + 1)
            return lastPingT
        }

        fun onPong(t: Long) {
            // A pong proves the connection was alive when ping t was handled, which also covers
            // every earlier ping.
            unansweredPings.headSet(t, true).clear()
            pingWaiters.remove(t)?.complete(true)
        }

        fun close() {
            closed = true
            pendingAcks.values.forEach { it.complete(null) }
            pingWaiters.values.forEach { it.complete(false) }
        }
    }

    private class Listener(private val events: SendChannel<Event>) : WebSocketListener() {
        override fun onOpen(webSocket: WebSocket, response: Response) {
            events.trySend(Event.Open)
        }

        override fun onMessage(webSocket: WebSocket, text: String) {
            events.trySend(Event.Text(text))
        }

        override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
            // Always answer with 1000: echoing is not allowed for codes such as 1005.
            webSocket.close(NORMAL_CLOSURE, null)
            events.trySend(Event.Closed(code))
        }

        override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
            events.trySend(Event.Closed(code))
        }

        override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
            events.trySend(Event.Failure(t))
        }
    }

    companion object {
        private const val NORMAL_CLOSURE = 1000

        fun defaultHttpClient(): OkHttpClient = OkHttpClient.Builder()
            .connectTimeout(5, TimeUnit.SECONDS)
            // Liveness is the protocol's own ping/pong, not WebSocket ping frames.
            .pingInterval(0, TimeUnit.MILLISECONDS)
            .build()
    }
}
