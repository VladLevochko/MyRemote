package dev.myremote.app.testutil

import dev.myremote.app.core.discovery.Endpoint
import dev.myremote.app.core.net.ClientIdentity
import dev.myremote.app.core.net.ConnectionState
import dev.myremote.app.core.net.RemoteClient
import dev.myremote.app.core.net.RemoteTimings
import java.io.Closeable
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.cancel
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestCoroutineScheduler
import okhttp3.OkHttpClient
import org.junit.Assert.fail

/**
 * Runs a [RemoteClient] with virtual time against a real socket.
 *
 * Every client timer (heartbeat, timeouts, backoff) lives on [scheduler] and only moves when the
 * test calls [advance]. Network I/O is real, so the test waits for it with [await], which keeps
 * running whatever the socket threads have queued but never moves the virtual clock. No test
 * sleeps through a protocol timeout.
 */
class ClientHarness(
    fingerprint: String,
    token: String,
    private val target: () -> Endpoint,
    timings: RemoteTimings = RemoteTimings(),
) : Closeable {
    val scheduler = TestCoroutineScheduler()
    private val scope = CoroutineScope(SupervisorJob() + StandardTestDispatcher(scheduler))
    private val http = OkHttpClient.Builder().connectTimeout(2, TimeUnit.SECONDS).build()

    /** Virtual time of every address resolution, which is the start of every connection attempt. */
    val attemptTimes = ArrayList<Long>()

    val client = RemoteClient(
        identity = ClientIdentity(fingerprint, token, deviceName = "Test Phone"),
        resolver = {
            attemptTimes += scheduler.currentTime
            target()
        },
        scope = scope,
        clock = { scheduler.currentTime },
        timings = timings,
        httpClient = http,
    )

    val state: ConnectionState get() = client.state.value

    val now: Long get() = scheduler.currentTime

    /** Moves virtual time forward, running every timer that becomes due, including at the new instant. */
    fun advance(ms: Long) {
        scheduler.advanceTimeBy(ms)
        scheduler.runCurrent()
    }

    /** Waits in real time, without moving virtual time, until [condition] holds. */
    fun await(what: String, timeoutMs: Long = 5_000, condition: () -> Boolean) {
        val deadline = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(timeoutMs)
        while (true) {
            scheduler.runCurrent()
            if (condition()) return
            if (System.nanoTime() > deadline) fail("timed out waiting for $what; state=$state")
            Thread.sleep(2)
        }
    }

    inline fun <reified T : ConnectionState> awaitState(what: String = T::class.java.simpleName): T {
        await(what) { state is T }
        return state as T
    }

    fun connectAndAwait(): ConnectionState.Connected {
        client.connect()
        return awaitState()
    }

    /** Starts a suspending client call on the virtual-time dispatcher. */
    fun <T> start(block: suspend RemoteClient.() -> T): Deferred<T> = scope.async { client.block() }

    fun <T> awaitResult(deferred: Deferred<T>, what: String = "result"): T {
        await(what) { deferred.isCompleted }
        @Suppress("OPT_IN_USAGE")
        return deferred.getCompleted()
    }

    override fun close() {
        client.disconnect()
        scheduler.runCurrent()
        scope.cancel()
        http.dispatcher.executorService.shutdown()
        http.connectionPool.evictAll()
    }
}
