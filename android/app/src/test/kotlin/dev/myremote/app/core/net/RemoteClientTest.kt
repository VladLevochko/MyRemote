package dev.myremote.app.core.net

import dev.myremote.app.core.discovery.Endpoint
import dev.myremote.app.core.protocol.AckErrors
import dev.myremote.app.core.protocol.ClientMessage
import dev.myremote.app.core.protocol.CloseCodes
import dev.myremote.app.core.protocol.CmdAction
import dev.myremote.app.core.protocol.ErrorCodes
import dev.myremote.app.core.protocol.KeyName
import dev.myremote.app.core.protocol.MouseButton
import dev.myremote.app.core.protocol.Profiles
import dev.myremote.app.core.protocol.RemoteState
import dev.myremote.app.core.protocol.ServerMessage
import dev.myremote.app.testutil.ClientHarness
import dev.myremote.app.testutil.FakeAgent
import java.net.ServerSocket
import java.util.concurrent.atomic.AtomicLong
import okio.ByteString.Companion.encodeUtf8
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * [RemoteClient] against a TLS WebSocket server with a generated self-signed certificate.
 * Protocol timers run on virtual time (see [ClientHarness]); only socket I/O is real.
 */
class RemoteClientTest {
    private lateinit var agent: FakeAgent
    private val harnesses = ArrayList<ClientHarness>()

    @Before
    fun setUp() {
        agent = FakeAgent().start()
    }

    @After
    fun tearDown() {
        harnesses.forEach { it.close() }
        agent.close()
    }

    private fun harness(
        fingerprint: String = agent.fingerprint,
        token: String = agent.token,
        target: () -> Endpoint = { agent.endpoint },
    ) = ClientHarness(fingerprint, token, target).also { harnesses += it }

    /** Heartbeat pings only: in these tests they are the ones stamped with a multiple of 5 s. */
    private fun heartbeatPings(connection: FakeAgent.Connection = agent.latest): List<Long> =
        connection.receivedOf<ClientMessage.Ping>().map { it.t }.filter { it % 5_000 == 0L }

    // --- TLS pinning and handshake ---

    @Test
    fun correctPinConnectsAndCompletesHelloWelcome() {
        val h = harness()
        assertEquals(ConnectionState.Disconnected, h.state)

        h.client.connect()
        h.scheduler.runCurrent()
        assertEquals(ConnectionState.Connecting(attempt = 1), h.state)

        val connected = h.awaitState<ConnectionState.Connected>()
        assertEquals(agent.agent, connected.agent)
        assertEquals(agent.state, connected.state)
        assertEquals(agent.endpoint, connected.endpoint)

        // hello is the first and only thing sent, with the token, version and device name.
        assertEquals(
            listOf<ClientMessage>(ClientMessage.Hello(v = 1, token = agent.token, device = "Test Phone")),
            agent.latest.received.toList(),
        )
        assertEquals(1, agent.requestCount)
    }

    @Test
    fun wrongPinFailsBeforeAnyApplicationDataIsSent() {
        val wrongPin = "3b7f0c1d9a2e4f5061728394a5b6c7d8e9f00112233445566778899aabbccdde"
        val h = harness(fingerprint = wrongPin)

        h.client.connect()
        val failed = h.awaitState<ConnectionState.Failed>()

        assertEquals(FailureReason.PinMismatch(actualFingerprint = agent.fingerprint), failed.reason)
        // The TLS handshake was aborted by the client, so not even the HTTP upgrade request went out.
        assertEquals(0, agent.requestCount)
        assertTrue(agent.connections.isEmpty())
        assertEquals(CommandResult.NotConnected, h.awaitResult(h.start { command(CmdAction.PlayPause) }))
        assertFalse(h.client.pointer(1.0, 1.0))
    }

    @Test
    fun pinIsTheOnlyAuthoritySoHostnameAndSelfSignatureDoNotMatter() {
        // The fake agent's certificate is self-signed for "agent.invalid" while the client dials
        // 127.0.0.1: only the fingerprint makes this connection acceptable.
        assertEquals(listOf("agent.invalid"), agent.certificate.certificate.subjectAlternativeNames.map { it[1] })
        val h = harness()
        h.connectAndAwait()
    }

