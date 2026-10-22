import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../bluetooth/ble_bridge.dart';
import '../bluetooth/bluetooth_bridge.dart';
import '../chat/chat_link.dart';
import '../chat/chat_store.dart';
import '../chat/models.dart';
import '../chat/sqlite_chat_store.dart';
import '../protocol/transport.dart';

/// Relie la base, le Bluetooth et les connexions actives.
class AppController extends ChangeNotifier {
  AppController._(this.store, this.identity, this.themeMode, this.filesDir) {
    _storeSub = store.changes.listen((_) => notifyListeners());
    _acceptSub = _ble.accepted.listen((t) => _attach(t));
    _foundSub = _ble.found.listen(_onFound);
    _autoTimer = Timer.periodic(
      const Duration(seconds: 25),
      (_) => unawaited(_autoCycle()),
    );
  }

  static Future<AppController> start() async {
    final store = await SqliteChatStore.open();
    final identity = await store.loadIdentity();
    final saved = await store.setting('theme');
    final mode = switch (saved) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };
    final docs = await getApplicationDocumentsDirectory();
    final filesDir = Directory('${docs.path}${Platform.pathSeparator}files');
    await filesDir.create(recursive: true);
    return AppController._(store, identity, mode, filesDir);
  }

  final ChatStore store;
  final Directory filesDir;
  Identity? identity;
  ThemeMode themeMode;
  String? lastError;

  /// Avancement des transferts de fichiers en cours (identifiant du message,
  /// entre 0 et 1).
  final Map<String, double> progress = {};

  final BluetoothBridge _bt = BluetoothBridge.instance; // mode de secours
  final BleBridge _ble = BleBridge.instance; // détection par balises
  late final StreamSubscription<void> _storeSub;
  late final StreamSubscription<BleTransport> _acceptSub;
  late final StreamSubscription<NearbyUser> _foundSub;
  late final Timer _autoTimer;

  final Set<ChatLink> _active = {};
  final Map<String, ChatLink> _byContact = {};

  // Mode de secours (association)
  bool _wantListen = false;
  bool get listening => _wantListen;

  // Détection par balises
  bool visible = false;
  bool scanning = false;
  bool _blePermOk = false;
  bool _autoBusy = false;
  final Map<String, NearbyUser> _nearby = {};
  final Map<String, DateTime> _nearbySeen = {};

  bool get hasActiveConnection => _active.isNotEmpty;
  bool isConnected(String contactId) => _byContact.containsKey(contactId);

  String get _myIdHex => identity!.deviceId.substring(0, 8);

  Uint8List get _myIdBytes => Uint8List.fromList([
    for (var i = 0; i < 8; i += 2)
      int.parse(_myIdHex.substring(i, i + 2), radix: 16),
  ]);

  /// Les utilisateurs vus dans les 15 dernières secondes (un par personne).
  List<NearbyUser> get nearbyUsers {
    final now = DateTime.now();
    final byId = <String, NearbyUser>{};
    for (final u in _nearby.values) {
      final seen = _nearbySeen[u.address];
      if (seen == null || now.difference(seen).inSeconds >= 15) continue;
      final old = byId[u.idHex];
      if (old == null || _nearbySeen[old.address]!.isBefore(seen)) {
        byId[u.idHex] = u;
      }
    }
    return byId.values.toList()..sort((a, b) => b.rssi.compareTo(a.rssi));
  }

  // ---------- Identité et réglages ----------

  Future<void> setName(String name) async {
    final id = Identity.create(name);
    await store.saveIdentity(id);
    identity = id;
    notifyListeners();
    unawaited(restoreVisibility());
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    themeMode = mode;
    notifyListeners();
    await store.saveSetting(
      'theme',
      mode == ThemeMode.dark
          ? 'dark'
          : mode == ThemeMode.light
          ? 'light'
          : 'system',
    );
  }

  void _fail(String message) {
    lastError = message;
    notifyListeners();
  }

  // ---------- Détection par balises ----------

  Future<bool> _prepareBle({bool ask = true}) async {
    if (!ask && !_blePermOk) return false;
    try {
      if (!await _ble.ensurePermissions()) {
        if (ask) _fail('Permissions Bluetooth refusées');
        return false;
      }
      if (!await _ble.isEnabled()) {
        if (ask) _fail('Active le Bluetooth du téléphone');
        return false;
      }
      _blePermOk = true;
      return true;
    } catch (e) {
      if (ask) _fail('$e');
      return false;
    }
  }

  /// Rend le téléphone visible (ou invisible) pour les autres utilisateurs.
  Future<void> setVisible(bool on) async {
    if (identity == null) return;
    if (!on) {
      try {
        await _ble.stopAdvertising();
      } catch (_) {}
      visible = false;
      notifyListeners();
      await store.saveSetting('visible', '0');
      return;
    }
    lastError = null;
    if (!await _prepareBle()) return;
    try {
      await _ble.startAdvertising(name: identity!.name, id: _myIdBytes);
      visible = true;
    } catch (e) {
      visible = false;
      _fail('Visibilité impossible : $e');
      return;
    }
    notifyListeners();
    await store.saveSetting('visible', '1');
  }

  /// Au démarrage : visible, sauf si l'utilisateur a choisi le contraire.
  Future<void> restoreVisibility() async {
    if (identity == null) return;
    if (await store.setting('visible') == '0') return;
    await setVisible(true);
  }

  void _onFound(NearbyUser u) {
    if (identity == null || u.idHex == _myIdHex) return;
    final known = _nearby[u.address];
    _nearby[u.address] = u;
    _nearbySeen[u.address] = DateTime.now();
    // On ne prévient l'interface que pour une nouveauté, pas à chaque écho.
    if (known == null || known.name != u.name) notifyListeners();
  }

  Future<void> startScan() async {
    if (scanning) return;
    lastError = null;
    if (!await _prepareBle()) return;
    try {
      await _ble.startScan();
      scanning = true;
    } catch (e) {
      _fail('Recherche impossible : $e');
      return;
    }
    notifyListeners();
  }

  Future<void> stopScan() async {
    if (!scanning) return;
    scanning = false;
    try {
      await _ble.stopScan();
    } catch (_) {}
    notifyListeners();
  }

  Future<bool> connectNearby(NearbyUser u) async {
    lastError = null;
    if (!await _prepareBle()) return false;
    await stopScan();
    try {
      _attach(await _ble.connect(u.address, u.psm));
      return true;
    } catch (e) {
      _fail('Connexion impossible : $e');
      return false;
    }
  }

  // ---------- Livraison automatique ----------

  /// Si des messages attendent un contact, on le cherche et on se connecte
  /// à lui dès qu'il est à portée.
  Future<void> _autoCycle() async {
    if (_autoBusy || identity == null || scanning || _active.isNotEmpty) return;
    _autoBusy = true;
    try {
      final targets = <Contact>[];
      for (final c in await store.contacts()) {
        if ((await store.pendingFor(c.deviceId)).isNotEmpty) targets.add(c);
      }
      if (targets.isEmpty || !await _prepareBle(ask: false)) return;

      await _ble.startScan();
      await Future<void>.delayed(const Duration(seconds: 6));
      try {
        await _ble.stopScan();
      } catch (_) {}

      for (final c in targets) {
        final user = nearbyUsers
            .where((u) => c.deviceId.startsWith(u.idHex))
            .firstOrNull;
        if (user == null) continue;
        // Petit délai aléatoire : si l'autre téléphone se connecte à nous
        // au même moment, l'un des deux cède la place.
        await Future<void>.delayed(
          Duration(milliseconds: Random().nextInt(1500)),
        );
        if (_active.isNotEmpty) return;
        try {
          _attach(await _ble.connect(user.address, user.psm), autoClose: true);
        } catch (_) {}
        return;
      }
    } catch (_) {
      // Rien de grave : on réessaiera au prochain passage.
    } finally {
      _autoBusy = false;
    }
  }

  /// Ferme une connexion automatique une fois tout livré et plus rien en cours.
  void _watchIdle(ChatLink link, String contactId) {
    var idle = 0;
    Timer.periodic(const Duration(seconds: 4), (t) async {
      if (!_active.contains(link)) {
        t.cancel();
        return;
      }
      final busy =
          progress.isNotEmpty || (await store.pendingFor(contactId)).isNotEmpty;
      idle = busy ? 0 : idle + 1;
      if (idle >= 3) {
        t.cancel();
        await link.close();
      }
    });
  }

  // ---------- Mode de secours : association Bluetooth ----------

  Future<bool> prepareBluetooth() async {
    lastError = null;
    try {
      if (!await _bt.ensurePermissions()) {
        _fail('Permission Bluetooth refusée');
        return false;
      }
      if (!await _bt.isEnabled()) {
        _fail('Active le Bluetooth du téléphone');
        return false;
      }
      return true;
    } catch (e) {
      _fail('$e');
      return false;
    }
  }

  Future<List<BtDevice>> bondedDevices() async {
    if (!await prepareBluetooth()) return const [];
    try {
      return await _bt.bondedDevices();
    } catch (e) {
      _fail('$e');
      return const [];
    }
  }

  Future<void> startListening() async {
    if (_wantListen) return;
    if (!await prepareBluetooth()) return;
    _wantListen = true;
    notifyListeners();
    unawaited(_listenLoop());
  }

  Future<void> stopListening() async {
    _wantListen = false;
    notifyListeners();
    try {
      await _bt.stopListening();
    } catch (_) {}
  }

  Future<void> _listenLoop() async {
    while (_wantListen) {
      if (_active.isNotEmpty) {
        await Future<void>.delayed(const Duration(seconds: 1));
        continue;
      }
      try {
        final t = await _bt.listen();
        _attach(t, address: t.remoteAddress);
      } catch (_) {
        if (!_wantListen) break;
        await Future<void>.delayed(const Duration(seconds: 2));
      }
    }
  }

  Future<void> connectTo(BtDevice device) async {
    if (!await prepareBluetooth()) return;
    if (_wantListen) await stopListening();
    try {
      final t = await _bt.connect(device.address);
      _attach(t, address: t.remoteAddress);
    } catch (e) {
      _fail('Connexion impossible : $e');
    }
  }

  // ---------- Connexion active ----------

  void _onProgress(String messageId, double p) {
    if (p < 0 || p >= 1) {
      progress.remove(messageId);
    } else {
      progress[messageId] = p;
    }
    notifyListeners();
  }

  void _attach(Transport transport, {String? address, bool autoClose = false}) {
    final link = ChatLink(
      transport: transport,
      store: store,
      identity: identity!,
      address: address,
      filesDir: filesDir,
      onProgress: _onProgress,
    );
    _active.add(link);
    notifyListeners();

    link.ready.then((contactId) {
      _byContact[contactId] = link;
      notifyListeners();
      if (autoClose) _watchIdle(link, contactId);
    }, onError: (_) {});

    link.closed.then((_) {
      _active.remove(link);
      _byContact.removeWhere((_, l) => identical(l, link));
      notifyListeners();
    });
  }

  Future<void> disconnect(String contactId) async {
    await _byContact[contactId]?.close();
  }

  // ---------- Messages ----------

  /// Écrit un message. Il est enregistré tout de suite (« en attente ») et
  /// part immédiatement si le contact est connecté, sinon dès qu'il est à portée.
  Future<void> sendText(String contactId, String text) async {
    final t = text.trim();
    if (t.isEmpty) return;
    await store.addMessage(ChatMessage.draft(contactId: contactId, text: t));
    await _deliverNow(contactId);
  }

  /// Envoie un fichier ou une image. Renvoie un message d'erreur, ou null si
  /// tout va bien. Le fichier est d'abord copié dans le dossier de
  /// l'application, pour qu'il reste disponible même si l'original disparaît.
  Future<String?> sendFile(
    String contactId, {
    required String sourcePath,
    required String name,
    required bool image,
  }) async {
    try {
      final src = File(sourcePath);
      final size = await src.length();
      if (size > maxFileSize) {
        return 'Fichier trop volumineux (maximum '
            '${maxFileSize ~/ (1024 * 1024)} Mo).';
      }
      final safe = name.replaceAll(RegExp(r'[\\/]'), '_');
      final stored =
          '${filesDir.path}${Platform.pathSeparator}${generateId()}_$safe';
      await src.copy(stored);
      await store.addMessage(
        ChatMessage.draftFile(
          contactId: contactId,
          kind: image ? MessageKind.image : MessageKind.file,
          fileName: name,
          fileSize: size,
          filePath: stored,
        ),
      );
      await _deliverNow(contactId);
      return null;
    } catch (e) {
      return 'Impossible d\'envoyer ce fichier : $e';
    }
  }

  Future<void> _deliverNow(String contactId) async {
    final link = _byContact[contactId];
    if (link != null) {
      try {
        await link.flush();
      } catch (_) {}
    } else {
      unawaited(
        _autoCycle(),
      ); // on le cherche sans attendre le prochain passage
    }
  }

  @override
  void dispose() {
    _autoTimer.cancel();
    _storeSub.cancel();
    _acceptSub.cancel();
    _foundSub.cancel();
    unawaited(_ble.stopAdvertising().catchError((_) {}));
    for (final l in _active.toList()) {
      unawaited(l.close());
    }
    super.dispose();
  }
}
