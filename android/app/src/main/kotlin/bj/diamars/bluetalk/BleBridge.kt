package bj.diamars.bluetalk

import android.Manifest
import android.annotation.SuppressLint
import android.app.Activity
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothServerSocket
import android.bluetooth.BluetoothSocket
import android.bluetooth.le.AdvertiseCallback
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertiseSettings
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelUuid
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.IOException
import java.io.OutputStream
import java.util.UUID
import java.util.concurrent.Executors

/**
 * Découverte par balises Bluetooth basse consommation, et canal de données
 * L2CAP (sans association). La balise annonce : un identifiant de service
 * propre à BlueTalk, le numéro du canal (PSM), un court identifiant et le
 * nom d'utilisateur.
 */
class BleBridge(private val activity: Activity, messenger: BinaryMessenger) {

    companion object {
        val SERVICE_UUID: UUID = UUID.fromString("8e2c4f10-6b3a-4d57-9a1e-2f7c0b5d9e41")
        const val COMPANY_ID = 0xFFFF // identifiant réservé aux essais
        const val PERMISSION_CODE = 4343
        const val NAME_BYTES = 20
    }

    private val main = Handler(Looper.getMainLooper())
    private val writer = Executors.newSingleThreadExecutor() // écritures dans l'ordre
    private val lock = Any()

    private var events: EventChannel.EventSink? = null
    private var pendingPermission: MethodChannel.Result? = null

    private var server: BluetoothServerSocket? = null
    private var advertiseCallback: AdvertiseCallback? = null
    private var scanCallback: ScanCallback? = null
    private var socket: BluetoothSocket? = null
    private var output: OutputStream? = null
    private var writeLimit = 512

    private val adapter: BluetoothAdapter?
        get() = (activity.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager)?.adapter

