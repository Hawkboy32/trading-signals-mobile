package com.blindbandit.tradingsignals.trading_signals.bubble

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Person
import android.content.Context
import android.content.Intent
import android.content.pm.ShortcutInfo
import android.content.pm.ShortcutManager
import android.graphics.drawable.Icon
import android.os.Build

private const val CHANNEL_ID = "trading_signals_bubble"
private const val SHORTCUT_ID = "trading_signals_bubble_shortcut"
private const val NOTIFICATION_ID = 4242

/**
 * Posts the bubble-eligible notification that summons the floating Trading
 * Signals bubble (BubbleActivity.kt). Pure platform APIs, no androidx.core
 * dependency needed for this.
 *
 * Requires API 30+ (Android 11) - bubbles exist from API 29 but need a
 * Person-attached, shortcut-backed, MessagingStyle notification to reliably
 * bubble on real devices rather than just showing as a normal notification;
 * a plain notification with only setBubbleMetadata() is not reliable enough
 * on its own (confirmed via the empirical spike - see
 * Mobile_App/CLAUDE_NOTES.txt's "floating chat-head bubble" entry).
 *
 * Android will only actually float this as a bubble once its conversation
 * has been marked Priority by the user (long-press the notification, or
 * Settings > Apps > Trading Signals > Notifications > Conversations) - an
 * app cannot self-promote to that status, so the first tap of this always
 * just shows a normal notification until that one-time step is done.
 */
object BubbleTrigger {
    fun show(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
            return  // silently no-op below API 30 rather than show a broken half-bubble
        }

        val nm = context.getSystemService(NotificationManager::class.java)
        if (nm.getNotificationChannel(CHANNEL_ID) == null) {
            val channel = NotificationChannel(
                CHANNEL_ID, "Floating bubble", NotificationManager.IMPORTANCE_HIGH,
            )
            nm.createNotificationChannel(channel)
        }

        val icon = Icon.createWithResource(context, context.applicationInfo.icon)
        val person = Person.Builder().setName("Trading Signals").setIcon(icon).setImportant(true).build()

        val bubbleContentIntent = Intent(context, BubbleActivity::class.java)
        val shortcut = ShortcutInfo.Builder(context, SHORTCUT_ID)
            .setShortLabel("Signals")
            .setIcon(icon)
            .setLongLived(true)
            .setPerson(person)
            .setIntent(bubbleContentIntent.setAction(Intent.ACTION_VIEW))
            .build()
        context.getSystemService(ShortcutManager::class.java)?.pushDynamicShortcut(shortcut)

        val bubblePendingIntent = PendingIntent.getActivity(
            context, 0, bubbleContentIntent,
            PendingIntent.FLAG_MUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val bubbleMetadata = Notification.BubbleMetadata.Builder(bubblePendingIntent, icon)
            .setDesiredHeight(600)
            .setAutoExpandBubble(true)
            .setSuppressNotification(false)
            .build()

        val notification = Notification.Builder(context, CHANNEL_ID)
            .setContentTitle("Trading Signals")
            .setContentText("Tap to open the floating bubble")
            .setSmallIcon(context.applicationInfo.icon)
            .setShortcutId(SHORTCUT_ID)
            .setBubbleMetadata(bubbleMetadata)
            .setCategory(Notification.CATEGORY_MESSAGE)
            .setStyle(
                Notification.MessagingStyle(person)
                    .addMessage("Tap to open your signals", System.currentTimeMillis(), person),
            )
            .build()

        nm.notify(NOTIFICATION_ID, notification)
    }
}
