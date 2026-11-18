package dev.shieldbridge

import android.content.Context
import android.content.pm.PackageManager
import android.database.Cursor
import android.net.Uri
import org.json.JSONObject
import java.util.concurrent.ConcurrentHashMap

/**
 * Column values from android.media.tv.TvContract. Spelled out here (rather
 * than referenced through the inherited Java interface constants) so the
 * contract is explicit and the file compiles without the TV support library.
 */
object TvConstants {
    val WATCH_NEXT_URI: Uri = Uri.parse("content://android.media.tv/watch_next_program")

    // program types
    const val TYPE_MOVIE = 0
    const val TYPE_TV_SERIES = 1
    const val TYPE_TV_SEASON = 2
    const val TYPE_TV_EPISODE = 3
    const val TYPE_CLIP = 4
    const val TYPE_EVENT = 5
    const val TYPE_CHANNEL = 6
    const val TYPE_TRACK = 7
    const val TYPE_ALBUM = 8
    const val TYPE_ARTIST = 9
    const val TYPE_PLAYLIST = 10
    const val TYPE_STATION = 11
    const val TYPE_GAME = 12

    // watch next types
    const val WATCH_NEXT_TYPE_CONTINUE = 0
    const val WATCH_NEXT_TYPE_NEXT = 1
    const val WATCH_NEXT_TYPE_NEW = 2
    const val WATCH_NEXT_TYPE_WATCHLIST = 3

    // poster art aspect ratios
    const val ASPECT_RATIO_16_9 = 0
    const val ASPECT_RATIO_3_2 = 1
    const val ASPECT_RATIO_4_3 = 2
    const val ASPECT_RATIO_1_1 = 3
    const val ASPECT_RATIO_2_3 = 4
    const val ASPECT_RATIO_MOVIE_POSTER = 5

    const val PERMISSION_READ_TV_LISTINGS = "android.permission.READ_TV_LISTINGS"

    fun typeName(t: Int): String = when (t) {
        TYPE_MOVIE -> "MOVIE"
        TYPE_TV_SERIES -> "TV_SERIES"
        TYPE_TV_SEASON -> "TV_SEASON"
        TYPE_TV_EPISODE -> "TV_EPISODE"
        TYPE_CLIP -> "CLIP"
        TYPE_EVENT -> "EVENT"
        TYPE_CHANNEL -> "CHANNEL"
        TYPE_TRACK -> "TRACK"
        TYPE_ALBUM -> "ALBUM"
        TYPE_ARTIST -> "ARTIST"
        TYPE_PLAYLIST -> "PLAYLIST"
        TYPE_STATION -> "STATION"
        TYPE_GAME -> "GAME"
        else -> "UNKNOWN"
    }

    fun watchNextTypeName(t: Int): String = when (t) {
        WATCH_NEXT_TYPE_CONTINUE -> "CONTINUE"
        WATCH_NEXT_TYPE_NEXT -> "NEXT"
        WATCH_NEXT_TYPE_NEW -> "NEW"
        WATCH_NEXT_TYPE_WATCHLIST -> "WATCHLIST"
        else -> "UNKNOWN"
    }

    fun watchNextTypeFromName(name: String): Int? = when (name.trim().uppercase()) {
        "CONTINUE" -> WATCH_NEXT_TYPE_CONTINUE
        "NEXT" -> WATCH_NEXT_TYPE_NEXT
        "NEW" -> WATCH_NEXT_TYPE_NEW
        "WATCHLIST" -> WATCH_NEXT_TYPE_WATCHLIST
        else -> null
    }

    /** Width/height hint for UIs that want to reserve space before the image loads. */
    fun aspectDims(aspect: Int, base: Int = 300): Pair<Int, Int> = when (aspect) {
        ASPECT_RATIO_3_2 -> Pair(base, base * 2 / 3)
        ASPECT_RATIO_4_3 -> Pair(base, base * 3 / 4)
        ASPECT_RATIO_1_1 -> Pair(base, base)
        ASPECT_RATIO_2_3 -> Pair(base * 2 / 3, base)
        ASPECT_RATIO_MOVIE_POSTER -> Pair(base * 1000 / 1441, base)
        else -> Pair(base, base * 9 / 16)
    }
}

data class WatchNextItem(
    val id: Long,
    val packageName: String,
    val appLabel: String,
    val title: String?,
    val episodeTitle: String?,
    val season: String?,
    val episode: String?,
    val type: Int,
    val watchNextType: Int,
    val positionMs: Long,
    val durationMs: Long,
    val lastEngagementMs: Long,
    val posterUri: String?,
    val thumbnailUri: String?,
    val aspect: Int,
    val intentUri: String?,
    val contentId: String?,
    val description: String?,
    val browsable: Boolean,
) {
    val progressPercent: Int
        get() = if (durationMs > 0 && positionMs >= 0) ((positionMs * 100) / durationMs).toInt().coerceIn(0, 100) else 0

    /** Best image for a tile: poster first, thumbnail as fallback. */
    val artUri: String? get() = posterUri ?: thumbnailUri

    fun toJson(artBaseUrl: String): JSONObject {
        val (w, h) = TvConstants.aspectDims(aspect)
        return JSONObject()
            .put("id", id)
            .put("package", packageName)
            .put("app", appLabel)
            .put("title", title ?: "")
            .put("episodeTitle", episodeTitle ?: "")
            .put("season", season ?: "")
            .put("episode", episode ?: "")
            .put("type", TvConstants.typeName(type))
            .put("watchNextType", TvConstants.watchNextTypeName(watchNextType))
            .put("positionMs", positionMs)
            .put("durationMs", durationMs)
            .put("progress", progressPercent)
            .put("lastEngagementMs", lastEngagementMs)
            .put("art", if (artUri != null) "$artBaseUrl/api/art/$id" else "")
            .put("artSource", artUri ?: "")
            .put("artWidth", w)
            .put("artHeight", h)
            .put("intentUri", intentUri ?: "")
            .put("contentId", contentId ?: "")
            .put("description", description ?: "")
            .put("browsable", browsable)
    }
}

