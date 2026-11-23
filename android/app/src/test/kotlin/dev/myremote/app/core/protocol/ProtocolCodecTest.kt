package dev.myremote.app.core.protocol

import dev.myremote.app.testutil.JsonSemantics.assertSameJson
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class ProtocolCodecTest {
    @Test
    fun unknownServerTypeDecodesToUnknownInsteadOfFailing() {
        assertEquals(
            ServerMessage.Unknown("telemetry"),
            ProtocolCodec.decodeServer("""{"type":"telemetry","cpu":0.5,"nested":{"a":[1,2]}}"""),
        )
    }

    @Test
    fun unknownFieldsAreIgnoredAtEveryLevel() {
        val welcome = ProtocolCodec.decodeServer(
            """
            {"type":"welcome","v":1,"motd":"hi",
             "agent":{"id":"0123456789abcdef","name":"Mac","os":"27.0"},
             "state":{"frontApp":{"bundleId":"a.b","name":"B","pid":4},"profile":"generic","accessibility":true,"volume":0.4}}
            """.trimIndent(),
        )
        assertEquals(
            ServerMessage.Welcome(1, AgentInfo("0123456789abcdef", "Mac"), RemoteState(FrontApp("a.b", "B"), "generic", true)),
            welcome,
        )
        assertEquals(ServerMessage.Ack(3, true), ProtocolCodec.decodeServer("""{"type":"ack","id":3,"ok":true,"took":12}"""))
    }

    @Test
    fun aProfileFromANewerAgentStillDecodes() {
        val state = ProtocolCodec.decodeServer(
            """{"type":"state","state":{"frontApp":null,"profile":"disneyplus","accessibility":true}}""",
        ) as ServerMessage.State
        assertEquals("disneyplus", state.state.profile)
    }

    @Test
    fun stateWithoutFrontAppKeyDecodesAsNull() {
        val state = ProtocolCodec.decodeServer(
            """{"type":"state","state":{"profile":"generic","accessibility":true}}""",
        ) as ServerMessage.State
        assertEquals(RemoteState(null, "generic", true), state.state)
    }

    @Test
    fun malformedInputIsReportedAsProtocolException() {
        for (bad in listOf("", "not json", "[1,2]", "42", """{"no":"type"}""", """{"type":7}""", """{"type":"ack","ok":true}""")) {
            assertThrows("should reject: $bad", ProtocolException::class.java) { ProtocolCodec.decodeServer(bad) }
        }
        assertThrows(ProtocolException::class.java) { ProtocolCodec.decodeClient("""{"type":"launchMissiles"}""") }
        assertThrows(ProtocolException::class.java) { ProtocolCodec.decodeClient("""{"type":"cmd","action":"dance"}""") }
        assertThrows(ProtocolException::class.java) {
            ProtocolCodec.decodeClient("""{"type":"click","button":"left","count":3}""")
        }
    }

    @Test
    fun everyActionAndKeyUsesItsContractSpelling() {
        val actions = CmdAction.entries.map { ProtocolCodec.encode(ClientMessage.Cmd(it)) }
        assertEquals(
            listOf(
                "playPause", "seekBackward", "seekForward", "volumeUp", "volumeDown", "toggleMute",
                "toggleFullscreen", "nextItem", "previousItem", "skip", "toggleSubtitles",
            ).map { """{"type":"cmd","action":"$it"}""" },
            actions,
        )
        val keys = KeyName.entries.map { ProtocolCodec.encode(ClientMessage.Key(it)) }
        assertEquals(
            listOf("up", "down", "left", "right", "enter", "escape", "space", "tab", "backspace")
                .map { """{"type":"key","key":"$it"}""" },
            keys,
        )
    }

    @Test
    fun fractionalDeltasAndUnicodeTextSurviveEncoding() {
        assertSameJson("pointer", """{"type":"pointer","dx":0.125,"dy":-7}""", ProtocolCodec.encode(ClientMessage.Pointer(0.125, -7.0)))
        val text = ClientMessage.Text("рядок \"з лапками\" \\ і емодзі 🍿\nновий", 1)
        assertEquals(text, ProtocolCodec.decodeClient(ProtocolCodec.encode(text)))
    }
}
