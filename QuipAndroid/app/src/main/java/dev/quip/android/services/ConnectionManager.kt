package dev.quip.android.services

import android.content.Context
import com.google.gson.Gson
import com.google.gson.reflect.TypeToken
import dev.quip.android.models.SavedConnection

object ConnectionManager {

    private const val PREFS_NAME = "quip_connections"
    private const val KEY_RECENTS = "recent_connections"
    private const val MAX_CONNECTIONS = 10

    private val gson = Gson()

    fun loadRecents(context: Context): List<SavedConnection> {
        val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val json = prefs.getString(KEY_RECENTS, null) ?: return emptyList()
        val type = object : TypeToken<List<SavedConnection>>() {}.type
        return try {
            val connections: List<SavedConnection> = gson.fromJson(json, type)
            connections.sortedWith(
                compareByDescending<SavedConnection> { it.pinned }
                    .thenByDescending { it.lastUsed }
            )
        } catch (_: Exception) {
            emptyList()
        }
    }

    fun saveRecent(context: Context, url: String) {
        val connections = loadRecents(context).toMutableList()

        // Update existing or add new
        val existingIndex = connections.indexOfFirst { it.url == url }
        if (existingIndex >= 0) {
            val existing = connections[existingIndex]
            connections[existingIndex] = existing.copy(lastUsed = System.currentTimeMillis())
        } else {
            connections.add(SavedConnection(url = url))
        }

        // Trim to max, but never remove pinned
        val sorted = connections.sortedWith(
            compareByDescending<SavedConnection> { it.pinned }
                .thenByDescending { it.lastUsed }
        )
        val trimmed = if (sorted.size > MAX_CONNECTIONS) {
            val pinned = sorted.filter { it.pinned }
            val unpinned = sorted.filter { !it.pinned }
            pinned + unpinned.take(MAX_CONNECTIONS - pinned.size)
        } else {
            sorted
        }

        persist(context, trimmed)
    }

    fun togglePin(context: Context, id: String) {
        val connections = loadRecents(context).toMutableList()
        val index = connections.indexOfFirst { it.id == id }
        if (index >= 0) {
            val conn = connections[index]
            connections[index] = conn.copy(pinned = !conn.pinned)
            persist(context, connections)
        }
    }

    fun rename(context: Context, id: String, newName: String) {
        val connections = loadRecents(context).toMutableList()
        val index = connections.indexOfFirst { it.id == id }
        if (index >= 0) {
            val conn = connections[index]
            connections[index] = conn.copy(name = newName.ifBlank { null })
            persist(context, connections)
        }
    }

    fun delete(context: Context, id: String) {
        val connections = loadRecents(context).toMutableList()
        connections.removeAll { it.id == id }
        persist(context, connections)
    }

    private fun persist(context: Context, connections: List<SavedConnection>) {
        val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val json = gson.toJson(connections)
        prefs.edit().putString(KEY_RECENTS, json).apply()
    }
}
