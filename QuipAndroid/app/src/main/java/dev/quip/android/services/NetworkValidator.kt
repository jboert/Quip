package dev.quip.android.services

import java.net.InetAddress
import java.net.URI

/**
 * Validates that cleartext (ws://) connections are only allowed to
 * local/private network addresses (RFC 1918 + loopback + link-local).
 */
object NetworkValidator {

    /**
     * Returns true if the given WebSocket URL is safe to connect to:
     * - wss:// URLs are always allowed (encrypted)
     * - ws:// URLs are only allowed for private/local IP ranges
     */
    fun isSafeUrl(url: String): Boolean {
        val uri = try { URI(url) } catch (e: Exception) { return false }
        val scheme = uri.scheme?.lowercase() ?: return false

        // Encrypted connections are always allowed
        if (scheme == "wss" || scheme == "https") return true

        // Cleartext connections: only allow for private/local networks
        if (scheme == "ws" || scheme == "http") {
            val host = uri.host ?: return false
            return isPrivateNetwork(host)
        }

        return false
    }

    /**
     * Returns true if the host is a private/local network address:
     * - 127.0.0.0/8 (loopback)
     * - 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 (RFC 1918)
     * - 169.254.0.0/16 (link-local)
     * - "localhost"
     */
    fun isPrivateNetwork(host: String): Boolean {
        if (host == "localhost") return true

        val addr = try {
            InetAddress.getByName(host)
        } catch (e: Exception) {
            return false
        }

        return addr.isLoopbackAddress ||
                addr.isSiteLocalAddress ||
                addr.isLinkLocalAddress
    }

    /**
     * Returns true if the URL matches expected Quip connection patterns:
     * - wss://[wildcard].trycloudflare.com (Cloudflare tunnel)
     * - ws:// to private/local IPs (RFC 1918, loopback, link-local, localhost)
     */
    fun isURLTrusted(url: String): Boolean {
        val uri = try { URI(url) } catch (e: Exception) { return false }
        val scheme = uri.scheme?.lowercase() ?: return false
        val host = uri.host?.lowercase() ?: return false

        // wss:// to *.trycloudflare.com is trusted
        if (scheme == "wss" && (host == "trycloudflare.com" || host.endsWith(".trycloudflare.com"))) {
            return true
        }

        // ws:// to local/private IPs is trusted
        if (scheme == "ws") {
            return isPrivateNetwork(host)
        }

        return false
    }
}
