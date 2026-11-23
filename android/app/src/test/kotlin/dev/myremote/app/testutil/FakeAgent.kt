package dev.myremote.app.testutil

import dev.myremote.app.core.discovery.Endpoint
import dev.myremote.app.core.net.Fingerprints
import dev.myremote.app.core.protocol.AgentInfo
import dev.myremote.app.core.protocol.ClientMessage
import dev.myremote.app.core.protocol.CloseCodes
import dev.myremote.app.core.protocol.ErrorCodes
import dev.myremote.app.core.protocol.FrontApp
import dev.myremote.app.core.protocol.PROTOCOL_VERSION
import dev.myremote.app.core.protocol.Profiles
import dev.myremote.app.core.protocol.ProtocolCodec
import dev.myremote.app.core.protocol.ProtocolException
import dev.myremote.app.core.protocol.RemoteState
import dev.myremote.app.core.protocol.ServerMessage
import java.io.Closeable
import java.util.concurrent.CopyOnWriteArrayList
import mockwebserver3.Dispatcher
import mockwebserver3.MockResponse
import mockwebserver3.MockWebServer
import mockwebserver3.RecordedRequest
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okhttp3.tls.HandshakeCertificates
import okhttp3.tls.HeldCertificate
import okio.ByteString

/**
 * A stand-in for the Mac agent, good enough to exercise the client: TLS with a self-signed
 * certificate, the `hello`/`welcome` handshake, `ack`s and `pong`s. Each behaviour can be switched
 * off or replaced so tests can make it misbehave.
 */
class FakeAgent(
    token: String = "q83vEjRWeJCrze8SNFZ4kKvN7xI0VniQq83vEjRWeJA",
    val agent: AgentInfo = AgentInfo("0123456789abcdef", "Fake Mac"),
) : Closeable {
    /** The token `hello` must carry. */
    @Volatile
    var token: String = token
        private set

    // The subject name deliberately matches nothing the client connects to: the pin must be enough.
    val certificate: HeldCertificate = HeldCertificate.Builder()
        .commonName("MyRemote fake agent")
        .addSubjectAlternativeName("agent.invalid")
        .build()
    val fingerprint: String = Fingerprints.of(certificate.certificate)

    val server = MockWebServer()
    val connections = CopyOnWriteArrayList<Connection>()

    @Volatile
    var state = RemoteState(FrontApp("com.google.Chrome", "Google Chrome"), Profiles.YOUTUBE, accessibility = true)

    /** When false, WebSocket upgrades are refused with HTTP 503. */
    @Volatile
    var acceptUpgrades = true

    /** When false, `hello` is received but never answered. */
    @Volatile
    var answerHello = true

    /** When false, `ping` is received but never answered. */
    @Volatile
    var answerPings = true

    /** Produces the ack for a message that carried an id; return null to stay silent. */
    @Volatile
    var ackFor: (message: ClientMessage, id: Long) -> ServerMessage.Ack? = { _, id -> ServerMessage.Ack(id, ok = true) }

    val endpoint: Endpoint get() = Endpoint("127.0.0.1", server.port)

    /** Number of HTTP requests that got as far as the application layer. */
    val requestCount: Int get() = server.requestCount

    val latest: Connection get() = connections.last()

    fun start(port: Int = 0): FakeAgent {
        val certificates = HandshakeCertificates.Builder().heldCertificate(certificate).build()
        server.useHttps(certificates.sslSocketFactory())
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                if (!acceptUpgrades || request.url.encodedPath != "/ws") {
                    return MockResponse.Builder().code(503).build()
                }
                val connection = Connection()
                connections += connection
                return MockResponse.Builder().webSocketUpgrade(connection).build()
            }
        }
        server.start(port)
        return this
    }

    fun pairingUri(host: String = "127.0.0.1"): String =
        "myremote://pair?v=1&host=$host&port=${server.port}&id=${agent.id}" +
            "&name=${agent.name.replace(" ", "%20")}&fp=$fingerprint&token=$token"

    /** Pushes a new state to every authenticated client, like the real agent does. */
    fun pushState(newState: RemoteState) {
        state = newState
        connections.filter { it.authenticated }.forEach { it.send(ServerMessage.State(newState)) }
    }

    /** What "Reset pairing" does on the real agent: new token, same certificate, everyone dropped. */
    fun resetPairing(newToken: String) {
        token = newToken
        connections.filter { it.closedCode == null }.forEach { it.close(1001, "pairing reset") }
    }

    override fun close() {
        server.close()
    }

    inner class Connection : WebSocketListener() {
        @Volatile
        var socket: WebSocket? = null
            private set

        @Volatile
        var authenticated = false
            private set

        @Volatile
        var closedCode: Int? = null
            private set

        /** Every text frame received, decoded. Frames that are not valid client messages are skipped. */
        val received = CopyOnWriteArrayList<ClientMessage>()

        inline fun <reified T : ClientMessage> receivedOf(): List<T> = received.filterIsInstance<T>()

        fun send(message: ServerMessage) {
            socket!!.send(ProtocolCodec.encode(message))
        }

        fun sendRaw(text: String) {
            socket!!.send(text)
        }

        fun sendBinary(bytes: ByteString) {
            socket!!.send(bytes)
        }

        fun close(code: Int, reason: String? = null) {
            socket!!.close(code, reason)
        }

        override fun onOpen(webSocket: WebSocket, response: Response) {
            socket = webSocket
        }

        override fun onMessage(webSocket: WebSocket, text: String) {
            val message = try {
                ProtocolCodec.decodeClient(text)
            } catch (_: ProtocolException) {
                send(ServerMessage.Error(ErrorCodes.BAD_REQUEST, "unknown message"))
                return
            }
            received += message
            if (!authenticated) {
                handshake(message)
                return
            }
            when (message) {
                is ClientMessage.Ping -> if (answerPings) send(ServerMessage.Pong(message.t))
                is ClientMessage.Cmd -> message.id?.let { id -> ackFor(message, id)?.let(::send) }
                is ClientMessage.Key -> message.id?.let { id -> ackFor(message, id)?.let(::send) }
                is ClientMessage.Text -> message.id?.let { id -> ackFor(message, id)?.let(::send) }
                else -> Unit
            }
        }

        private fun handshake(message: ClientMessage) {
            if (!answerHello) return
            when {
                message !is ClientMessage.Hello || message.token != token -> {
                    send(ServerMessage.Error(ErrorCodes.UNAUTHORIZED, "invalid token"))
                    close(CloseCodes.UNAUTHORIZED, "unauthorized")
                }

                message.v != PROTOCOL_VERSION -> {
                    send(ServerMessage.Error(ErrorCodes.UNSUPPORTED_VERSION, "unsupported version"))
                    close(CloseCodes.UNSUPPORTED_VERSION, "unsupported version")
                }

                else -> {
                    authenticated = true
                    send(ServerMessage.Welcome(PROTOCOL_VERSION, agent, state))
                }
            }
        }

        override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
            closedCode = code
            webSocket.close(1000, null)
        }

        override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
            closedCode = closedCode ?: -1
        }
    }
}
