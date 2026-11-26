package dev.shieldbridge

import android.service.notification.NotificationListenerService

/**
 * Never reads a notification. Android only lets an app see other apps' media
 * sessions (what is playing, its title and artwork) while that app has an
 * enabled notification listener, so this empty one is what /api/nowplaying
 * needs. Enable it under Settings > Apps > Special app access > Notification
 * access, or with:
 *   adb shell cmd notification allow_listener dev.shieldbridge/dev.shieldbridge.MediaListener
 */
class MediaListener : NotificationListenerService()
