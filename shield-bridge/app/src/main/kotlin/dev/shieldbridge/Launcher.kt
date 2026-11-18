package dev.shieldbridge

import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.Settings
import java.net.URISyntaxException

/** Starts other apps from the bridge: Watch Next intents, plain deep links, or app packages. */
object Launcher {

    data class Result(val ok: Boolean, val message: String, val launched: String = "")

    /** Whether Android will let a background service start another app's activity. */
    fun canLaunchFromBackground(ctx: Context): Boolean = Settings.canDrawOverlays(ctx)

    fun launchIntentUri(ctx: Context, intentUri: String): Result {
        val intent = try {
            Intent.parseUri(intentUri, Intent.URI_INTENT_SCHEME)
        } catch (e: URISyntaxException) {
            // Not intent:// syntax; most likely a bare URL.
            return launchUrl(ctx, intentUri)
        }
        // Defensive: a selector or component pointing at us makes no sense here.
        intent.selector = null
        return start(ctx, intent, intentUri)
    }

    fun launchUrl(ctx: Context, url: String): Result {
        val intent = Intent(Intent.ACTION_VIEW, Uri.parse(url))
        return start(ctx, intent, url)
    }

    fun launchPackage(ctx: Context, pkg: String): Result {
        val pm = ctx.packageManager
        val intent = pm.getLeanbackLaunchIntentForPackage(pkg) ?: pm.getLaunchIntentForPackage(pkg)
            ?: return Result(false, "no launch intent for $pkg")
        return start(ctx, intent, pkg)
    }

    private fun start(ctx: Context, intent: Intent, what: String): Result {
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        return try {
            ctx.startActivity(intent)
            val warn = if (!canLaunchFromBackground(ctx))
                " (warning: 'Display over other apps' is not granted, Android may have blocked this background launch)"
            else ""
            Result(true, "launched$warn", what)
        } catch (e: ActivityNotFoundException) {
            Result(false, "no app can handle: $what")
        } catch (e: SecurityException) {
            Result(false, "security exception: ${e.message}")
        } catch (e: Exception) {
            Result(false, "launch failed: ${e.javaClass.simpleName}: ${e.message}")
        }
    }
}
