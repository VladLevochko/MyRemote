package dev.myremote.app.core.net

import dev.myremote.app.core.discovery.Endpoint
import dev.myremote.app.core.pairing.PairingInfo
import dev.myremote.app.core.pairing.PairingResult
import dev.myremote.app.core.pairing.PairingUriParser
import dev.myremote.app.core.protocol.CmdAction
import dev.myremote.app.core.protocol.KeyName
import dev.myremote.app.core.protocol.MouseButton
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeoutOrNull
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.Test

/**
 * End-to-end test of the real [RemoteClient] against a live Mac agent.
 *
 * Skipped unless the environment variable `MYREMOTE_E2E_URI` holds the agent's pairing URI
 * (the `PAIRING ...` line the agent prints, see PROTOCOL.md section 6). Run it with the agent in
 * `--dry-run` mode unless you want the keystrokes to really happen:
 *
 *     MYREMOTE_E2E_URI='myremote://pair?...' ./gradlew testDebugUnitTest --tests '*LiveAgentE2ETest'
 *
 * Uses real time and connects straight to the URI's host and port (no mDNS on the JVM).
 */
class LiveAgentE2ETest {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private lateinit var pairing: PairingInfo

    @Before
    fun readPairingUri() {
        val uri = System.getenv(ENV)?.trim().orEmpty()
        assumeTrue("$ENV is not set; skipping the live agent test", uri.isNotEmpty())
        pairing = when (val parsed = PairingUriParser.parse(uri)) {
            is PairingResult.Success -> parsed.info
            is PairingResult.Failure -> throw AssertionError("$ENV is not a valid pairing URI: ${parsed.error}")
        }
    }

    @After
    fun tearDown() {
        scope.cancel()
    }

    private fun client(token: String) = RemoteClient(
        identity = ClientIdentity(pairing.fp, token, deviceName = "LiveAgentE2ETest"),
        resolver = { Endpoint(pairing.host, pairing.port) },
        scope = scope,
    )

    private suspend fun RemoteClient.awaitOutcome(): ConnectionState =
        withTimeoutOrNull(CONNECT_TIMEOUT_MS) {
            state.first { it is ConnectionState.Connected || it is ConnectionState.Failed }
        } ?: fail("no welcome and no failure within $CONNECT_TIMEOUT_MS ms; state=${state.value}").let { state.value }

    private fun assertAcked(what: String, result: CommandResult) {
        // Any ack proves the round trip. `ok=false` (for example `unsupported` in the current
        // profile) is still an ack; a timeout or a lost connection is not.
        assertTrue(
            "$what: expected an ack but got $result",
            result is CommandResult.Ok || result is CommandResult.Rejected,
        )
        println("LiveAgentE2ETest: $what -> $result")
    }

    @Test
    fun fullSessionAgainstLiveAgent() = runBlocking {
        val client = client(pairing.token)
        try {
            client.connect()

            // welcome arrives with a state
            val connected = client.awaitOutcome()
            assertTrue("expected Connected but was $connected", connected is ConnectionState.Connected)
            connected as ConnectionState.Connected
            assertEquals("agent id in welcome must match the pairing URI", pairing.id, connected.agent.id)
            assertTrue("state.profile must not be empty", connected.state.profile.isNotEmpty())
            println("LiveAgentE2ETest: welcome from '${connected.agent.name}', state=${connected.state}")

            // cmd / key / text with an id each get an ack
            assertAcked("cmd playPause", client.command(CmdAction.PlayPause))
            assertAcked("key enter", client.key(KeyName.Enter))
            assertAcked("text", client.text("MyRemote e2e ✓"))

            // pointer, click and scroll can be sent without error
            assertTrue("pointer was not sent", client.pointer(12.5, -3.25))
            assertTrue("click was not sent", client.click(MouseButton.Left, 1))
            assertTrue("scroll was not sent", client.scroll(0.0, -40.5))

            // a ping gets a pong; arriving after the fire-and-forget messages, it also shows
            // that none of them made the agent drop the connection
            val roundTrip = client.ping(timeoutMs = 5_000)
            assertNotNull("no pong within 5 s", roundTrip)
            println("LiveAgentE2ETest: ping round trip $roundTrip ms")
            assertTrue("connection did not survive: ${client.state.value}", client.state.value is ConnectionState.Connected)
        } finally {
            client.disconnect()
        }
    }

    @Test
    fun corruptedTokenEndsInUnauthorized() = runBlocking {
        // Same URI, same certificate pin, but a different (still well-formed) token.
        val first = pairing.token.first()
        val corrupted = (if (first == 'A') 'B' else 'A') + pairing.token.drop(1)
        val client = client(corrupted)
        try {
            client.connect()
            assertEquals(
                ConnectionState.Failed(FailureReason.Unauthorized, retryInMs = null),
                client.awaitOutcome(),
            )
        } finally {
            client.disconnect()
        }
    }

    private companion object {
        const val ENV = "MYREMOTE_E2E_URI"
        const val CONNECT_TIMEOUT_MS = 10_000L
    }
}
