package dev.shieldbridge

import android.content.Context
import android.net.Uri
import java.io.File
import java.io.FileOutputStream
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest

/**
 * Fetches poster art once and serves it from disk afterwards, so Control4
 * touch screens load every image from the LAN and never talk to a streaming
 * service's CDN directly.
 */
class ArtCache(ctx: Context) {
    private val dir = File(ctx.cacheDir, "art").apply { mkdirs() }
    private val resolver = ctx.contentResolver

    data class Entry(val file: File, val mime: String)

    @Synchronized
    fun get(uri: String): Entry? {
        val key = sha1(uri)
        val data = File(dir, "$key.bin")
        val meta = File(dir, "$key.type")
        if (data.exists() && data.length() > 0) {
            val mime = if (meta.exists()) meta.readText().trim() else "image/jpeg"
            data.setLastModified(System.currentTimeMillis())
            return Entry(data, mime)
        }
        val fetched = fetch(uri) ?: return null
        val tmp = File(dir, "$key.tmp")
        try {
            fetched.first.use { input -> FileOutputStream(tmp).use { out -> input.copyTo(out) } }
            if (tmp.length() == 0L) {
                tmp.delete()
                return null
            }
            tmp.renameTo(data)
            meta.writeText(fetched.second)
        } catch (e: Exception) {
            tmp.delete()
            return null
        }
        prune()
        return Entry(data, fetched.second)
    }

    /** Returns stream + mime type, or null when the source cannot be read. */
    private fun fetch(uri: String): Pair<InputStream, String>? {
        return try {
            if (uri.startsWith("content://") || uri.startsWith("android.resource://") || uri.startsWith("file://")) {
                val parsed = Uri.parse(uri)
                val stream = resolver.openInputStream(parsed) ?: return null
                val mime = resolver.getType(parsed) ?: "image/png"
                Pair(stream, mime)
            } else {
                val conn = URL(uri).openConnection() as HttpURLConnection
                conn.connectTimeout = 8000
                conn.readTimeout = 15000
                conn.instanceFollowRedirects = true
                conn.setRequestProperty("User-Agent", "ShieldBridge/1.0")
                if (conn.responseCode !in 200..299) {
                    conn.disconnect()
                    return null
                }
                val mime = conn.contentType?.substringBefore(';')?.trim()?.ifEmpty { null } ?: "image/jpeg"
                Pair(conn.inputStream, mime)
            }
        } catch (e: Exception) {
            null
        }
    }

    /** Keep the cache to a sane size: drop least-recently-used files past the limit. */
    private fun prune(maxFiles: Int = 400) {
        val files = dir.listFiles { f -> f.name.endsWith(".bin") } ?: return
        if (files.size <= maxFiles) return
        files.sortBy { it.lastModified() }
        for (f in files.take(files.size - maxFiles)) {
            f.delete()
            File(dir, f.name.removeSuffix(".bin") + ".type").delete()
        }
    }

    private fun sha1(s: String): String {
        val md = MessageDigest.getInstance("SHA-1")
        return md.digest(s.toByteArray()).joinToString("") { "%02x".format(it) }
    }
}
