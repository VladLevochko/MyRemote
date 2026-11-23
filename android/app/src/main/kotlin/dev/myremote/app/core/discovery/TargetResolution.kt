package dev.myremote.app.core.discovery

import java.net.Inet4Address
import java.net.Inet6Address
import java.net.InetAddress
import kotlin.coroutines.cancellation.CancellationException
import kotlinx.coroutines.withTimeoutOrNull

/** Where to open the WebSocket. [host] is an IPv4 literal, a hostname or an unbracketed IPv6 literal. */
data class Endpoint(val host: String, val port: Int)

/** Decides which endpoint the next connection attempt should use. */
fun interface TargetResolver {
    suspend fun resolve(): Endpoint
}

/**
 * Finds a paired agent on the local network by the `id` TXT record of its `_myremote._tcp`
 * service. The Android implementation wraps NsdManager; tests use a fake.
 */
fun interface AgentDiscovery {
    /**
     * Suspends until an agent advertising [agentId] has been found and resolved. Must be
     * cancellable and release platform resources on cancellation. May throw if discovery cannot
     * run at all.
     */
    suspend fun find(agentId: String): Endpoint
}

/**
 * Reconnect rule from PROTOCOL.md section 3: look the agent up over mDNS by `id` first, and if
 * that has not produced an answer within 3 s use the last known `host:port`.
 *
 * @param lastKnown read at the moment of fallback, so it can track the persisted value.
 * @param directFirst when true the very first [resolve] skips discovery and returns [lastKnown].
 *   Used right after pairing, when `host:port` came straight from the pairing URI and this is a
 *   first connection rather than a reconnect.
 */
class ReconnectTargetResolver(
    private val agentId: String,
    private val discovery: AgentDiscovery,
    private val lastKnown: () -> Endpoint,
    private val discoveryTimeoutMs: Long = DISCOVERY_TIMEOUT_MS,
    directFirst: Boolean = false,
) : TargetResolver {
    private var direct = directFirst

    override suspend fun resolve(): Endpoint {
        if (direct) {
            direct = false
            return lastKnown()
        }
        val discovered = try {
            withTimeoutOrNull(discoveryTimeoutMs) { discovery.find(agentId) }
        } catch (e: CancellationException) {
            throw e
        } catch (_: Exception) {
            // Discovery being unavailable must not block reconnecting to the last known address.
            null
        }
        return discovered ?: lastKnown()
    }

    companion object {
        const val DISCOVERY_TIMEOUT_MS = 3_000L
    }
}

/**
 * Picks the address to connect to from what mDNS resolved for a service. IPv4 is preferred.
 * Link-local IPv6 is skipped because it needs a scope id, which a URL cannot carry.
 */
fun pickConnectableAddress(addresses: List<InetAddress>): String? {
    addresses.firstOrNull { it is Inet4Address }?.let { return it.hostAddress }
    return addresses
        .firstOrNull { it is Inet6Address && !it.isLinkLocalAddress && it.scopeId == 0 }
        ?.hostAddress
}
