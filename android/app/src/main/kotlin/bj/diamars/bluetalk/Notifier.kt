package bj.diamars.bluetalk

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent

/** Les deux sortes de notifications : la présence permanente, et les messages. */
object Notifier {
    const val CHANNEL_LINK = "bluetalk_link"
    const val CHANNEL_MESSAGES = "bluetalk_messages"
    const val ID_LINK = 1001

    fun ensureChannels(ctx: Context) {
        val nm = ctx.getSystemService(NotificationManager::class.java) ?: return
        if (nm.getNotificationChannel(CHANNEL_LINK) == null) {
            nm.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_LINK,
                    "Connexion BlueTalk",
                    NotificationManager.IMPORTANCE_LOW
                ).apply { description = "Reste affichée pendant que BlueTalk garde les connexions ouvertes" }
            )
        }
        if (nm.getNotificationChannel(CHANNEL_MESSAGES) == null) {
            nm.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_MESSAGES,
                    "Messages",
                    NotificationManager.IMPORTANCE_HIGH
                ).apply { description = "Nouveaux messages reçus" }
            )
        }
    }

    private fun openAppIntent(ctx: Context): PendingIntent {
        val launch = ctx.packageManager.getLaunchIntentForPackage(ctx.packageName) ?: Intent()
        launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        return PendingIntent.getActivity(
            ctx,
            0,
            launch,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
    }

    fun linkNotification(ctx: Context, text: String): Notification =
        Notification.Builder(ctx, CHANNEL_LINK)
            .setSmallIcon(android.R.drawable.stat_sys_data_bluetooth)
            .setContentTitle("BlueTalk")
            .setContentText(text)
            .setOngoing(true)
            .setContentIntent(openAppIntent(ctx))
            .build()

    fun message(ctx: Context, id: Int, title: String, body: String) {
        val nm = ctx.getSystemService(NotificationManager::class.java) ?: return
        val n = Notification.Builder(ctx, CHANNEL_MESSAGES)
            .setSmallIcon(android.R.drawable.stat_notify_chat)
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(Notification.BigTextStyle().bigText(body))
            .setAutoCancel(true)
            .setContentIntent(openAppIntent(ctx))
            .build()
        nm.notify(id, n)
    }
}
