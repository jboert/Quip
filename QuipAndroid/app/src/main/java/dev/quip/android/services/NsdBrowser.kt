package dev.quip.android.services

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.net.wifi.WifiManager
import android.os.Handler
import android.os.Looper
import android.util.Log
import java.util.LinkedList

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

    // NSD can only resolve one service at a time; queue the rest
    private val resolveQueue = LinkedList<NsdServiceInfo>()
    @Volatile private var isResolving = false

    private val discoveryListener = object : NsdManager.DiscoveryListener {
        override fun onDiscoveryStarted(serviceType: String) {
            Log.i(TAG, "Discovery started for $serviceType")
        }

        override fun onDiscoveryStopped(serviceType: String) {
            Log.i(TAG, "Discovery stopped for $serviceType")
        }

        override fun onServiceFound(serviceInfo: NsdServiceInfo) {
            Log.i(TAG, "Found service: ${serviceInfo.serviceName}")
            enqueueResolve(serviceInfo)
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
        resolveQueue.clear()
        isResolving = false

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
        resolveQueue.clear()
        isResolving = false

        try {
            multicastLock?.release()
            multicastLock = null
            Log.i(TAG, "Multicast lock released")
        } catch (e: Exception) {
            Log.w(TAG, "Error releasing multicast lock: ${e.message}")
        }
    }

    private fun enqueueResolve(serviceInfo: NsdServiceInfo) {
        synchronized(resolveQueue) {
            resolveQueue.add(serviceInfo)
            if (!isResolving) {
                resolveNext()
            }
        }
    }

    private fun resolveNext() {
        val serviceInfo: NsdServiceInfo
        synchronized(resolveQueue) {
            serviceInfo = resolveQueue.poll() ?: run {
                isResolving = false
                return
            }
            isResolving = true
        }

        val manager = nsdManager ?: return

        manager.resolveService(serviceInfo, object : NsdManager.ResolveListener {
            override fun onResolveFailed(info: NsdServiceInfo, errorCode: Int) {
                Log.e(TAG, "Resolve failed for ${info.serviceName}: $errorCode")
                resolveNext()
            }

            override fun onServiceResolved(info: NsdServiceInfo) {
                val host = info.host?.hostAddress ?: return
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

                resolveNext()
            }
        })
    }
}
