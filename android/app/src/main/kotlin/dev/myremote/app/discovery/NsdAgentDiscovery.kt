package dev.myremote.app.discovery

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Build
import dev.myremote.app.core.discovery.AgentDiscovery
import dev.myremote.app.core.discovery.Endpoint
import dev.myremote.app.core.discovery.pickConnectableAddress
import kotlin.coroutines.resume
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/**
 * Finds the paired agent with Android's NsdManager: browses `_myremote._tcp`, resolves each
 * service and returns the first whose TXT record `id` equals the paired agent id
 * (PROTOCOL.md section 2).
 */
class NsdAgentDiscovery(context: Context) : AgentDiscovery {
    private val nsd = context.applicationContext.getSystemService(NsdManager::class.java)

    // Before Android 14 NsdManager fails a resolve that starts while another is running.
    private val resolveLock = Mutex()

    override suspend fun find(agentId: String): Endpoint {
        val manager = nsd ?: error("NsdManager is not available")
        val found = Channel<NsdServiceInfo>(Channel.UNLIMITED)
        val listener = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(serviceType: String) = Unit

            override fun onDiscoveryStopped(serviceType: String) = Unit

            override fun onServiceFound(serviceInfo: NsdServiceInfo) {
                found.trySend(serviceInfo)
            }

            override fun onServiceLost(serviceInfo: NsdServiceInfo) = Unit

            override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {
                found.close(IllegalStateException("mDNS discovery could not start (NsdManager error $errorCode)"))
            }

            override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) = Unit
        }
        manager.discoverServices(SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, listener)
        try {
            for (candidate in found) {
                val resolved = resolve(manager, candidate) ?: continue
                val id = resolved.attributes[TXT_ID]?.toString(Charsets.UTF_8)
                if (id != agentId) continue
                val host = pickConnectableAddress(addressesOf(resolved)) ?: continue
                return Endpoint(host, resolved.port)
            }
            error("mDNS discovery ended without a result")
        } finally {
            // Throws if discovery never started; either way there is nothing left to stop.
            runCatching { manager.stopServiceDiscovery(listener) }
        }
    }

    private suspend fun resolve(manager: NsdManager, info: NsdServiceInfo): NsdServiceInfo? = resolveLock.withLock {
        suspendCancellableCoroutine { continuation ->
            val listener = object : NsdManager.ResolveListener {
                override fun onResolveFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {
                    if (continuation.isActive) continuation.resume(null)
                }

                override fun onServiceResolved(serviceInfo: NsdServiceInfo) {
                    if (continuation.isActive) continuation.resume(serviceInfo)
                }
            }
            // The one-shot resolve exists on every supported API level (28+). Its replacement,
            // registerServiceInfoCallback, needs API 34 and keeps a subscription open, which a
            // single lookup does not need.
            @Suppress("DEPRECATION")
            manager.resolveService(info, listener)
        }
    }

    private fun addressesOf(info: NsdServiceInfo) =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            info.hostAddresses
        } else {
            @Suppress("DEPRECATION")
            listOfNotNull(info.host)
        }

    private companion object {
        const val SERVICE_TYPE = "_myremote._tcp"
        const val TXT_ID = "id"
    }
}