    @Test
    fun unauthorizedSurfacesAsRepairStateAndIsNeverRetried() {
        val h = harness(token = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA")

        h.client.connect()
        val failed = h.awaitState<ConnectionState.Failed>()

        assertEquals(FailureReason.Unauthorized, failed.reason)
        assertTrue(failed.reason.terminal)
        assertNull("no retry may be scheduled", failed.retryInMs)

        h.advance(120_000)
        Thread.sleep(50)
        h.advance(120_000)
        assertEquals(ConnectionState.Failed(FailureReason.Unauthorized, null), h.state)
        assertEquals("exactly one connection attempt", listOf(0L), h.attemptTimes)
        assertEquals(1, agent.requestCount)
    }

    @Test
    fun closeCode4401AloneAlsoMeansUnauthorized() {
        agent.answerHello = false
        val h = harness()
        h.client.connect()
        h.await("hello") { agent.connections.isNotEmpty() && agent.latest.received.isNotEmpty() }

        agent.latest.close(CloseCodes.UNAUTHORIZED, "unauthorized")

        assertEquals(ConnectionState.Failed(FailureReason.Unauthorized, null), h.awaitState<ConnectionState.Failed>())
    }

    @Test
    fun unsupportedVersionStopsWithoutRetry() {
        agent.answerHello = false
        val h = harness()
        h.client.connect()
        h.await("hello") { agent.connections.isNotEmpty() && agent.latest.received.isNotEmpty() }

        agent.latest.send(ServerMessage.Error(ErrorCodes.UNSUPPORTED_VERSION, "v1 is too old"))
        agent.latest.close(CloseCodes.UNSUPPORTED_VERSION)

        assertEquals(ConnectionState.Failed(FailureReason.UnsupportedVersion, null), h.awaitState<ConnectionState.Failed>())
        h.advance(60_000)
        assertEquals(1, h.attemptTimes.size)
    }

    @Test
    fun missingWelcomeTimesOutAndRetries() {
        agent.answerHello = false
        val h = harness()
        h.client.connect()
        h.await("hello") { agent.connections.isNotEmpty() && agent.latest.received.isNotEmpty() }

        h.advance(9_999)
        assertEquals(ConnectionState.Connecting(1), h.state)
        h.advance(1)
        assertEquals(ConnectionState.Failed(FailureReason.HandshakeTimeout, retryInMs = 1_000), h.state)
    }

    // --- Commands and acks ---

    @Test
    fun acksAreCorrelatedByIdEvenWhenTheyArriveOutOfOrder() {
        val held = ArrayList<Pair<ClientMessage, Long>>()
        agent.ackFor = { message, id ->
            synchronized(held) { held += message to id }
            null
        }
        val h = harness()
        h.connectAndAwait()

        val play = h.start { command(CmdAction.PlayPause) }
        val enter = h.start { key(KeyName.Enter) }
        val text = h.start { text("Привіт") }
        h.await("three requests") { synchronized(held) { held.size } == 3 }

        val ids = synchronized(held) { held.associate { it.first to it.second } }
        val playId = ids.entries.single { it.key is ClientMessage.Cmd }.value
        val enterId = ids.entries.single { it.key is ClientMessage.Key }.value
        val textId = ids.entries.single { it.key is ClientMessage.Text }.value
        assertEquals("ids must be distinct", 3, setOf(playId, enterId, textId).size)
        assertEquals(ClientMessage.Cmd(CmdAction.PlayPause, playId), ids.keys.single { it is ClientMessage.Cmd })
        assertEquals(ClientMessage.Key(KeyName.Enter, enterId), ids.keys.single { it is ClientMessage.Key })
        assertEquals(ClientMessage.Text("Привіт", textId), ids.keys.single { it is ClientMessage.Text })

        // Answer in reverse order, each with a different outcome, plus an ack nobody asked for.
        agent.latest.send(ServerMessage.Ack(987_654, ok = true))
        agent.latest.send(ServerMessage.Ack(textId, ok = false, error = AckErrors.ACCESSIBILITY_DENIED))
        assertEquals(CommandResult.Rejected(AckErrors.ACCESSIBILITY_DENIED), h.awaitResult(text))
        assertFalse(enter.isCompleted)
        assertFalse(play.isCompleted)

        agent.latest.send(ServerMessage.Ack(enterId, ok = false, error = AckErrors.UNSUPPORTED))
        assertEquals(CommandResult.Rejected(AckErrors.UNSUPPORTED), h.awaitResult(enter))
        assertFalse(play.isCompleted)

        agent.latest.send(ServerMessage.Ack(playId, ok = true))
        assertEquals(CommandResult.Ok, h.awaitResult(play))
    }

    @Test
    fun ackTimeoutIsReportedAndALateAckIsHarmless() {
        val sentId = AtomicLong(-1)
        agent.ackFor = { _, id ->
            sentId.set(id)
            null
        }
        val h = harness()
        h.connectAndAwait()

        val result = h.start { command(CmdAction.ToggleMute) }
        h.await("request") { sentId.get() > 0 }
        h.advance(2_999)
        assertFalse("must wait the full ack timeout", result.isCompleted)
        h.advance(1)
        assertEquals(CommandResult.Timeout, h.awaitResult(result))

        // The connection is still usable, and the stale ack does not confuse the next command.
        agent.latest.send(ServerMessage.Ack(sentId.get(), ok = true))
        agent.ackFor = { _, id -> ServerMessage.Ack(id, ok = false, error = AckErrors.BAD_REQUEST) }
        assertEquals(CommandResult.Rejected(AckErrors.BAD_REQUEST), h.awaitResult(h.start { command(CmdAction.Skip) }))
        assertTrue(h.state is ConnectionState.Connected)
    }

    @Test
    fun pointerClickAndScrollAreFireAndForgetWithoutIds() {
        val h = harness()
        h.connectAndAwait()

        assertTrue(h.client.pointer(12.5, -3.25))
        assertTrue(h.client.click(MouseButton.Right, 2))
        assertTrue(h.client.scroll(0.0, -40.5))

        h.await("three messages") { agent.latest.received.size == 4 }
        assertEquals(
            listOf(
                ClientMessage.Pointer(12.5, -3.25),
                ClientMessage.Click(MouseButton.Right, 2),
                ClientMessage.Scroll(0.0, -40.5),
            ),
            agent.latest.received.drop(1),
        )
    }

    @Test
    fun commandsReportNotConnectedWhenThereIsNoSession() {
        val h = harness()
        assertEquals(CommandResult.NotConnected, h.awaitResult(h.start { command(CmdAction.PlayPause) }))
        assertEquals(CommandResult.NotConnected, h.awaitResult(h.start { key(KeyName.Up) }))
        assertEquals(CommandResult.NotConnected, h.awaitResult(h.start { text("x") }))
        assertFalse(h.client.pointer(1.0, 0.0))
        assertFalse(h.client.click(MouseButton.Left))
        assertFalse(h.client.scroll(0.0, 1.0))
        assertNull(h.awaitResult(h.start { ping() }))
    }

    @Test
    fun aCommandWaitingForItsAckEndsWhenTheConnectionDrops() {
        agent.ackFor = { _, _ -> null }
        val h = harness()
        h.connectAndAwait()
        val pending = h.start { command(CmdAction.NextItem) }
        h.await("request") { agent.latest.receivedOf<ClientMessage.Cmd>().isNotEmpty() }

        agent.latest.close(1001, "going away")

        assertEquals(CommandResult.NotConnected, h.awaitResult(pending))
        assertEquals(ConnectionState.Failed(FailureReason.ClosedByServer(1001), retryInMs = 1_000), h.awaitState<ConnectionState.Failed>())
    }

    // --- Server pushes ---

    @Test
    fun serverStatePushUpdatesTheExposedState() {
        val h = harness()
        val connected = h.connectAndAwait()
        assertEquals(Profiles.YOUTUBE, connected.state.profile)

        val pushed = RemoteState(frontApp = null, profile = Profiles.GENERIC, accessibility = false)
        agent.pushState(pushed)

        h.await("state push") { (h.state as? ConnectionState.Connected)?.state == pushed }
        assertEquals(connected.copy(state = pushed), h.state)
    }

    @Test
    fun unknownServerMessageTypesAndJunkFramesAreIgnored() {
        val h = harness()
        h.connectAndAwait()

        agent.latest.sendRaw("""{"type":"telemetry","cpu":0.93}""")
        agent.latest.sendRaw("this is not json")
        agent.latest.sendRaw("""{"type":"ack"}""")
        agent.latest.sendRaw("""{"type":"error","code":"bad_request","message":"non-fatal"}""")
        agent.latest.sendBinary("binary".encodeUtf8())
        val after = RemoteState(null, Profiles.NETFLIX, accessibility = true)
        agent.pushState(after)

        // The state push sent after the junk is processed, on the same connection.
        h.await("state after junk") { (h.state as? ConnectionState.Connected)?.state == after }
        assertEquals(1, agent.connections.size)
        assertEquals(CommandResult.Ok, h.awaitResult(h.start { command(CmdAction.PlayPause) }))
    }

    // --- Heartbeat and reconnect ---

    @Test
    fun pingsEveryFiveSecondsAndStaysConnectedWhilePongsArrive() {
        val h = harness()
        h.connectAndAwait()

        for (round in 1..12) {
            h.advance(4_999)
            assertEquals("no ping before the 5 s mark", round - 1, heartbeatPings().size)
            h.advance(1)
            h.await("ping $round") { heartbeatPings().size == round }
            // An explicit ping is answered after the heartbeat's, so once it returns the heartbeat
            // pong has been processed too.
            assertEquals(0L, h.awaitResult(h.start { ping() }))
        }

        assertTrue(h.state is ConnectionState.Connected)
        assertEquals("ping carries the client clock in ms", (1..12).map { it * 5_000L }, heartbeatPings())
        assertEquals(listOf(0L), h.attemptTimes)
    }

    @Test
    fun heartbeatTimeoutReconnectsWithTheContractBackoffSequence() {
        val h = harness()
        h.connectAndAwait()
        agent.answerPings = false
        agent.acceptUpgrades = false

        // First unanswered ping goes out at 5 s; the connection is declared dead 10 s later.
        h.advance(5_000)
        h.await("first ping") { heartbeatPings().size == 1 }
        h.advance(9_999)
        assertTrue("still connected 1 ms before the pong deadline", h.state is ConnectionState.Connected)
        h.advance(1)
        assertEquals(ConnectionState.Failed(FailureReason.HeartbeatTimeout, retryInMs = 1_000), h.state)
        assertEquals(15_000, h.now)
        h.await("old socket closed") { agent.connections.first().closedCode != null }

        // Every further attempt is refused, so the delays grow: 1 s, 2 s, 4 s, 8 s, then capped at 15 s.
        val expectedDelays = listOf(1_000L, 2_000L, 4_000L, 8_000L, 15_000L, 15_000L, 15_000L)
        for ((index, delay) in expectedDelays.withIndex()) {
            val failed = h.awaitState<ConnectionState.Failed>("failure ${index + 1}")
            assertEquals("delay after failure ${index + 1}", delay, failed.retryInMs)
            if (index == 0) {
                assertEquals(FailureReason.HeartbeatTimeout, failed.reason)
            } else {
                assertTrue("refused upgrade should be a network failure: ${failed.reason}", failed.reason is FailureReason.Network)
            }
            val attemptsSoFar = h.attemptTimes.size
            h.advance(delay - 1)
            assertEquals("no attempt before the backoff has elapsed", attemptsSoFar, h.attemptTimes.size)
            assertEquals(failed, h.state)
            h.advance(1)
            assertEquals(attemptsSoFar + 1, h.attemptTimes.size)
            // While the next attempt runs, the state still says why the previous one ended.
            assertEquals(ConnectionState.Connecting(attempt = index + 2, lastFailure = failed.reason), h.state)
            if (index < expectedDelays.lastIndex) {
                h.await("attempt ${index + 2} to fail") { h.state is ConnectionState.Failed }
            }
        }
        assertEquals(
            "virtual times of all connection attempts",
            listOf(0L, 16_000L, 18_000L, 22_000L, 30_000L, 45_000L, 60_000L, 75_000L),
            h.attemptTimes,
        )

        // Once the agent is back the client connects, and the backoff starts over at 1 s.
        h.await("attempt 8 to fail") { h.state is ConnectionState.Failed }
        agent.acceptUpgrades = true
        agent.answerPings = true
        h.advance(15_000)
        h.awaitState<ConnectionState.Connected>()
        assertEquals(2, agent.connections.size)

        agent.latest.close(1012, "restarting")
        assertEquals(
            ConnectionState.Failed(FailureReason.ClosedByServer(1012), retryInMs = 1_000),
            h.awaitState<ConnectionState.Failed>(),
        )
    }

    @Test
    fun aPongForALaterPingAlsoSettlesEarlierOnesAndEachPingHasItsOwnDeadline() {
        val h = harness()
        h.connectAndAwait()
        agent.answerPings = false

        h.advance(5_000)
        h.await("first ping") { heartbeatPings().size == 1 }
        h.advance(5_000)
        h.await("second ping") { heartbeatPings().size == 2 }
        h.advance(4_000)

        // 9 s after the first ping the agent answers only the second one. A state push sent right
        // behind it tells the test when the client has processed the pong.
        agent.latest.send(ServerMessage.Pong(10_000))
        val marker = RemoteState(null, Profiles.APPLE_TV, accessibility = true)
        agent.pushState(marker)
        h.await("pong processed") { (h.state as? ConnectionState.Connected)?.state == marker }

        h.advance(1_000)
        assertTrue("the first ping's deadline passed harmlessly", h.state is ConnectionState.Connected)
        h.await("third ping") { heartbeatPings().size == 3 }

        // The third ping (sent at 15 s) is never answered: dead exactly 10 s after it, not sooner.
        h.advance(9_999)
        assertTrue(h.state is ConnectionState.Connected)
        h.advance(1)
        assertEquals(ConnectionState.Failed(FailureReason.HeartbeatTimeout, retryInMs = 1_000), h.state)
        assertEquals(25_000, h.now)
    }

    @Test
    fun refusedConnectionIsANetworkFailureThatRetries() {
        val deadPort = ServerSocket(0).use { it.localPort }
        val h = harness(target = { Endpoint("127.0.0.1", deadPort) })

        h.client.connect()
        val failed = h.awaitState<ConnectionState.Failed>()

        assertTrue("was ${failed.reason}", failed.reason is FailureReason.Network)
        assertEquals(1_000L, failed.retryInMs)
        h.advance(1_000)
        assertEquals(2, h.attemptTimes.size)
    }

    @Test
    fun disconnectStopsReconnectingAndConnectStartsAgain() {
        val h = harness()
        h.connectAndAwait()

        h.client.disconnect()
        assertEquals(ConnectionState.Disconnected, h.state)
        h.await("server sees the close") { agent.latest.closedCode != null }
        assertEquals("a deliberate disconnect closes cleanly", 1000, agent.latest.closedCode)
        h.advance(120_000)
        assertEquals(ConnectionState.Disconnected, h.state)
        assertEquals(1, h.attemptTimes.size)
        assertEquals(CommandResult.NotConnected, h.awaitResult(h.start { command(CmdAction.PlayPause) }))

        h.connectAndAwait()
        assertEquals(2, agent.connections.size)
        // Calling connect while already connected does nothing.
        h.client.connect()
        h.advance(1_000)
        assertEquals(2, h.attemptTimes.size)
    }
}
