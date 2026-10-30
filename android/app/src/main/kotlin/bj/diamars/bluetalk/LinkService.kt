package bj.diamars.bluetalk

import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder

/**
 * Service de premier plan : tant qu'il tourne (avec sa notification), Android
 * ne ferme pas l'application quand on la quitte. Les connexions Bluetooth et
 * la recherche de contacts continuent donc en arrière-plan.
 */
class LinkService : Service() {

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        Notifier.ensureChannels(this)
        val text = intent?.getStringExtra("text") ?: "BlueTalk reste connecté"
        val notification = Notifier.linkNotification(this, text)
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(
                    Notifier.ID_LINK,
                    notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE
                )
            } else {
                startForeground(Notifier.ID_LINK, notification)
            }
        } catch (e: Exception) {
            // Android refuse (permission manquante, démarrage en arrière-plan) :
            // l'application fonctionne alors comme avant, sans service.
            stopSelf()
        }
        // Pas de redémarrage automatique : sans l'application, il n'y a rien à garder.
        return START_NOT_STICKY
    }

    /** L'application a été retirée de la liste des applications récentes. */
    override fun onTaskRemoved(rootIntent: Intent?) {
        stopSelf()
        super.onTaskRemoved(rootIntent)
    }
}
