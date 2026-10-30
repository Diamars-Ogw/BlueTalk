import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/services.dart';

import '../protocol/transport.dart';

class BleException implements Exception {
  BleException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Un utilisateur de BlueTalk détecté à proximité.
class NearbyUser {
  const NearbyUser({
    required this.address,
    required this.name,
    required this.idHex,
    required this.psm,
    required this.rssi,
  });

  factory NearbyUser.fromEvent(Map<String, dynamic> e) => NearbyUser(
    address: e['address'] as String,
    name: e['name'] as String,
    idHex: e['id'] as String,
    psm: e['psm'] as int,
    rssi: e['rssi'] as int,
  );

  final String
  address; // adresse temporaire, valable pour se connecter maintenant
  final String name;
  final String idHex; // début de l'identifiant d'installation
  final int psm; // numéro du canal de données
  final int rssi; // force du signal (plus proche de 0 = plus près)
}

/// Découverte par balises et canaux L2CAP, via le code Kotlin. Plusieurs
/// connexions peuvent être ouvertes en même temps : chacune a un numéro
/// (cid), présent dans chaque évènement venant du code natif.
class BleBridge {
  BleBridge._() {
    _eventChannel.receiveBroadcastStream().listen(
      _onEvent,
      onError: (Object _) {},
    );
  }

  static final BleBridge instance = BleBridge._();

  static const MethodChannel _method = MethodChannel('bluetalk/ble');
  static const EventChannel _eventChannel = EventChannel('bluetalk/ble/events');

  final StreamController<Map<String, dynamic>> _events =
      StreamController<Map<String, dynamic>>.broadcast();
  final StreamController<BleTransport> _accepted =
      StreamController<BleTransport>.broadcast();

  int _reqCounter = 0;
  final Set<int> _waiting = {}; // demandes de connexion encore attendues

  Stream<Map<String, dynamic>> get events => _events.stream;

  /// Connexions entrantes : quelqu'un s'est connecté à nous.
  Stream<BleTransport> get accepted => _accepted.stream;

  /// Les utilisateurs trouvés pendant une recherche.
  Stream<NearbyUser> get found => _events.stream
      .where((e) => e['type'] == 'found')
      .map(NearbyUser.fromEvent);

  void _onEvent(dynamic raw) {
    final e = Map<String, dynamic>.from(raw as Map);
    if (e['type'] == 'connected') {
      if (e['role'] == 'server') {
        if (_accepted.hasListener) {
          // Créé tout de suite : aucune donnée reçue juste après n'est perdue.
          _accepted.add(BleTransport._(this, e));
        } else {
          unawaited(
            _call<void>('close', {'cid': e['cid']}).catchError((_) => null),
          );
        }
      } else if (!_waiting.contains(e['req'])) {
        // Une connexion que plus personne n'attend (délai dépassé) : on la ferme.
        unawaited(
          _call<void>('close', {'cid': e['cid']}).catchError((_) => null),
        );
      }
    }
    _events.add(e);
  }

  Future<T?> _call<T>(String name, [Object? arguments]) async {
    try {
      return await _method.invokeMethod<T>(name, arguments);
    } on PlatformException catch (e) {
      throw BleException(e.message ?? e.code);
    }
  }

  Future<bool> ensurePermissions() async =>
      await _call<bool>('ensurePermissions') ?? false;

  Future<bool> isEnabled() async => await _call<bool>('isEnabled') ?? false;

  /// Commence à annoncer sa présence. Renvoie le numéro du canal de données.
  Future<int> startAdvertising({
    required String name,
    required Uint8List id,
  }) async =>
      await _call<int>('startAdvertising', {'name': name, 'id': id}) ?? 0;

  Future<void> stopAdvertising() => _call<void>('stopAdvertising');

  Future<void> startScan() => _call<void>('startScan');

  Future<void> stopScan() => _call<void>('stopScan');

  /// Ouvre une connexion. Plusieurs peuvent être en cours : chaque demande
  /// a un numéro, repris par la réponse du code natif.
  Future<BleTransport> connect(String address, int psm) async {
    final req = ++_reqCounter;
    _waiting.add(req);
    final c = Completer<BleTransport>();
    c.future.ignore();
    final sub = events.listen((e) {
      if (c.isCompleted || e['req'] != req) return;
      if (e['type'] == 'connected' && e['role'] == 'client') {
        c.complete(BleTransport._(this, e));
      } else if (e['type'] == 'error') {
        c.completeError(
          BleException(e['message'] as String? ?? 'Erreur Bluetooth'),
        );
      }
    });
    try {
      await _call<void>('connect', {
        'address': address,
        'psm': psm,
        'req': req,
      });
      return await c.future.timeout(const Duration(seconds: 20));
    } on TimeoutException {
      unawaited(_call<void>('cancelConnect', {'req': req}).catchError((_) {}));
      throw BleException('Connexion impossible : délai dépassé');
    } finally {
      _waiting.remove(req);
      await sub.cancel();
    }
  }

  /// Coupe toutes les connexions.
  Future<void> closeAll() => _call<void>('closeAll');
}

/// Le canal réel, utilisable par une [Session] comme les autres transports.
class BleTransport implements Transport {
  BleTransport._(this._bridge, Map<String, dynamic> info)
    : cid = info['cid'] as int,
      remoteName = info['name'] as String? ?? 'Appareil',
      remoteAddress = info['address'] as String? ?? '' {
    _sub = _bridge.events.listen(_onEvent);
  }

  final BleBridge _bridge;

  /// Numéro de cette connexion côté Android.
  final int cid;
  final String remoteName;
  final String remoteAddress;

  final StreamController<Uint8List> _in = StreamController<Uint8List>();
  late final StreamSubscription<Map<String, dynamic>> _sub;
  Future<void> _tail = Future<void>.value();
  bool _closed = false;

  @override
  Stream<Uint8List> get incoming => _in.stream;

  void _onEvent(Map<String, dynamic> e) {
    if (e['cid'] != cid) return; // évènement d'une autre connexion
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
    final run = _tail.then(
      (_) => _bridge._call<void>('send', {'cid': cid, 'bytes': bytes}),
    );
    _tail = run.catchError((_) {});
    return run;
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _finish();
    try {
      await _bridge._call<void>('close', {'cid': cid});
    } catch (_) {}
  }

  void _finish() {
    if (_closed) return;
    _closed = true;
    _sub.cancel();
    if (!_in.isClosed) _in.close();
  }
}
