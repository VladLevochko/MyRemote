package dev.myremote.app.core.protocol

import dev.myremote.app.testutil.Fixtures
import dev.myremote.app.testutil.JsonSemantics.assertSameJson
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Contract tests against the shared fixtures in `protocol/fixtures` (also used by the Mac agent). */
class FixtureContractTest {
    private val clientTypes = mapOf(
        "hello" to ClientMessage.Hello::class,
        "cmd" to ClientMessage.Cmd::class,
        "key" to ClientMessage.Key::class,
        "pointer" to ClientMessage.Pointer::class,
        "click" to ClientMessage.Click::class,
        "scroll" to ClientMessage.Scroll::class,
        "text" to ClientMessage.Text::class,
        "ping" to ClientMessage.Ping::class,
    )

    private val serverTypes = mapOf(
        "welcome" to ServerMessage.Welcome::class,
        "ack" to ServerMessage.Ack::class,
        "state" to ServerMessage.State::class,
        "pong" to ServerMessage.Pong::class,
        "error" to ServerMessage.Error::class,
    )

    private fun typeOf(json: String) = Json.parseToJsonElement(json).jsonObject.getValue("type").jsonPrimitive.content

    @Test
    fun everyClientFixtureDecodesToItsTypedModelAndReencodesToTheSameJson() {
        val fixtures = Fixtures.messages("client")
        for ((name, json) in fixtures) {
            val message = ProtocolCodec.decodeClient(json)
            assertEquals("client/$name decoded to the wrong model", clientTypes.getValue(typeOf(json)), message::class)
            assertSameJson("client/$name", json, ProtocolCodec.encode(message))
        }
        // Every message type of section 4.2 must be exercised by at least one fixture.
        assertEquals(clientTypes.keys, fixtures.values.map(::typeOf).toSet())
    }

    @Test
    fun everyServerFixtureDecodesToItsTypedModelAndReencodesToTheSameJson() {
        val fixtures = Fixtures.messages("server")
        for ((name, json) in fixtures) {
            val message = ProtocolCodec.decodeServer(json)
            assertEquals("server/$name decoded to the wrong model", serverTypes.getValue(typeOf(json)), message::class)
            assertSameJson("server/$name", json, ProtocolCodec.encode(message))
        }
        assertEquals(serverTypes.keys, fixtures.values.map(::typeOf).toSet())
    }

    @Test
    fun clientFixturesCarryTheExpectedValues() {
        fun client(name: String) = ProtocolCodec.decodeClient(Fixtures.read("client/$name"))

        assertEquals(
            ClientMessage.Hello(1, "q83vEjRWeJCrze8SNFZ4kKvN7xI0VniQq83vEjRWeJA", "Galaxy S24"),
            client("hello.json"),
        )
        assertEquals(ClientMessage.Cmd(CmdAction.PlayPause, 7), client("cmd_with_id.json"))
        assertEquals(ClientMessage.Cmd(CmdAction.SeekForward, null), client("cmd_without_id.json"))
        assertEquals(ClientMessage.Key(KeyName.Enter, 8), client("key.json"))
        assertEquals(ClientMessage.Pointer(12.5, -3.25), client("pointer.json"))
        assertEquals(ClientMessage.Click(MouseButton.Left, 1), client("click_left.json"))
        assertEquals(ClientMessage.Click(MouseButton.Right, 2), client("click_right_double.json"))
        assertEquals(ClientMessage.Scroll(0.0, -40.5), client("scroll.json"))
        assertEquals(ClientMessage.Text("Привіт, світ! 🎬 \"quoted\"", 9), client("text.json"))
        assertEquals(ClientMessage.Ping(1790000000123), client("ping.json"))
    }

    @Test
    fun serverFixturesCarryTheExpectedValues() {
        fun server(name: String) = ProtocolCodec.decodeServer(Fixtures.read("server/$name"))

        assertEquals(
            ServerMessage.Welcome(
                v = 1,
                agent = AgentInfo("0123456789abcdef", "MacBook Pro"),
                state = RemoteState(FrontApp("com.google.Chrome", "Google Chrome"), "youtube", true),
            ),
            server("welcome.json"),
        )
        assertEquals(ServerMessage.Ack(7, ok = true, error = null), server("ack_ok.json"))
        assertEquals(ServerMessage.Ack(8, ok = false, error = "accessibility_denied"), server("ack_error.json"))
        assertEquals(
            ServerMessage.State(RemoteState(FrontApp("com.apple.TV", "TV"), "appletv", true)),
            server("state_appletv.json"),
        )
        val noFrontApp = server("state_no_front_app.json") as ServerMessage.State
        assertNull(noFrontApp.state.frontApp)
        assertEquals("generic", noFrontApp.state.profile)
        assertEquals(false, noFrontApp.state.accessibility)
        assertEquals(ServerMessage.Pong(1790000000123), server("pong.json"))
        assertEquals(ServerMessage.Error("unauthorized", "invalid token"), server("error.json"))
    }

    @Test
    fun optionalIdIsOmittedNotNullWhenAbsent() {
        val encoded = ProtocolCodec.encode(ClientMessage.Cmd(CmdAction.SeekForward))
        assertTrue(encoded, "\"id\"" !in encoded)
        assertSameJson("cmd without id", """{"type":"cmd","action":"seekForward"}""", encoded)
    }
}