    init {
        EventChannel(messenger, "bluetalk/ble/events").setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, sink: EventChannel.EventSink?) {
                    events = sink
                }
                override fun onCancel(arguments: Any?) {
                    events = null
                }
            }
        )

        MethodChannel(messenger, "bluetalk/ble").setMethodCallHandler { call, result ->
            when (call.method) {
                "ensurePermissions" -> ensurePermissions(result)
                "isEnabled" -> result.success(adapter?.isEnabled == true)
                "startAdvertising" -> startAdvertising(
                    call.argument<String>("name") ?: "",
                    call.argument<ByteArray>("id"),
                    result
                )
                "stopAdvertising" -> { stopAdvertising(); result.success(null) }
                "startScan" -> startScan(result)
                "stopScan" -> { stopScan(); result.success(null) }
                "connect" -> connectTo(call.argument<String>("address"), call.argument<Int>("psm"), result)
                "send" -> send(call.argument<ByteArray>("bytes"), result)
                "close" -> { closeConnection(); result.success(null) }
                else -> result.notImplemented()
            }
        }
    }

    // ---------- Permissions ----------

    private fun requiredPermissions(): Array<String> =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            arrayOf(
                Manifest.permission.BLUETOOTH_SCAN,
                Manifest.permission.BLUETOOTH_ADVERTISE,
                Manifest.permission.BLUETOOTH_CONNECT
            )
        } else {
            arrayOf(Manifest.permission.ACCESS_FINE_LOCATION)
        }

    private fun ensurePermissions(result: MethodChannel.Result) {
        val missing = requiredPermissions().filter {
            activity.checkSelfPermission(it) != PackageManager.PERMISSION_GRANTED
        }
        if (missing.isEmpty()) {
            result.success(true)
            return
        }
        pendingPermission?.success(false)
        pendingPermission = result
        activity.requestPermissions(missing.toTypedArray(), PERMISSION_CODE)
    }

    fun onRequestPermissionsResult(requestCode: Int, grantResults: IntArray) {
        if (requestCode != PERMISSION_CODE) return
        val granted = grantResults.isNotEmpty() &&
            grantResults.all { it == PackageManager.PERMISSION_GRANTED }
        pendingPermission?.success(granted)
        pendingPermission = null
    }

    // ---------- Annoncer sa présence ----------

    private fun truncateUtf8(s: String, max: Int): ByteArray {
        val bytes = s.toByteArray(Charsets.UTF_8)
        if (bytes.size <= max) return bytes
        var end = max
        // On ne coupe jamais au milieu d'un caractère.
        while (end > 0 && (bytes[end].toInt() and 0xC0) == 0x80) end--
        return bytes.copyOf(end)
    }

    @SuppressLint("NewApi", "MissingPermission")
    private fun startAdvertising(name: String, id: ByteArray?, result: MethodChannel.Result) {
        val a = adapter
        if (a == null || !a.isEnabled) {
            result.error("disabled", "Bluetooth désactivé", null)
            return
        }
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            result.error("unsupported", "Android 10 ou plus récent requis", null)
            return
        }
        val advertiser = a.bluetoothLeAdvertiser
        if (advertiser == null) {
            result.error(
                "unsupported",
                "Ce téléphone ne peut pas annoncer sa présence en Bluetooth basse consommation",
                null
            )
            return
        }
        stopAdvertising()

        // Le canal de données : un socket L2CAP sans association.
        val srv: BluetoothServerSocket
        try {
            srv = a.listenUsingInsecureL2capChannel()
        } catch (e: Exception) {
            result.error("listen", e.message ?: "Écoute impossible", null)
            return
        }
        val psm = srv.psm

        // Contenu de la balise : version, canal, identifiant court, nom.
        val nameBytes = truncateUtf8(name, NAME_BYTES)
        val idBytes = (id ?: ByteArray(4)).copyOf(4)
        val payload = ByteArray(7 + nameBytes.size)
        payload[0] = 1
        payload[1] = ((psm shr 8) and 0xFF).toByte()
        payload[2] = (psm and 0xFF).toByte()
        System.arraycopy(idBytes, 0, payload, 3, 4)
        System.arraycopy(nameBytes, 0, payload, 7, nameBytes.size)

        val settings = AdvertiseSettings.Builder()
            .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY)
            .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_MEDIUM)
            .setConnectable(true)
            .setTimeout(0)
            .build()
        val data = AdvertiseData.Builder()
            .setIncludeDeviceName(false)
            .setIncludeTxPowerLevel(false)
            .addServiceUuid(ParcelUuid(SERVICE_UUID))
            .build()
        val scanResponse = AdvertiseData.Builder()
            .setIncludeDeviceName(false)
            .addManufacturerData(COMPANY_ID, payload)
            .build()

        val cb = object : AdvertiseCallback() {
            override fun onStartSuccess(settingsInEffect: AdvertiseSettings) {
                main.post { result.success(psm) }
            }

            override fun onStartFailure(errorCode: Int) {
                stopAdvertising()
                main.post { result.error("advertise", "Annonce impossible (code $errorCode)", null) }
            }
        }
        synchronized(lock) {
            server = srv
            advertiseCallback = cb
        }
        try {
            advertiser.startAdvertising(settings, data, scanResponse, cb)
        } catch (e: Exception) {
            stopAdvertising()
            result.error("advertise", e.message ?: "Annonce impossible", null)
            return
        }
        startAcceptLoop(srv)
    }

    private fun startAcceptLoop(srv: BluetoothServerSocket) {
        Thread {
            while (true) {
                val s = try {
                    srv.accept() // bloque jusqu'à une connexion
                } catch (e: IOException) {
                    break // socket fermé : on arrête d'écouter
                }
                val busy = synchronized(lock) { socket != null }
                if (busy) {
                    try { s.close() } catch (_: IOException) {}
                    continue
                }
                Thread { attach(s, "server") }.start()
            }
        }.start()
    }

    @SuppressLint("MissingPermission")
    private fun stopAdvertising() {
        val (cb, srv) = synchronized(lock) {
            val c = advertiseCallback
            val s = server
            advertiseCallback = null
            server = null
            Pair(c, s)
        }
        try {
            if (cb != null) adapter?.bluetoothLeAdvertiser?.stopAdvertising(cb)
        } catch (_: Exception) {}
        try { srv?.close() } catch (_: IOException) {}
    }

    // ---------- Chercher les autres ----------

    @SuppressLint("MissingPermission")
    private fun startScan(result: MethodChannel.Result) {
        val a = adapter
        if (a == null || !a.isEnabled) {
            result.error("disabled", "Bluetooth désactivé", null)
            return
        }
        val scanner = a.bluetoothLeScanner
        if (scanner == null) {
            result.error("unsupported", "Recherche Bluetooth basse consommation indisponible", null)
            return
        }
        stopScan()
        val cb = object : ScanCallback() {
            override fun onScanResult(callbackType: Int, r: ScanResult) {
                handleResult(r)
            }

            override fun onScanFailed(errorCode: Int) {
                emit(mapOf("type" to "scanFailed", "code" to errorCode))
            }
        }
        val filters = listOf(ScanFilter.Builder().setServiceUuid(ParcelUuid(SERVICE_UUID)).build())
        val settings = ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY).build()
        synchronized(lock) { scanCallback = cb }
        try {
            scanner.startScan(filters, settings, cb)
            result.success(null)
        } catch (e: Exception) {
            result.error("scan", e.message ?: "Recherche impossible", null)
        }
    }

    private fun handleResult(r: ScanResult) {
        val data = r.scanRecord?.getManufacturerSpecificData(COMPANY_ID) ?: return
        if (data.size < 7 || data[0].toInt() != 1) return
        val psm = ((data[1].toInt() and 0xFF) shl 8) or (data[2].toInt() and 0xFF)
        val id = data.copyOfRange(3, 7).joinToString("") { "%02x".format(it) }
        val name = String(data, 7, data.size - 7, Charsets.UTF_8)
        emit(
            mapOf(
                "type" to "found",
                "address" to r.device.address,
                "name" to name,
                "id" to id,
                "psm" to psm,
                "rssi" to r.rssi
            )
        )
    }

    @SuppressLint("MissingPermission")
    private fun stopScan() {
        val cb = synchronized(lock) {
            val c = scanCallback
            scanCallback = null
            c
        }
        try {
            if (cb != null) adapter?.bluetoothLeScanner?.stopScan(cb)
        } catch (_: Exception) {}
    }

    // ---------- Se connecter ----------

    @SuppressLint("NewApi", "MissingPermission")
    private fun connectTo(address: String?, psm: Int?, result: MethodChannel.Result) {
        val a = adapter
        if (address == null || psm == null || a == null || !a.isEnabled) {
            result.error("disabled", "Bluetooth désactivé ou adresse manquante", null)
            return
        }
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            result.error("unsupported", "Android 10 ou plus récent requis", null)
            return
        }
        result.success(null)

        Thread {
            var pending: BluetoothSocket? = null
            try {
                val device = a.getRemoteDevice(address)
                val sock = device.createInsecureL2capChannel(psm)
                pending = sock
                sock.connect() // bloque jusqu'à la connexion ou l'échec
                attach(sock, "client")
            } catch (e: Exception) {
                try { pending?.close() } catch (_: IOException) {}
                emit(mapOf("type" to "error", "message" to (e.message ?: "Connexion impossible")))
            }
        }.start()
    }

    // ---------- Connexion active ----------

    /** Prend en charge une connexion établie. Bloque (lecture) jusqu'à sa fin. */
    @SuppressLint("MissingPermission")
    private fun attach(s: BluetoothSocket, role: String) {
        val previous = synchronized(lock) {
            val old = socket
            socket = s
            output = null
            old
        }
        try { previous?.close() } catch (_: IOException) {}

        val input = s.inputStream
        val mtu = s.maxTransmitPacketSize
        synchronized(lock) {
            output = s.outputStream
            writeLimit = if (mtu > 0) minOf(mtu, 4096) else 512
        }

        val name = try { s.remoteDevice.name } catch (_: SecurityException) { null }
        emit(
            mapOf(
                "type" to "connected",
                "role" to role,
                "name" to (name ?: s.remoteDevice.address),
                "address" to s.remoteDevice.address,
                "mtu" to mtu
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
        val (out, limit) = synchronized(lock) { Pair(output, writeLimit) }
        if (bytes == null || out == null) {
            result.error("not_connected", "Aucune connexion active", null)
            return
        }
        writer.execute {
            try {
                // Découpé à la taille maximale d'un paquet du canal.
                var i = 0
                while (i < bytes.size) {
                    val n = minOf(limit, bytes.size - i)
                    out.write(bytes, i, n)
                    i += n
                }
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

    fun shutdown() {
        closeConnection()
        stopScan()
        stopAdvertising()
    }
}