/**
 * Reads the system-wide Watch Next ("Continue watching") table.
 *
 * Access rule, verified in the TvProvider source: a caller without the
 * privileged ACCESS_ALL_EPG_DATA permission gets rows for its own package only,
 * unless it holds READ_TV_LISTINGS, in which case it also gets every row whose
 * searchable flag is set (the default for all apps). Selection strings are not
 * allowed for such callers, so filtering happens here in memory.
 */
object WatchNextRepository {

    private val fullProjection = arrayOf(
        "_id", "package_name", "title", "episode_title",
        "season_display_number", "episode_display_number", "type", "watch_next_type",
        "last_playback_position_millis", "duration_millis", "last_engagement_time_utc_millis",
        "poster_art_uri", "thumbnail_uri", "poster_art_aspect_ratio", "intent_uri",
        "content_id", "short_description", "browsable",
    )

    /** Last successful query, keyed by row id, so /api/art and /api/launch can resolve ids. */
    val cache = ConcurrentHashMap<Long, WatchNextItem>()

    @Volatile var lastError: String? = null

    fun hasPermission(ctx: Context): Boolean =
        ctx.checkSelfPermission(TvConstants.PERMISSION_READ_TV_LISTINGS) == PackageManager.PERMISSION_GRANTED

    fun query(ctx: Context): List<WatchNextItem> {
        val pm = ctx.packageManager
        val labels = HashMap<String, String>()
        val out = ArrayList<WatchNextItem>()
        val cursor: Cursor? = try {
            ctx.contentResolver.query(TvConstants.WATCH_NEXT_URI, fullProjection, null, null, null)
        } catch (e: IllegalArgumentException) {
            // A column name the provider does not know about; fall back to the core set.
            ctx.contentResolver.query(TvConstants.WATCH_NEXT_URI, null, null, null, null)
        }
        if (cursor == null) {
            lastError = "provider returned no cursor"
            return out
        }
        cursor.use { c ->
            val col = Columns(c)
            while (c.moveToNext()) {
                val pkg = col.str(c, "package_name") ?: continue
                val label = labels.getOrPut(pkg) { appLabel(pm, pkg) }
                out.add(
                    WatchNextItem(
                        id = col.lng(c, "_id"),
                        packageName = pkg,
                        appLabel = label,
                        title = col.str(c, "title"),
                        episodeTitle = col.str(c, "episode_title"),
                        season = col.str(c, "season_display_number"),
                        episode = col.str(c, "episode_display_number"),
                        type = col.int(c, "type", -1),
                        watchNextType = col.int(c, "watch_next_type", -1),
                        positionMs = col.lng(c, "last_playback_position_millis", -1),
                        durationMs = col.lng(c, "duration_millis", -1),
                        lastEngagementMs = col.lng(c, "last_engagement_time_utc_millis", 0),
                        posterUri = col.str(c, "poster_art_uri"),
                        thumbnailUri = col.str(c, "thumbnail_uri"),
                        aspect = col.int(c, "poster_art_aspect_ratio", TvConstants.ASPECT_RATIO_16_9),
                        intentUri = col.str(c, "intent_uri"),
                        contentId = col.str(c, "content_id"),
                        description = col.str(c, "short_description"),
                        browsable = col.int(c, "browsable", 1) != 0,
                    )
                )
            }
        }
        lastError = null
        // newest engagement first
        out.sortByDescending { it.lastEngagementMs }
        cache.clear()
        for (item in out) cache[item.id] = item
        return out
    }

    fun find(ctx: Context, id: Long): WatchNextItem? {
        cache[id]?.let { return it }
        query(ctx)
        return cache[id]
    }

    private fun appLabel(pm: PackageManager, pkg: String): String = try {
        pm.getApplicationLabel(pm.getApplicationInfo(pkg, 0)).toString()
    } catch (e: PackageManager.NameNotFoundException) {
        pkg
    }

    /** Column index helper tolerant of missing columns. */
    private class Columns(c: Cursor) {
        private val idx = HashMap<String, Int>()

        init {
            for (name in c.columnNames) idx[name] = c.getColumnIndex(name)
        }

        fun str(c: Cursor, name: String): String? {
            val i = idx[name] ?: return null
            return if (i < 0 || c.isNull(i)) null else c.getString(i)
        }

        fun lng(c: Cursor, name: String, def: Long = 0): Long {
            val i = idx[name] ?: return def
            return if (i < 0 || c.isNull(i)) def else c.getLong(i)
        }

        fun int(c: Cursor, name: String, def: Int = 0): Int {
            val i = idx[name] ?: return def
            return if (i < 0 || c.isNull(i)) def else c.getInt(i)
        }
    }
}
