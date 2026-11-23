package dev.myremote.app.core.discovery

import java.net.InetAddress
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.currentTime
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class ReconnectTargetResolverTest {
    private val agentId = "0123456789abcdef"
    private val lastKnown = Endpoint("192.168.1.42", 47110)
    private val discovered = Endpoint("192.168.1.77", 50123)

    @Test
    fun usesTheMdnsResultWhenItArrivesInTime() = runTest {
        val asked = ArrayList<String>()
        val resolver = ReconnectTargetResolver(agentId, discovery = { id ->
            asked += id
            delay(2_999)
            discovered
        }, lastKnown = { lastKnown })

        assertEquals(discovered, resolver.resolve())
        assertEquals(2_999, currentTime)
        assertEquals("the lookup is by agent id", listOf(agentId), asked)
    }

    @Test
    fun fallsBackToLastKnownAddressAfterExactlyThreeSeconds() = runTest {
        var discoveryCancelled = false
        val resolver = ReconnectTargetResolver(agentId, discovery = {
            try {
                awaitCancellation()
            } catch (e: CancellationException) {
                discoveryCancelled = true
                throw e
            }
        }, lastKnown = { lastKnown })

        var result: Endpoint? = null
        val job = launch { result = resolver.resolve() }
        advanceTimeBy(2_999)
        runCurrent()
        assertNull("must keep waiting for mDNS until 3 s have passed", result)
        advanceTimeBy(1)
        runCurrent()
        assertEquals(lastKnown, result)
        assertEquals(3_000, currentTime)
        assertTrue("the mDNS lookup must be stopped on fallback", discoveryCancelled)
        job.join()
    }

    @Test
    fun anAnswerThatComesTooLateIsNotUsed() = runTest {
        val resolver = ReconnectTargetResolver(agentId, discovery = {
            delay(3_001)
            discovered
        }, lastKnown = { lastKnown })
        assertEquals(lastKnown, resolver.resolve())
        assertEquals(3_000, currentTime)
    }

    @Test
    fun fallsBackImmediatelyWhenDiscoveryCannotRun() = runTest {
        val resolver = ReconnectTargetResolver(agentId, discovery = { throw IllegalStateException("NSD unavailable") }, lastKnown = { lastKnown })
        assertEquals(lastKnown, resolver.resolve())
        assertEquals(0, currentTime)
    }

    @Test
    fun readsTheLastKnownAddressAtFallbackTime() = runTest {
        var stored = lastKnown
        val resolver = ReconnectTargetResolver(agentId, discovery = { awaitCancellation() }, lastKnown = { stored })
        assertEquals(lastKnown, resolver.resolve())
        stored = Endpoint("10.0.0.9", 47111)
        assertEquals(Endpoint("10.0.0.9", 47111), resolver.resolve())
    }

    @Test
    fun directFirstSkipsDiscoveryOnlyForTheFirstAttempt() = runTest {
        var lookups = 0
        val resolver = ReconnectTargetResolver(agentId, discovery = {
            lookups++
            discovered
        }, lastKnown = { lastKnown }, directFirst = true)

        assertEquals(lastKnown, resolver.resolve())
        assertEquals(0, lookups)
        assertEquals(discovered, resolver.resolve())
        assertEquals(1, lookups)
    }

    @Test
    fun cancellingTheResolverCancelsDiscovery() = runTest {
        var discoveryCancelled = false
        val resolver = ReconnectTargetResolver(agentId, discovery = {
            try {
                awaitCancellation()
            } catch (e: CancellationException) {
                discoveryCancelled = true
                throw e
            }
        }, lastKnown = { lastKnown })
        val job = launch { resolver.resolve() }
        runCurrent()
        job.cancel()
        job.join()
        assertTrue(discoveryCancelled)
        assertTrue(job.isCancelled)
    }

    @Test
    fun picksIpv4OverIpv6AndSkipsLinkLocalIpv6() {
        val v4 = InetAddress.getByName("192.168.1.42")
        val linkLocal = InetAddress.getByName("fe80::1")
        val global = InetAddress.getByName("2001:db8::7")
        assertEquals("192.168.1.42", pickConnectableAddress(listOf(linkLocal, global, v4)))
        assertEquals(global.hostAddress, pickConnectableAddress(listOf(linkLocal, global)))
        assertNull(pickConnectableAddress(listOf(linkLocal)))
        assertNull(pickConnectableAddress(emptyList()))
    }
}
