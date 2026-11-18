package dev.shieldbridge

import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.drawable.BitmapDrawable
import android.graphics.drawable.Drawable
import android.os.Build
import android.os.PowerManager
import fi.iki.elonen.NanoHTTPD
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.FileInputStream
import java.util.Collections
import java.util.LinkedHashMap

/**
 * The LAN HTTP API. All responses are JSON unless the path serves an image.
 *
 *   GET  /api/status                 health, permissions, addresses
 *   GET  /api/continue               Watch Next rows (query: limit, types, package, all)
 *   GET  /api/apps                   installed TV apps
 *   GET  /api/icon/{package}         PNG banner or icon for an app
 *   GET  /api/art/{id}               cached poster for a Watch Next row
 *   GET|POST /api/launch             id | intentUri | url | package
 *   POST /api/wake                   best-effort screen wake
 *
 * If an API key is configured it must arrive as X-Api-Key header or ?key=.
 */
class BridgeServer(private val ctx: Context, port: Int) : NanoHTTPD(port) {

    private val art = ArtCache(ctx)
    private val iconCache = Collections.synchronizedMap(object : LinkedHashMap<String, ByteArray>(16, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, ByteArray>?): Boolean = size > 60
    })
    private val startedAt = System.currentTimeMillis()

    companion object {
        const val VERSION = "0.1.0"
        private const val JSON = "application/json; charset=utf-8"
    }

    override fun serve(session: IHTTPSession): Response {
        return try {
            route(session)
        } catch (t: Throwable) {
            json(Response.Status.INTERNAL_ERROR, JSONObject().put("ok", false).put("error", "${t.javaClass.simpleName}: ${t.message}"))
        }
    }

    private fun route(session: IHTTPSession): Response {
        val uri = session.uri.trimEnd('/').ifEmpty { "/" }
        if (uri == "/") return text("Shield Bridge $VERSION. See /api/status")

        if (!authorized(session)) {
            return json(Response.Status.UNAUTHORIZED, JSONObject().put("ok", false).put("error", "missing or wrong api key"))
        }

        return when {
            uri == "/api/status" -> status(session)
            uri == "/api/continue" -> continueList(session)
            uri == "/api/apps" -> apps(session)
            uri.startsWith("/api/icon/") -> icon(uri.removePrefix("/api/icon/"))
            uri.startsWith("/api/art/") -> artFor(uri.removePrefix("/api/art/"))
            uri == "/api/launch" -> launch(session)
            uri == "/api/wake" -> wake()
            else -> json(Response.Status.NOT_FOUND, JSONObject().put("ok", false).put("error", "unknown path $uri"))
        }
    }

    // ---------------------------------------------------------------- helpers

    private fun authorized(session: IHTTPSession): Boolean {
        val key = Prefs.apiKey(ctx)
        if (key.isEmpty()) return true
        val header = session.headers["x-api-key"]
        val query = param(session, "key")
        return header == key || query == key
    }

    private fun param(session: IHTTPSession, name: String): String? =
        session.parameters[name]?.firstOrNull()?.takeIf { it.isNotEmpty() }

    /** Body of a POST as a JSONObject; GET or malformed body gives an empty object. */
    private fun body(session: IHTTPSession): JSONObject {
        if (session.method != Method.POST && session.method != Method.PUT) return JSONObject()
        val files = HashMap<String, String>()
        return try {
            session.parseBody(files)
            val raw = files["postData"] ?: ""
            if (raw.trim().startsWith("{")) JSONObject(raw) else JSONObject()
        } catch (e: Exception) {
            JSONObject()
        }
    }

    /** Value from JSON body first, then query string. */
    private fun arg(session: IHTTPSession, body: JSONObject, name: String): String? {
        if (body.has(name) && !body.isNull(name)) {
            val v = body.get(name).toString()
            if (v.isNotEmpty()) return v
        }
        return param(session, name)
    }

    /** http://host:port as the client addressed us, for building image URLs. */
    private fun baseUrl(session: IHTTPSession): String {
        val host = session.headers["host"] ?: "${NetUtil.localAddresses().firstOrNull() ?: "127.0.0.1"}:$listeningPort"
        return "http://$host"
    }

    private fun json(status: Response.Status, obj: JSONObject): Response =
        newFixedLengthResponse(status, JSON, obj.toString()).also { noCache(it) }

    private fun ok(obj: JSONObject): Response = json(Response.Status.OK, obj.put("ok", true))

    private fun text(s: String): Response = newFixedLengthResponse(Response.Status.OK, "text/plain", s)

    private fun noCache(r: Response) {
        r.addHeader("Cache-Control", "no-store")
        r.addHeader("Access-Control-Allow-Origin", "*")
    }

    // --------------------------------------------------------------- handlers

    private fun status(session: IHTTPSession): Response {
        val items = if (WatchNextRepository.hasPermission(ctx)) safeQuery() else emptyList()
        val perms = JSONObject()
            .put("readTvListings", WatchNextRepository.hasPermission(ctx))
            .put("displayOverOtherApps", Launcher.canLaunchFromBackground(ctx))
        return ok(
            JSONObject()
                .put("app", "shield-bridge")
                .put("version", VERSION)
                .put("device", "${Build.MANUFACTURER} ${Build.MODEL}")
                .put("android", Build.VERSION.SDK_INT)
                .put("port", listeningPort)
                .put("addresses", JSONArray(NetUtil.localAddresses()))
                .put("apiKeyRequired", Prefs.apiKey(ctx).isNotEmpty())
                .put("permissions", perms)
                .put("watchNextCount", items.size)
                .put("watchNextError", WatchNextRepository.lastError ?: "")
                .put("uptimeMs", System.currentTimeMillis() - startedAt)
        )
    }

    private fun safeQuery(): List<WatchNextItem> = try {
        WatchNextRepository.query(ctx)
    } catch (e: SecurityException) {
        WatchNextRepository.lastError = "permission denied: ${e.message}"
        emptyList()
    } catch (e: Exception) {
        WatchNextRepository.lastError = "${e.javaClass.simpleName}: ${e.message}"
        emptyList()
    }

    private fun continueList(session: IHTTPSession): Response {
        if (!WatchNextRepository.hasPermission(ctx)) {
            return json(
                Response.Status.FORBIDDEN,
                JSONObject().put("ok", false).put("error", "READ_TV_LISTINGS not granted; open the Shield Bridge app on the TV")
            )
        }
        val limit = param(session, "limit")?.toIntOrNull()?.coerceIn(1, 500) ?: 50
        val includeHidden = param(session, "all") == "1"
        val pkgFilter = param(session, "package")
        val typeFilter: Set<Int>? = param(session, "types")
            ?.split(',')
            ?.mapNotNull { TvConstants.watchNextTypeFromName(it) }
            ?.toSet()
            ?.takeIf { it.isNotEmpty() }

        val base = baseUrl(session)
        val all = safeQuery()
        val arr = JSONArray()
        var count = 0
        for (item in all) {
            if (!includeHidden && !item.browsable) continue
            if (pkgFilter != null && item.packageName != pkgFilter) continue
            if (typeFilter != null && item.watchNextType !in typeFilter) continue
            arr.put(item.toJson(base))
            count++
            if (count >= limit) break
        }
        return ok(
            JSONObject()
                .put("generatedAt", System.currentTimeMillis())
                .put("total", all.size)
                .put("items", arr)
        )
    }

    private fun apps(session: IHTTPSession): Response {
        val pm = ctx.packageManager
        val intent = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LEANBACK_LAUNCHER)
        val base = baseUrl(session)
        val list = pm.queryIntentActivities(intent, 0)
            .map { ri ->
                val pkg = ri.activityInfo.packageName
                Pair(ri.loadLabel(pm).toString(), pkg)
            }
            .distinctBy { it.second }
            .sortedBy { it.first.lowercase() }
        val arr = JSONArray()
        for ((label, pkg) in list) {
            if (pkg == ctx.packageName) continue
            arr.put(JSONObject().put("package", pkg).put("label", label).put("icon", "$base/api/icon/$pkg"))
        }
        return ok(JSONObject().put("apps", arr))
    }

    private fun icon(pkg: String): Response {
        if (pkg.isEmpty()) return json(Response.Status.NOT_FOUND, JSONObject().put("ok", false).put("error", "no package"))
        val bytes = iconCache[pkg] ?: renderIcon(pkg)?.also { iconCache[pkg] = it }
            ?: return json(Response.Status.NOT_FOUND, JSONObject().put("ok", false).put("error", "no icon for $pkg"))
        val r = newFixedLengthResponse(Response.Status.OK, "image/png", ByteArrayInputStream(bytes), bytes.size.toLong())
        r.addHeader("Cache-Control", "max-age=86400")
        return r
    }

    private fun renderIcon(pkg: String): ByteArray? {
        val pm = ctx.packageManager
        val drawable: Drawable = try {
            pm.getApplicationBanner(pkg) ?: pm.getApplicationIcon(pkg)
        } catch (e: PackageManager.NameNotFoundException) {
            return null
        }
        val bmp: Bitmap = if (drawable is BitmapDrawable && drawable.bitmap != null) {
            drawable.bitmap
        } else {
            val w = if (drawable.intrinsicWidth > 0) drawable.intrinsicWidth else 320
            val h = if (drawable.intrinsicHeight > 0) drawable.intrinsicHeight else 180
            val b = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
            val canvas = Canvas(b)
            drawable.setBounds(0, 0, w, h)
            drawable.draw(canvas)
            b
        }
        val out = ByteArrayOutputStream()
        bmp.compress(Bitmap.CompressFormat.PNG, 100, out)
        return out.toByteArray()
    }

    private fun artFor(idText: String): Response {
        val id = idText.substringBefore('?').toLongOrNull()
            ?: return json(Response.Status.BAD_REQUEST, JSONObject().put("ok", false).put("error", "bad id"))
        val item = WatchNextRepository.find(ctx, id)
            ?: return json(Response.Status.NOT_FOUND, JSONObject().put("ok", false).put("error", "no watch next row $id"))
        val uri = item.artUri
            ?: return json(Response.Status.NOT_FOUND, JSONObject().put("ok", false).put("error", "row has no art"))
        val entry = art.get(uri)
            ?: return json(Response.Status.SERVICE_UNAVAILABLE, JSONObject().put("ok", false).put("error", "could not fetch art"))
        val r = newFixedLengthResponse(Response.Status.OK, entry.mime, FileInputStream(entry.file), entry.file.length())
        r.addHeader("Cache-Control", "max-age=3600")
        return r
    }

    private fun launch(session: IHTTPSession): Response {
        val body = body(session)
        val id = arg(session, body, "id")?.toLongOrNull()
        val intentUri = arg(session, body, "intentUri")
        val url = arg(session, body, "url")
        val pkg = arg(session, body, "package")

        val result: Launcher.Result = when {
            id != null -> {
                val item = WatchNextRepository.find(ctx, id)
                when {
                    item == null -> Launcher.Result(false, "no watch next row $id (list may have changed; refresh)")
                    !item.intentUri.isNullOrEmpty() -> Launcher.launchIntentUri(ctx, item.intentUri)
                    else -> Launcher.launchPackage(ctx, item.packageName)
                }
            }
            !intentUri.isNullOrEmpty() -> Launcher.launchIntentUri(ctx, intentUri)
            !url.isNullOrEmpty() -> Launcher.launchUrl(ctx, url)
            !pkg.isNullOrEmpty() -> Launcher.launchPackage(ctx, pkg)
            else -> Launcher.Result(false, "give one of: id, intentUri, url, package")
        }
        val obj = JSONObject().put("message", result.message).put("launched", result.launched)
        return if (result.ok) ok(obj) else json(Response.Status.BAD_REQUEST, obj.put("ok", false))
    }

    private fun wake(): Response {
        var detail = ""
        try {
            val pm = ctx.getSystemService(Context.POWER_SERVICE) as PowerManager
            @Suppress("DEPRECATION")
            val wl = pm.newWakeLock(
                PowerManager.SCREEN_BRIGHT_WAKE_LOCK or PowerManager.ACQUIRE_CAUSES_WAKEUP or PowerManager.ON_AFTER_RELEASE,
                "shieldbridge:wake"
            )
            wl.acquire(5000)
            detail += "wakelock "
        } catch (e: Exception) {
            detail += "wakelock-failed(${e.message}) "
        }
        try {
            val intent = Intent(ctx, WakeActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            ctx.startActivity(intent)
            detail += "activity"
        } catch (e: Exception) {
            detail += "activity-failed(${e.message})"
        }
        return ok(JSONObject().put("message", detail.trim()))
    }
}
