package dev.quip.android.services

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.net.wifi.WifiManager
import android.os.Handler
import android.os.Looper
import android.util.Log
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.launch

data class DiscoveredHost(
    val name: String,
    val host: String,
    val port: Int
) {
    val wsUrl: String get() = "ws://$host:$port"
}

class NsdBrowser {

    companion object {
        private const val TAG = "NsdBrowser"
        private const val SERVICE_TYPE = "_quip._tcp."
    }

    var discoveredHosts: List<DiscoveredHost> = emptyList()
        private set
    var isSearching: Boolean = false
        private set

    var onHostsChanged: (() -> Unit)? = null

    private var nsdManager: NsdManager? = null
    private var multicastLock: WifiManager.MulticastLock? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    // Channel-based resolve queue replaces LinkedList+synchronized+volatile
    private val resolveChannel = Channel<NsdServiceInfo>(Channel.UNLIMITED)
    private val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())

    private val discoveryListener = object : NsdManager.DiscoveryListener {
        override fun onDiscoveryStarted(serviceType: String) {
            Log.i(TAG, "Discovery started for $serviceType")
        }

        override fun onDiscoveryStopped(serviceType: String) {
            Log.i(TAG, "Discovery stopped for $serviceType")
        }

        override fun onServiceFound(serviceInfo: NsdServiceInfo) {
            Log.i(TAG, "Found service: ${serviceInfo.serviceName}")
            resolveChannel.trySend(serviceInfo)
        }

        override fun onServiceLost(serviceInfo: NsdServiceInfo) {
            Log.i(TAG, "Lost service: ${serviceInfo.serviceName}")
            mainHandler.post {
                discoveredHosts = discoveredHosts.filter { it.name != serviceInfo.serviceName }
                onHostsChanged?.invoke()
            }
        }

        override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {
            Log.e(TAG, "Start discovery failed: $errorCode")
            isSearching = false
        }

        override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) {
            Log.e(TAG, "Stop discovery failed: $errorCode")
        }
    }

    fun startDiscovery(context: Context) {
        if (isSearching) return

        discoveredHosts = emptyList()

        // Launch coroutine that processes resolves serially from the channel
        scope.launch {
            for (serviceInfo in resolveChannel) {
                resolveService(serviceInfo)
            }
        }

        // Acquire multicast lock so WiFi chipset doesn't filter mDNS packets
        val wifiManager = context.applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
        val lock = wifiManager.createMulticastLock("quip_mdns")
        lock.setReferenceCounted(true)
        lock.acquire()
        multicastLock = lock
        Log.i(TAG, "Multicast lock acquired")

        val manager = context.getSystemService(Context.NSD_SERVICE) as NsdManager
        nsdManager = manager

        manager.discoverServices(SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, discoveryListener)
        isSearching = true
        Log.i(TAG, "Searching...")
    }

    fun stopDiscovery() {
        if (!isSearching) return
        try {
            nsdManager?.stopServiceDiscovery(discoveryListener)
        } catch (e: Exception) {
            Log.w(TAG, "Error stopping discovery: ${e.message}")
        }
        nsdManager = null
        isSearching = false
        scope.cancel()

        try {
            multicastLock?.release()
            multicastLock = null
            Log.i(TAG, "Multicast lock released")
        } catch (e: Exception) {
            Log.w(TAG, "Error releasing multicast lock: ${e.message}")
        }
    }

    /**
     * Resolves a single service using suspendCoroutine to bridge the callback API.
     * Called serially from the channel consumer coroutine, ensuring NSD resolves one at a time.
     */
    @Suppress("DEPRECATION")
    private suspend fun resolveService(serviceInfo: NsdServiceInfo) {
        val manager = nsdManager ?: return

        kotlin.coroutines.suspendCoroutine { cont ->
            manager.resolveService(serviceInfo, object : NsdManager.ResolveListener {
                override fun onResolveFailed(info: NsdServiceInfo, errorCode: Int) {
                    Log.e(TAG, "Resolve failed for ${info.serviceName}: $errorCode")
                    cont.resumeWith(Result.success(Unit))
                }

                override fun onServiceResolved(info: NsdServiceInfo) {
                    val host = info.host?.hostAddress
                    if (host != null) {
                        val port = info.port
                        Log.i(TAG, "Resolved: ${info.serviceName} -> $host:$port")

                        val discovered = DiscoveredHost(
                            name = info.serviceName,
                            host = host,
                            port = port
                        )

                        mainHandler.post {
                            if (discoveredHosts.none { it.host == host && it.port == port }) {
                                discoveredHosts = discoveredHosts + discovered
                                onHostsChanged?.invoke()
                            }
                        }
                    }

                    cont.resumeWith(Result.success(Unit))
                }
            })
        }
    }
}
