package dev.shieldbridge

import android.content.ComponentName
import android.content.Context
import android.graphics.Bitmap
import android.media.MediaMetadata
import android.media.session.MediaController
import android.media.session.MediaSessionManager
import android.media.session.PlaybackState
import android.os.Build
import android.os.SystemClock
import android.provider.Settings
import java.io.ByteArrayOutputStream

/**
 * What is playing right now, read from Android's media sessions. Streaming
 * apps publish their title, artwork and play state there (it feeds the
 * system's own now-playing card and the Assistant), so this works however the
 * show was started: from Control4, the Shield remote or inside the app.
 */
object NowPlaying {

    class Info(
        val pkg: String,
        val app: String,
        val state: String,
        val title: String?,
        val subtitle: String?,
        val artist: String?,
        val album: String?,
        val durationMs: Long,
        val positionMs: Long,
        val hasArt: Boolean,
        /** Changes when the title or the picture does; used to bust image caches. */
        val artKey: String,
    )

    private val LIVE_STATES = setOf(
        PlaybackState.STATE_PLAYING, PlaybackState.STATE_PAUSED, PlaybackState.STATE_BUFFERING,
        PlaybackState.STATE_CONNECTING, PlaybackState.STATE_FAST_FORWARDING, PlaybackState.STATE_REWINDING,
        PlaybackState.STATE_SKIPPING_TO_NEXT, PlaybackState.STATE_SKIPPING_TO_PREVIOUS,
        PlaybackState.STATE_SKIPPING_TO_QUEUE_ITEM,
    )

    fun listener(ctx: Context) = ComponentName(ctx, MediaListener::class.java)

    /** True once the notification listener is enabled (see MediaListener). */
    fun hasAccess(ctx: Context): Boolean {
        val enabled = Settings.Secure.getString(ctx.contentResolver, "enabled_notification_listeners") ?: return false
        val me = listener(ctx)
        return enabled.split(':').any { ComponentName.unflattenFromString(it) == me }
    }

    /** The session worth showing: one that is playing, else one paused or buffering. */
    fun current(ctx: Context): MediaController? {
        val msm = ctx.getSystemService(Context.MEDIA_SESSION_SERVICE) as MediaSessionManager
        val sessions = msm.getActiveSessions(listener(ctx)).filter { it.packageName != ctx.packageName }
        fun state(c: MediaController) = c.playbackState?.state ?: PlaybackState.STATE_NONE
        return sessions.firstOrNull { state(it) == PlaybackState.STATE_PLAYING }
            ?: sessions.firstOrNull { state(it) in LIVE_STATES }
    }

    fun read(ctx: Context): Info? {
        val c = current(ctx) ?: return null
        val md = c.metadata
        val ps = c.playbackState
        val bmp = bitmap(md)
        val uri = artUri(md)
        val title = md.text(MediaMetadata.METADATA_KEY_DISPLAY_TITLE) ?: md.text(MediaMetadata.METADATA_KEY_TITLE)
        val subtitle = md.text(MediaMetadata.METADATA_KEY_DISPLAY_SUBTITLE)
        val duration = md?.getLong(MediaMetadata.METADATA_KEY_DURATION)?.takeIf { it > 0 } ?: 0L
        var pos = position(ps)
        if (duration > 0 && pos > duration) pos = duration
        val picture = when {
            bmp != null -> bitmapKey(bmp)
            uri != null -> uri
            else -> ""
        }
        return Info(
            pkg = c.packageName,
            app = label(ctx, c.packageName),
            state = stateName(ps?.state),
            title = title,
            subtitle = subtitle,
            artist = md.text(MediaMetadata.METADATA_KEY_ARTIST),
            album = md.text(MediaMetadata.METADATA_KEY_ALBUM),
            durationMs = duration,
            positionMs = pos,
            hasArt = bmp != null || uri != null,
            artKey = Integer.toHexString("${c.packageName}|$title|$subtitle|$picture".hashCode()),
        )
    }

