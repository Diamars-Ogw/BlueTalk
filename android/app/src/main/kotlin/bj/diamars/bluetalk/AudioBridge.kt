package bj.diamars.bluetalk

import android.Manifest
import android.app.Activity
import android.content.pm.PackageManager
import android.media.MediaPlayer
import android.media.MediaRecorder
import android.os.Build
import android.os.SystemClock
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * Messages vocaux : enregistrement (MediaRecorder, AAC mono, léger pour le
 * Bluetooth : environ 240 Ko par minute) et lecture (MediaPlayer).
 * Un seul enregistrement et une seule lecture à la fois.
 */
class AudioBridge(private val activity: Activity, messenger: BinaryMessenger) {

    companion object {
        const val PERMISSION_CODE = 4345
        const val MAX_RECORD_MS = 5 * 60 * 1000
    }

    private var recorder: MediaRecorder? = null
    private var recordFile: File? = null
    private var recordStartedAt = 0L

    private var player: MediaPlayer? = null
    private var playerDone = false

    private var pendingPermission: MethodChannel.Result? = null

    init {
        MethodChannel(messenger, "bluetalk/audio").setMethodCallHandler { call, result ->
            when (call.method) {
                "ensurePermission" -> ensurePermission(result)
                "startRecording" -> startRecording(result)
                "stopRecording" -> stopRecording(result)
                "cancelRecording" -> { cancelRecording(); result.success(null) }
                "play" -> play(
                    call.argument<String>("path"),
                    call.argument<Int>("from") ?: 0,
                    result
                )
                "pause" -> {
                    try { player?.takeIf { it.isPlaying }?.pause() } catch (_: Exception) {}
                    result.success(null)
                }
                "resume" -> {
                    try { player?.takeIf { !playerDone }?.start() } catch (_: Exception) {}
                    result.success(null)
                }
                "stopPlayback" -> { releasePlayer(); result.success(null) }
                "seek" -> {
                    try { player?.seekTo(call.argument<Int>("ms") ?: 0) } catch (_: Exception) {}
                    result.success(null)
                }
                "state" -> result.success(playerState())
                else -> result.notImplemented()
            }
        }
    }

    // ---------- Permission du micro ----------

    private fun hasPermission(): Boolean =
        activity.checkSelfPermission(Manifest.permission.RECORD_AUDIO) ==
            PackageManager.PERMISSION_GRANTED

    private fun ensurePermission(result: MethodChannel.Result) {
        if (hasPermission()) {
            result.success(true)
            return
        }
        pendingPermission?.success(false)
        pendingPermission = result
        activity.requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO), PERMISSION_CODE)
    }

    fun onRequestPermissionsResult(requestCode: Int, grantResults: IntArray) {
        if (requestCode != PERMISSION_CODE) return
        pendingPermission?.success(
            grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED
        )
        pendingPermission = null
    }

    // ---------- Enregistrer ----------

    @Suppress("DEPRECATION")
    private fun startRecording(result: MethodChannel.Result) {
        if (!hasPermission()) {
            result.error("permission", "Autorisation du micro refusée", null)
            return
        }
        cancelRecording()
        releasePlayer() // on ne parle pas par-dessus une lecture
        val file = File(activity.cacheDir, "vocal_${System.currentTimeMillis()}.m4a")
        try {
            val r = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                MediaRecorder(activity)
            } else {
                MediaRecorder()
            }
            r.setAudioSource(MediaRecorder.AudioSource.MIC)
            r.setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
            r.setAudioEncoder(MediaRecorder.AudioEncoder.AAC)
            r.setAudioChannels(1)
            r.setAudioSamplingRate(22050)
            r.setAudioEncodingBitRate(32000)
            r.setMaxDuration(MAX_RECORD_MS)
            r.setOutputFile(file.absolutePath)
            r.prepare()
            r.start()
            recorder = r
            recordFile = file
            recordStartedAt = SystemClock.elapsedRealtime()
            result.success(file.absolutePath)
        } catch (e: Exception) {
            recorder = null
            recordFile = null
            try { file.delete() } catch (_: Exception) {}
            result.error("record", e.message ?: "Enregistrement impossible", null)
        }
    }

    private fun stopRecording(result: MethodChannel.Result) {
        val r = recorder
        val file = recordFile
        recorder = null
        recordFile = null
        if (r == null || file == null) {
            result.success(null)
            return
        }
        val duration = SystemClock.elapsedRealtime() - recordStartedAt
        try {
            r.stop()
        } catch (e: RuntimeException) {
            // Arrêt trop rapide : aucun son enregistré.
            try { r.release() } catch (_: Exception) {}
            try { file.delete() } catch (_: Exception) {}
            result.success(null)
            return
        }
        try { r.release() } catch (_: Exception) {}
        result.success(
            mapOf("path" to file.absolutePath, "durationMs" to duration.toInt())
        )
    }

    private fun cancelRecording() {
        val r = recorder
        val file = recordFile
        recorder = null
        recordFile = null
        if (r != null) {
            try { r.stop() } catch (_: Exception) {}
            try { r.release() } catch (_: Exception) {}
        }
        try { file?.delete() } catch (_: Exception) {}
    }

    // ---------- Écouter ----------

    private fun play(path: String?, from: Int, result: MethodChannel.Result) {
        if (path == null || !File(path).exists()) {
            result.error("missing", "Fichier audio introuvable", null)
            return
        }
        releasePlayer()
        try {
            val p = MediaPlayer()
            p.setDataSource(path)
            p.prepare()
            if (from > 0) p.seekTo(from)
            p.setOnCompletionListener { playerDone = true }
            playerDone = false
            p.start()
            player = p
            result.success(p.duration)
        } catch (e: Exception) {
            releasePlayer()
            result.error("play", e.message ?: "Lecture impossible", null)
        }
    }

    private fun playerState(): Map<String, Any> {
        val p = player ?: return mapOf(
            "playing" to false, "position" to 0, "duration" to 0, "done" to false
        )
        return try {
            mapOf(
                "playing" to (p.isPlaying),
                "position" to p.currentPosition,
                "duration" to p.duration,
                "done" to playerDone
            )
        } catch (e: Exception) {
            mapOf("playing" to false, "position" to 0, "duration" to 0, "done" to true)
        }
    }

    private fun releasePlayer() {
        val p = player ?: return
        player = null
        playerDone = false
        try { p.stop() } catch (_: Exception) {}
        try { p.release() } catch (_: Exception) {}
    }

    fun shutdown() {
        cancelRecording()
        releasePlayer()
    }
}
