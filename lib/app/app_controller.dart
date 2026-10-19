import 'dart:async';

import 'package:flutter/foundation.dart';

import '../bluetooth/bluetooth_bridge.dart';
import '../chat/chat_link.dart';
import '../chat/chat_store.dart';
import '../chat/models.dart';
import '../chat/sqlite_chat_store.dart';

/// Relie la base, le Bluetooth et les connexions actives.
class AppController extends ChangeNotifier {
  AppController._(this.store, this.identity) {
    _storeSub = store.changes.listen((_) => notifyListeners());
  }

  static Future<AppController> start() async {
    final store = await SqliteChatStore.open();
    return AppController._(store, await store.loadIdentity());
  }

  final ChatStore store;
  Identity? identity;
  String? lastError;

  final BluetoothBridge _bt = BluetoothBridge.instance;
  late final StreamSubscription<void> _storeSub;

  final Set<ChatLink> _active = {};
  final Map<String, ChatLink> _byContact = {};
  bool _wantListen = false;

  bool get listening => _wantListen;
  bool get hasActiveConnection => _active.isNotEmpty;
  bool isConnected(String contactId) => _byContact.containsKey(contactId);

  Future<void> setName(String name) async {
    final id = Identity.create(name);
    await store.saveIdentity(id);
    identity = id;
    notifyListeners();
  }

  void _fail(String message) {
    lastError = message;
    notifyListeners();
  }

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

  // ---------- Attendre une connexion ----------

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
        // Une connexion est en cours : on réécoutera quand elle sera finie.
        await Future<void>.delayed(const Duration(seconds: 1));
        continue;
      }
      try {
        _attach(await _bt.listen());
      } catch (_) {
        if (!_wantListen) break;
        await Future<void>.delayed(const Duration(seconds: 2));
      }
    }
  }

  // ---------- Se connecter ----------

  Future<void> connectTo(BtDevice device) async {
    if (!await prepareBluetooth()) return;
    if (_wantListen) await stopListening();
    try {
      _attach(await _bt.connect(device.address));
    } catch (e) {
      _fail('Connexion impossible : $e');
    }
  }

  // ---------- Connexion active ----------

  void _attach(BluetoothTransport transport) {
    final link = ChatLink(
      transport: transport,
      store: store,
      identity: identity!,
      address: transport.remoteAddress,
    );
    _active.add(link);
    notifyListeners();

    link.ready.then((contactId) {
      _byContact[contactId] = link;
      notifyListeners();
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
  /// part immédiatement si le contact est connecté.
  Future<void> sendText(String contactId, String text) async {
    final t = text.trim();
    if (t.isEmpty) return;
    await store.addMessage(ChatMessage.draft(contactId: contactId, text: t));
    try {
      await _byContact[contactId]?.flush();
    } catch (_) {}
  }

  @override
  void dispose() {
    _storeSub.cancel();
    for (final l in _active.toList()) {
      unawaited(l.close());
    }
    super.dispose();
  }
}
