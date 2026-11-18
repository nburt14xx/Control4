package dev.shieldbridge

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.IBinder
import android.util.Log
import fi.iki.elonen.NanoHTTPD

/** Foreground service that owns the HTTP server for as long as the box is up. */
class BridgeService : Service() {

    companion object {
        private const val TAG = "ShieldBridge"
        private const val CHANNEL = "bridge"
        private const val NOTIFICATION_ID = 1
        const val ACTION_STOP = "dev.shieldbridge.STOP"

        @Volatile var running: Boolean = false
        @Volatile var lastError: String? = null
        @Volatile var port: Int = Prefs.DEFAULT_PORT

        fun start(ctx: Context) {
            ctx.startForegroundService(Intent(ctx, BridgeService::class.java))
        }

        fun stop(ctx: Context) {
            ctx.startService(Intent(ctx, BridgeService::class.java).setAction(ACTION_STOP))
        }
    }

    private var server: BridgeServer? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        startForeground(NOTIFICATION_ID, buildNotification("Starting"))
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopServer()
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
            return START_NOT_STICKY
        }
        startServer()
        return START_STICKY
    }

    override fun onDestroy() {
        stopServer()
        super.onDestroy()
    }

    private fun startServer() {
        if (server != null) return
        port = Prefs.port(this)
        try {
            val s = BridgeServer(applicationContext, port)
            s.start(NanoHTTPD.SOCKET_READ_TIMEOUT, false)
            server = s
            running = true
            lastError = null
            val addr = NetUtil.localAddresses().firstOrNull() ?: "?"
            updateNotification("Listening on http://$addr:$port")
            Log.i(TAG, "server started on $port")
        } catch (e: Exception) {
            running = false
            lastError = "${e.javaClass.simpleName}: ${e.message}"
            updateNotification("Failed: $lastError")
            Log.e(TAG, "server failed to start", e)
        }
    }

    private fun stopServer() {
        try {
            server?.stop()
        } catch (e: Exception) {
            Log.w(TAG, "stop failed", e)
        }
        server = null
        running = false
    }

    private fun buildNotification(text: String): Notification {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (nm.getNotificationChannel(CHANNEL) == null) {
            nm.createNotificationChannel(
                NotificationChannel(CHANNEL, "Shield Bridge", NotificationManager.IMPORTANCE_LOW).apply {
                    description = "Keeps the Control4 bridge server running"
                }
            )
        }
        val open = PendingIntent.getActivity(
            this, 0, Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        return Notification.Builder(this, CHANNEL)
            .setContentTitle("Shield Bridge")
            .setContentText(text)
            .setSmallIcon(android.R.drawable.ic_media_play)
            .setContentIntent(open)
            .setOngoing(true)
            .build()
    }

    private fun updateNotification(text: String) {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        nm.notify(NOTIFICATION_ID, buildNotification(text))
    }
}
