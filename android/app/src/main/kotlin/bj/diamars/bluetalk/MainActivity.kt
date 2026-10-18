package bj.diamars.bluetalk

import android.Manifest
import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothServerSocket
import android.bluetooth.BluetoothSocket
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.IOException
import java.io.OutputStream
import java.util.UUID
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {

    // Identifiant du service : les deux applications doivent utiliser le même.
    private val appUuid: UUID = UUID.fromString("5c9e1d4a-7b32-4e86-a0f1-3d6b8c2e9a17")
    private val permissionCode = 4242

    private val main = Handler(Looper.getMainLooper())
    private val writer = Executors.newSingleThreadExecutor() // écritures dans l'ordre
    private val lock = Any()

    private var events: EventChannel.EventSink? = null
    private var pendingPermission: MethodChannel.Result? = null

    private var serverSocket: BluetoothServerSocket? = null
    private var socket: BluetoothSocket? = null
    private var output: OutputStream? = null

    private val adapter: BluetoothAdapter?
        get() = (getSystemService(BLUETOOTH_SERVICE) as? BluetoothManager)?.adapter

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger

        EventChannel(messenger, "bluetalk/bt/events").setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, sink: EventChannel.EventSink?) {
                    events = sink
                }
                override fun onCancel(arguments: Any?) {
                    events = null
                }
            }
        )

        MethodChannel(messenger, "bluetalk/bt").setMethodCallHandler { call, result ->
            when (call.method) {
                "ensurePermissions" -> ensurePermissions(result)
                "isEnabled" -> result.success(adapter?.isEnabled == true)
                "bondedDevices" -> bondedDevices(result)
                "listen" -> startListening(result)
                "stopListening" -> { stopListening(); result.success(null) }
                "connect" -> connectTo(call.argument<String>("address"), result)
                "send" -> send(call.argument<ByteArray>("bytes"), result)
                "close" -> { closeConnection(); result.success(null) }
                else -> result.notImplemented()
            }
        }
    }

    // ---------- Permissions ----------

    private fun ensurePermissions(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) {
            result.success(true)
            return
        }
        val permission = Manifest.permission.BLUETOOTH_CONNECT
        if (checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED) {
            result.success(true)
            return
        }
        pendingPermission?.success(false)
        pendingPermission = result
        requestPermissions(arrayOf(permission), permissionCode)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == permissionCode) {
            val granted = grantResults.isNotEmpty() &&
                grantResults[0] == PackageManager.PERMISSION_GRANTED
            pendingPermission?.success(granted)
            pendingPermission = null
        }
    }

    // ---------- Appareils associés ----------

    @SuppressLint("MissingPermission")
    private fun bondedDevices(result: MethodChannel.Result) {
        val a = adapter
        if (a == null) {
            result.error("no_bluetooth", "Pas de Bluetooth sur cet appareil", null)
            return
        }
        try {
            val list = a.bondedDevices.map {
                mapOf("name" to (it.name ?: it.address), "address" to it.address)
            }
            result.success(list)
        } catch (e: SecurityException) {
            result.error("permission", "Permission Bluetooth manquante", null)
        }
    }

    // ---------- Attendre une connexion ----------

    @SuppressLint("MissingPermission")
    private fun startListening(result: MethodChannel.Result) {
        val a = adapter
        if (a == null || !a.isEnabled) {
            result.error("disabled", "Bluetooth désactivé", null)
            return
        }
        if (synchronized(lock) { serverSocket != null }) {
            result.error("busy", "Déjà en attente d'une connexion", null)
            return
        }
        val server: BluetoothServerSocket
        try {
            server = a.listenUsingRfcommWithServiceRecord("BlueTalk", appUuid)
        } catch (e: Exception) {
            result.error("listen", e.message ?: "Écoute impossible", null)
            return
        }
        synchronized(lock) { serverSocket = server }
        result.success(null)

        Thread {
            try {
                val s = server.accept() // bloque jusqu'à une connexion
                synchronized(lock) { if (serverSocket === server) serverSocket = null }
                try { server.close() } catch (_: IOException) {}
                attach(s)
            } catch (e: IOException) {
                val cancelled = synchronized(lock) { serverSocket !== server }
                synchronized(lock) { if (serverSocket === server) serverSocket = null }
                try { server.close() } catch (_: IOException) {}
                if (cancelled) {
                    emit(mapOf("type" to "listenStopped"))
                } else {
                    emit(mapOf("type" to "error", "message" to (e.message ?: "Écoute interrompue")))
                }
            }
        }.start()
    }

    private fun stopListening() {
        val s = synchronized(lock) {
            val x = serverSocket
            serverSocket = null
            x
        }
        try { s?.close() } catch (_: IOException) {}
    }

    // ---------- Se connecter ----------

    @SuppressLint("MissingPermission")
    private fun connectTo(address: String?, result: MethodChannel.Result) {
        val a = adapter
        if (address == null || a == null || !a.isEnabled) {
            result.error("disabled", "Bluetooth désactivé ou adresse manquante", null)
            return
        }
        if (synchronized(lock) { serverSocket != null }) {
            result.error("busy", "Annule d'abord l'attente de connexion", null)
            return
        }
        result.success(null)

        Thread {
            var pending: BluetoothSocket? = null
            try {
                val device = a.getRemoteDevice(address)
                val sock = device.createRfcommSocketToServiceRecord(appUuid)
                pending = sock
                sock.connect() // bloque jusqu'à la connexion ou l'échec
                attach(sock)
            } catch (e: Exception) {
                try { pending?.close() } catch (_: IOException) {}
                emit(mapOf("type" to "error", "message" to (e.message ?: "Connexion impossible")))
            }
        }.start()
    }

    // ---------- Connexion active ----------

    /** Prend en charge une connexion établie. Bloque (lecture) jusqu'à sa fin. */
    @SuppressLint("MissingPermission")
    private fun attach(s: BluetoothSocket) {
        val previous = synchronized(lock) {
            val old = socket
            socket = s
            output = null
            old
        }
        try { previous?.close() } catch (_: IOException) {}

        val input = s.inputStream
        synchronized(lock) { output = s.outputStream }

        val name = try { s.remoteDevice.name } catch (_: SecurityException) { null }
        emit(
            mapOf(
                "type" to "connected",
                "name" to (name ?: s.remoteDevice.address),
                "address" to s.remoteDevice.address
            )
        )

        val buffer = ByteArray(4096)
        try {
            while (true) {
                val n = input.read(buffer)
                if (n < 0) break
                emit(mapOf("type" to "data", "bytes" to buffer.copyOf(n)))
            }
        } catch (_: IOException) {
            // connexion coupée
        } finally {
            val wasCurrent = synchronized(lock) {
                if (socket === s) {
                    socket = null
                    output = null
                    true
                } else false
            }
            try { s.close() } catch (_: IOException) {}
            if (wasCurrent) emit(mapOf("type" to "disconnected"))
        }
    }

    private fun send(bytes: ByteArray?, result: MethodChannel.Result) {
        val out = synchronized(lock) { output }
        if (bytes == null || out == null) {
            result.error("not_connected", "Aucune connexion active", null)
            return
        }
        writer.execute {
            try {
                out.write(bytes)
                out.flush()
                main.post { result.success(null) }
            } catch (e: IOException) {
                main.post { result.error("write", e.message ?: "Écriture impossible", null) }
            }
        }
    }

    private fun closeConnection() {
        val s = synchronized(lock) {
            val x = socket
            socket = null
            output = null
            x
        }
        try { s?.close() } catch (_: IOException) {}
    }

    private fun emit(event: Map<String, Any?>) {
        main.post { events?.success(event) }
    }

    override fun onDestroy() {
        closeConnection()
        stopListening()
        super.onDestroy()
    }
}