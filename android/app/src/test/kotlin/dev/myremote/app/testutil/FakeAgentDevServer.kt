package dev.myremote.app.testutil

import dev.myremote.app.core.protocol.AckErrors
import dev.myremote.app.core.protocol.ClientMessage
import dev.myremote.app.core.protocol.CmdAction
import dev.myremote.app.core.protocol.ProtocolCodec
import dev.myremote.app.core.protocol.ServerMessage
import java.io.File
import org.junit.Assume.assumeTrue
import org.junit.Test

/**
 * Not a test: a way to run [FakeAgent] as a long-lived server so the app can be tried on an
 * emulator without the Mac agent. Skipped unless `MYREMOTE_FAKE_AGENT_DIR` names a directory.
 *
 *     MYREMOTE_FAKE_AGENT_DIR=/some/dir ./gradlew testDebugUnitTest --tests '*FakeAgentDevServer' --rerun
 *
 * In that directory it writes `pairing-uri.txt` (with host 10.0.2.2, the emulator's name for the
 * host machine) and appends every received message to `received.log`. It answers every command
 * with `ok`, except `toggleSubtitles`, which is `unsupported`. To push a state, write a `state`
 * message as JSON to `push.json`. Create a file named `reset-pairing` to change the token and
 * drop all clients, like "Reset pairing" on the real agent. Create a file named `stop` to shut
 * it down. The certificate is generated at start, so the app has to be paired again after a restart.
 */
class FakeAgentDevServer {
    @Test
    fun serve() {
        val dirName = System.getenv("MYREMOTE_FAKE_AGENT_DIR").orEmpty()
        assumeTrue("MYREMOTE_FAKE_AGENT_DIR is not set", dirName.isNotEmpty())
        val dir = File(dirName).apply { mkdirs() }
        val log = File(dir, "received.log").apply { writeText("") }
        val push = File(dir, "push.json")
        val reset = File(dir, "reset-pairing").apply { delete() }
        val stop = File(dir, "stop").apply { delete() }

        val agent = FakeAgent()
        agent.ackFor = { message, id ->
            if (message is ClientMessage.Cmd && message.action == CmdAction.ToggleSubtitles) {
                ServerMessage.Ack(id, ok = false, error = AckErrors.UNSUPPORTED)
            } else {
                ServerMessage.Ack(id, ok = true)
            }
        }
        agent.start(port = System.getenv("MYREMOTE_FAKE_AGENT_PORT")?.toIntOrNull() ?: 0)
        try {
            File(dir, "pairing-uri.txt").writeText(agent.pairingUri(host = "10.0.2.2") + "\n")
            val logged = HashMap<FakeAgent.Connection, Int>()
            while (!stop.exists()) {
                for (connection in agent.connections) {
                    val seen = logged[connection] ?: 0
                    val all = connection.received.toList()
                    all.drop(seen).forEach { log.appendText(ProtocolCodec.encode(it) + "\n") }
                    logged[connection] = all.size
                }
                if (reset.exists()) {
                    reset.delete()
                    agent.resetPairing("AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA")
                }
                if (push.exists()) {
                    val message = ProtocolCodec.decodeServer(push.readText())
                    push.delete()
                    if (message is ServerMessage.State) agent.pushState(message.state)
                }
                Thread.sleep(100)
            }
        } finally {
            agent.close()
        }
    }
}
