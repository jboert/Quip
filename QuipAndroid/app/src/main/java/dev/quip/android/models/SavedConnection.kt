package dev.quip.android.models

import java.net.URL
import java.util.UUID

data class SavedConnection(
    val id: String = UUID.randomUUID().toString(),
    val url: String,
    val name: String? = null,
    val pinned: Boolean = false,
    val lastUsed: Long = System.currentTimeMillis()
) {
    val displayName: String
        get() = name?.takeIf { it.isNotEmpty() }
            ?: try {
                URL(url).host?.replace(".trycloudflare.com", "") ?: url
            } catch (_: Exception) {
                url
            }
}