    /** The current artwork: JPEG bytes when the app sent a picture, else its art URI. */
    fun art(ctx: Context): Pair<ByteArray?, String?> {
        val c = current(ctx) ?: return Pair(null, null)
        val md = c.metadata
        val bmp = bitmap(md)
        if (bmp != null) return Pair(jpeg(bmp), null)
        return Pair(null, artUri(md))
    }

    private fun MediaMetadata?.text(key: String): String? =
        this?.getText(key)?.toString()?.trim()?.takeIf { it.isNotEmpty() }

    private fun bitmap(md: MediaMetadata?): Bitmap? {
        if (md == null) return null
        return md.getBitmap(MediaMetadata.METADATA_KEY_ART)
            ?: md.getBitmap(MediaMetadata.METADATA_KEY_ALBUM_ART)
            ?: md.getBitmap(MediaMetadata.METADATA_KEY_DISPLAY_ICON)
    }

    private fun artUri(md: MediaMetadata?): String? {
        if (md == null) return null
        for (k in arrayOf(
            MediaMetadata.METADATA_KEY_ART_URI,
            MediaMetadata.METADATA_KEY_ALBUM_ART_URI,
            MediaMetadata.METADATA_KEY_DISPLAY_ICON_URI,
        )) {
            val v = md.getString(k)
            if (!v.isNullOrBlank()) return v
        }
        return null
    }

    private fun position(ps: PlaybackState?): Long {
        if (ps == null || ps.position < 0) return 0
        if (ps.state != PlaybackState.STATE_PLAYING) return ps.position
        val elapsed = SystemClock.elapsedRealtime() - ps.lastPositionUpdateTime
        return ps.position + (elapsed * ps.playbackSpeed).toLong()
    }

    private fun stateName(s: Int?): String = when (s) {
        PlaybackState.STATE_PLAYING -> "playing"
        PlaybackState.STATE_PAUSED -> "paused"
        PlaybackState.STATE_BUFFERING, PlaybackState.STATE_CONNECTING -> "buffering"
        PlaybackState.STATE_FAST_FORWARDING, PlaybackState.STATE_REWINDING,
        PlaybackState.STATE_SKIPPING_TO_NEXT, PlaybackState.STATE_SKIPPING_TO_PREVIOUS,
        PlaybackState.STATE_SKIPPING_TO_QUEUE_ITEM -> "seeking"
        PlaybackState.STATE_STOPPED -> "stopped"
        else -> "other"
    }

    private fun label(ctx: Context, pkg: String): String = try {
        val pm = ctx.packageManager
        pm.getApplicationLabel(pm.getApplicationInfo(pkg, 0)).toString()
    } catch (e: Exception) {
        pkg
    }

    /**
     * A fingerprint of the picture. Each read of another app's session hands
     * back a fresh Bitmap copy, so object identity cannot tell whether the
     * artwork changed; a few sampled pixels can.
     */
    private fun bitmapKey(b: Bitmap): String = try {
        var h = 17L
        h = h * 31 + b.width
        h = h * 31 + b.height
        for (i in 1..4) for (j in 1..4) h = h * 31 + b.getPixel(b.width * i / 5, b.height * j / 5)
        java.lang.Long.toHexString(h)
    } catch (e: Exception) {
        "${b.width}x${b.height}"
    }

    private fun jpeg(src: Bitmap): ByteArray {
        var b = src
        if (Build.VERSION.SDK_INT >= 26 && b.config == Bitmap.Config.HARDWARE) {
            b = b.copy(Bitmap.Config.ARGB_8888, false) ?: b
        }
        val longest = maxOf(b.width, b.height)
        if (longest > 720) {
            val scale = 720f / longest
            b = Bitmap.createScaledBitmap(b, maxOf(1, (b.width * scale).toInt()), maxOf(1, (b.height * scale).toInt()), true)
        }
        val out = ByteArrayOutputStream()
        b.compress(Bitmap.CompressFormat.JPEG, 88, out)
        return out.toByteArray()
    }
}
