import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/services.dart';

import '../protocol/transport.dart';

class BluetoothException implements Exception {
  BluetoothException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Un appareil déjà associé dans les réglages Bluetooth d'Android.
class BtDevice {
  const BtDevice(this.name, this.address);
  final String name;
  final String address;
}

/// Accès au Bluetooth Classic (RFCOMM) via le code Kotlin.
class BluetoothBridge {
  BluetoothBridge._() {
    // Abonnement permanent : aucun évènement natif n'est perdu.
    _eventChannel.receiveBroadcastStream().listen(
      (e) => _events.add(Map<String, dynamic>.from(e as Map)),
      onError: (Object _) {},
    );
  }

  static final BluetoothBridge instance = BluetoothBridge._();

  static const MethodChannel _method = MethodChannel('bluetalk/bt');
  static const EventChannel _eventChannel = EventChannel('bluetalk/bt/events');

  final StreamController<Map<String, dynamic>> _events =
      StreamController<Map<String, dynamic>>.broadcast();

  Stream<Map<String, dynamic>> get events => _events.stream;

  Future<T?> _call<T>(String name, [Object? arguments]) async {
    try {
      return await _method.invokeMethod<T>(name, arguments);
    } on PlatformException catch (e) {
      throw BluetoothException(e.message ?? e.code);
    }
  }

  Future<bool> ensurePermissions() async =>
      await _call<bool>('ensurePermissions') ?? false;

  Future<bool> isEnabled() async => await _call<bool>('isEnabled') ?? false;

  Future<List<BtDevice>> bondedDevices() async {
    final list = await _call<List<dynamic>>('bondedDevices') ?? const [];
    return [
      for (final d in list)
        BtDevice((d as Map)['name'] as String, d['address'] as String),
    ];
  }

  /// Attend qu'un autre appareil se connecte. Se termine à la connexion,
  /// ou avec une erreur si l'écoute est annulée ou échoue.
  Future<BluetoothTransport> listen() =>
      _establish(() => _call<void>('listen'));

  Future<void> stopListening() => _call<void>('stopListening');

  /// Se connecte à un appareil associé qui est en attente.
  Future<BluetoothTransport> connect(String address) =>
      _establish(() => _call<void>('connect', {'address': address}));

  Future<BluetoothTransport> _establish(Future<void> Function() start) async {
    final c = Completer<BluetoothTransport>();
    c.future.ignore();
    final sub = events.listen((e) {
      if (c.isCompleted) return;
      switch (e['type']) {
        case 'connected':
          // Créé ici, dans le même tour : aucune donnée reçue juste après
          // la connexion ne peut être manquée.
          c.complete(BluetoothTransport._(this, e));
        case 'error':
          c.completeError(
            BluetoothException(e['message'] as String? ?? 'Erreur Bluetooth'),
          );
        case 'listenStopped':
          c.completeError(BluetoothException('Attente annulée'));
      }
    });
    try {
      await start();
      return await c.future;
    } finally {
      await sub.cancel();
    }
  }
}

/// Le canal Bluetooth réel, utilisable par une [Session] comme le faux canal.
class BluetoothTransport implements Transport {
  BluetoothTransport._(this._bridge, Map<String, dynamic> info)
    : remoteName = info['name'] as String? ?? 'Appareil',
      remoteAddress = info['address'] as String? ?? '' {
    _sub = _bridge.events.listen(_onEvent);
  }

  final BluetoothBridge _bridge;
  final String remoteName;
  final String remoteAddress;

  final StreamController<Uint8List> _in = StreamController<Uint8List>();
  late final StreamSubscription<Map<String, dynamic>> _sub;
  Future<void> _tail = Future<void>.value();
  bool _closed = false;

  @override
  Stream<Uint8List> get incoming => _in.stream;

  void _onEvent(Map<String, dynamic> e) {
    switch (e['type']) {
      case 'data':
        if (!_in.isClosed) _in.add(e['bytes'] as Uint8List);
      case 'disconnected':
        _finish();
    }
  }

  @override
  Future<void> send(Uint8List bytes) {
    if (_closed) return Future<void>.error(StateError('Canal fermé'));
    // Les envois partent l'un après l'autre, dans l'ordre.
    final run = _tail.then(
      (_) => _bridge._call<void>('send', {'bytes': bytes}),
    );
    _tail = run.catchError((_) {});
    return run;
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _finish();
    try {
      await _bridge._call<void>('close');
    } catch (_) {}
  }

  void _finish() {
    if (_closed) return;
    _closed = true;
    _sub.cancel();
    if (!_in.isClosed) _in.close();
  }
}
