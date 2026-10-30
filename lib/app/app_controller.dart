import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../bluetooth/background_service.dart';
import '../bluetooth/ble_bridge.dart';
import '../bluetooth/bluetooth_bridge.dart';
import '../chat/chat_link.dart';
import '../chat/chat_store.dart';
import '../chat/diagnostics.dart';
import '../chat/group_ops.dart';
import '../chat/models.dart';
import '../chat/sqlite_chat_store.dart';
import '../protocol/frame.dart';
import '../protocol/transport.dart';

/// Relie la base, le Bluetooth et les connexions actives. Plusieurs
/// connexions peuvent être ouvertes en même temps (jusqu'à [maxLinks]) et
/// restent ouvertes quand l'application passe en arrière-plan.
class AppController extends ChangeNotifier
    with WidgetsBindingObserver
    implements LinkHub {
  AppController._(this.store, this.identity, this.themeMode, this.filesDir) {
    _storeSub = store.changes.listen((_) => notifyListeners());
    _acceptSub = _ble.accepted.listen((t) => _attach(t));
    _foundSub = _ble.found.listen(_onFound);
    _autoTimer = Timer.periodic(
      const Duration(seconds: 20),
      (_) => unawaited(_autoCycle()),
    );
    WidgetsBinding.instance.addObserver(this);
  }

  /// Plafond de connexions ouvertes en même temps. La vraie limite est celle
  /// de la puce Bluetooth du téléphone, qui varie d'un modèle à l'autre :
  /// l'application essaie jusqu'à ce plafond et retient le nombre où le
  /// téléphone commence à refuser (voir [linkLimit]).
  static const int maxLinks = 15;

  int? _learnedMax;
  final Map<int, int> _failsAt = {};

  /// Nombre de connexions que ce téléphone accepte, d'après ce qu'on a
  /// constaté (ou le plafond tant que rien n'a été refusé).
  int get linkLimit => min(maxLinks, _learnedMax ?? maxLinks);

  /// Le téléphone a-t-il déjà refusé une connexion supplémentaire ?
  int? get detectedLimit => _learnedMax;

  /// Une connexion vers quelqu'un qu'on venait de voir a échoué alors qu'on
  /// en avait déjà [n] : deux échecs au même nombre = la limite du téléphone.
  void _noteConnectFailure() {
    final n = _byContact.length;
    if (n < 2) return;
    final fails = (_failsAt[n] ?? 0) + 1;
    _failsAt[n] = fails;
    if (fails >= 2 && (_learnedMax == null || n < _learnedMax!)) {
      _learnedMax = n;
      Diagnostics.log('Limite détectée : ce téléphone accepte $n connexions');
      unawaited(
        store.saveSetting(
          'link_limit',
          '$n@${DateTime.now().millisecondsSinceEpoch}',
        ),
      );
      notifyListeners();
    }
  }

  Future<void> _loadLinkLimit() async {
    final raw = await store.setting('link_limit');
    if (raw == null) return;
    final parts = raw.split('@');
    if (parts.length != 2) return;
    final n = int.tryParse(parts[0]);
    final at = int.tryParse(parts[1]);
    if (n == null || at == null) return;
    final when = DateTime.fromMillisecondsSinceEpoch(at);
    // Une limite constatée n'est valable que quelques heures : on réessaie
    // ensuite, car elle dépendait peut-être de la distance.
    if (DateTime.now().difference(when) < const Duration(hours: 6)) {
      _learnedMax = n;
    }
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
    final c = AppController._(store, identity, mode, filesDir);
    c.keepRunning = await store.setting('background') != '0';
    await c._loadLinkLimit();
    return c;
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

  final BackgroundService _service = BackgroundService.instance;

  final Set<ChatLink> _active = {};
  final Map<String, ChatLink> _byContact = {};
  final Set<String> _connecting = {}; // débuts d'identifiant en cours de connexion
  final Map<String, DateTime> _lastAttempt = {};
  final Map<String, DateTime> _noAutoUntil = {};
  final Set<String> _seenReceipts = {};
  Future<void> _connectTail = Future<void>.value();

  ChatLink? _fileSlot; // la liaison qui envoie un gros fichier en ce moment
  final Set<String> _receivingIds = {};
  final Map<String, DateTime> _lastProgressNotify = {};

  /// Rester connecté quand on quitte l'application (service de premier plan).
  bool keepRunning = true;
  bool _serviceOn = false;
  String _serviceText = '';
  bool _foreground = true;

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

  /// Nombre de personnes connectées en ce moment.
  int get connectedCount => _byContact.length;

  /// Combien de membres de ce groupe (hors nous) sont connectés.
  int connectedMembers(Group g) => g.members
      .where((m) => m.deviceId != identity?.deviceId && isConnected(m.deviceId))
      .length;

  // ---------- Pour les connexions (LinkHub) ----------

  @override
  Iterable<ChatLink> get links => _active;

  @override
  bool firstTimeSeen(String key) {
    if (_seenReceipts.length > 3000) _seenReceipts.clear();
    return _seenReceipts.add(key);
  }

  @override
  bool get transferring => progress.isNotEmpty || _active.any((l) => l.busy);

  @override
  bool acquireFileSlot(ChatLink link) {
    if (_fileSlot == null || identical(_fileSlot, link)) {
      _fileSlot = link;
      return true;
    }
    return false;
  }

  @override
  void releaseFileSlot(ChatLink link) {
    if (identical(_fileSlot, link)) {
      _fileSlot = null;
      // Le prochain qui attendait son tour peut partir.
      unawaited(_deliverAll());
    }
  }

  @override
  bool beginReceiving(String messageId) => _receivingIds.add(messageId);

  @override
  void endReceiving(String messageId) => _receivingIds.remove(messageId);

  @override
  void membershipChanged() {
    notifyListeners();
    unawaited(_autoCycle());
  }

  @override
  void messageReceived(ChatMessage message) {
    if (_foreground) return;
    unawaited(_notifyIncoming(message));
  }

  Future<void> _notifyIncoming(ChatMessage m) async {
    final String title;
    final String body;
    final what = switch (m.kind) {
      MessageKind.text => m.text,
      MessageKind.image => 'Image',
      MessageKind.audio => 'Message vocal',
      MessageKind.file => m.fileName ?? 'Fichier',
    };
    if (m.isGroupMessage) {
      final g = await store.group(m.contactId);
      title = g?.name ?? 'Groupe';
      body = '${m.senderName ?? 'Membre'} : $what';
    } else {
      title = (await store.contact(m.contactId))?.name ?? 'BlueTalk';
      body = what;
    }
    await _service.notify(
      id: m.contactId.hashCode & 0x7fffffff,
      title: title,
      body: body,
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final wasForeground = _foreground;
    _foreground = state == AppLifecycleState.resumed;
    if (_foreground && !wasForeground) {
      notifyListeners();
      unawaited(_autoCycle());
    }
  }

  /// Bouton Retour sur l'écran principal : on met l'application de côté sans
  /// la fermer, pour que les connexions continuent.
  Future<void> goToBackground() => _service.moveToBack();

  // ---------- Présence en arrière-plan ----------

  Future<void> setKeepRunning(bool on) async {
    keepRunning = on;
    notifyListeners();
    await store.saveSetting('background', on ? '1' : '0');
    if (on) {
      await _updateService();
    } else {
      _serviceOn = false;
      _serviceText = '';
      await _service.stop();
    }
  }

  Future<void> _updateService() async {
    if (identity == null || !_blePermOk || !keepRunning) return;
    final n = _byContact.length;
    final text = n == 0
        ? 'En attente de contacts à proximité'
        : n == 1
        ? 'Connecté à 1 appareil'
        : 'Connecté à $n appareils';
    if (_serviceOn && text == _serviceText) return;
    _serviceText = text;
    _serviceOn = await _service.start(text);
  }

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
    unawaited(_service.ensureNotifications());
    await _updateService();
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

  /// Ouvre une connexion depuis la liste « Rechercher ». La recherche reste
  /// active : on peut en ouvrir plusieurs à la suite.
  Future<bool> connectNearby(NearbyUser u) async {
    lastError = null;
    if (!await _prepareBle()) return false;
    if (_active.length >= linkLimit) {
      _fail('Déjà $linkLimit connexions ouvertes : coupe-en une d\'abord.');
      return false;
    }
    final contactId = _knownId(u.idHex);
    if (contactId != null) _noAutoUntil.remove(contactId);
    try {
      await _connectTo(u);
      return true;
    } catch (e) {
      _fail('Connexion impossible : $e');
      return false;
    }
  }

  /// L'identifiant complet d'une personne déjà connectée, d'après son début.
  String? _knownId(String idHex) =>
      _byContact.keys.where((k) => k.startsWith(idHex)).firstOrNull;

  /// Est-ce que cette personne est déjà connectée ? (pour l'écran de recherche)
  bool isNearbyConnected(NearbyUser u) => _knownId(u.idHex) != null;

  /// Ouvre une connexion, une à la fois : Android supporte mal plusieurs
  /// ouvertures simultanées.
  Future<void> _connectTo(NearbyUser u) {
    final job = _connectTail.then((_) async {
      if (_knownId(u.idHex) != null || _connecting.contains(u.idHex)) return;
      _connecting.add(u.idHex);
      Diagnostics.log(
        'Connexion vers ${u.name} (${_active.length} déjà ouverte(s))',
      );
      try {
        final t = await _ble.connect(u.address, u.psm);
        _failsAt.clear();
        _attach(t, initiator: true);
      } catch (e) {
        Diagnostics.log('Connexion vers ${u.name} échouée : $e');
        _noteConnectFailure();
        rethrow;
      } finally {
        _connecting.remove(u.idHex);
      }
    });
    _connectTail = job.catchError((_) {});
    return job;
  }

  // ---------- Connexions automatiques ----------

  /// Les personnes avec qui on veut rester connecté : les membres de nos
  /// groupes (pour discuter en direct) et les contacts à qui des messages
  /// attendent.
  Future<Set<String>> _wantedIds() async {
    final me = identity!.deviceId;
    final ids = <String>{};
    for (final g in await store.groups()) {
      if (!g.active) continue;
      for (final m in g.members) {
        if (m.deviceId != me) ids.add(m.deviceId);
      }
    }
    for (final c in await store.contacts()) {
      if ((await store.pendingFor(c.deviceId)).isNotEmpty) ids.add(c.deviceId);
    }
    final now = DateTime.now();
    ids.removeWhere((id) {
      final until = _noAutoUntil[id];
      return until != null && now.isBefore(until);
    });
    return ids;
  }

  /// Cherche les personnes voulues qui sont à portée et s'y connecte, jusqu'à
  /// [maxLinks]. Revient toutes les 20 secondes, et après chaque coupure :
  /// une personne qui s'éloigne puis revient est reconnectée seule.
  Future<void> _autoCycle() async {
    if (_autoBusy || identity == null || _active.length >= linkLimit) return;
    // Pendant un transfert, on ne cherche personne : un scan Bluetooth ralentit
    // les liaisons ouvertes et peut les couper.
    if (transferring) return;
    _autoBusy = true;
    try {
      final wanted = await _wantedIds();
      wanted.removeWhere(_byContact.containsKey);
      if (wanted.isEmpty || !await _prepareBle(ask: false)) return;

      // Si l'écran « Rechercher » scanne déjà, on utilise ses résultats.
      if (!scanning) {
        await _ble.startScan();
        await Future<void>.delayed(const Duration(seconds: 5));
        try {
          await _ble.stopScan();
        } catch (_) {}
      }

      for (final u in nearbyUsers) {
        if (_active.length + _connecting.length >= linkLimit) break;
        final id = wanted.where((w) => w.startsWith(u.idHex)).firstOrNull;
        if (id == null || _byContact.containsKey(id)) continue;
        final last = _lastAttempt[id];
        if (last != null &&
            DateTime.now().difference(last) < const Duration(seconds: 12)) {
          continue;
        }
        _lastAttempt[id] = DateTime.now();
        // Petit délai aléatoire : si l'autre téléphone se connecte à nous au
        // même moment, une seule des deux connexions est gardée.
        await Future<void>.delayed(
          Duration(milliseconds: Random().nextInt(1200)),
        );
        if (_byContact.containsKey(id)) continue;
        try {
          await _connectTo(u);
        } catch (_) {}
      }
    } catch (_) {
      // Rien de grave : on réessaiera au prochain passage.
    } finally {
      _autoBusy = false;
    }
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
      if (_active.length >= linkLimit) {
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
      _lastProgressNotify.remove(messageId);
      notifyListeners();
      return;
    }
    progress[messageId] = p;
    // On ne redessine pas l'écran à chaque bloc reçu : cela ralentissait les
    // transferts. Quelques mises à jour par seconde suffisent.
    final now = DateTime.now();
    final last = _lastProgressNotify[messageId];
    if (last == null ||
        now.difference(last) > const Duration(milliseconds: 400)) {
      _lastProgressNotify[messageId] = now;
      notifyListeners();
    }
  }

  void _attach(Transport transport, {String? address, bool initiator = false}) {
    if (_active.length >= linkLimit) {
      Diagnostics.log('Connexion reçue refusée : limite de $linkLimit atteinte');
      unawaited(transport.close());
      return;
    }
    Diagnostics.log(
      'Connexion ${initiator ? 'ouverte' : 'reçue'} '
      '(${_active.length + 1} au total)',
    );
    final link = ChatLink(
      transport: transport,
      store: store,
      identity: identity!,
      address: address,
      filesDir: filesDir,
      onProgress: _onProgress,
      initiator: initiator,
      hub: this,
      keepAlive: const Duration(seconds: 20),
    );
    _active.add(link);
    notifyListeners();

    link.ready.then((contactId) {
      final existing = _byContact[contactId];
      if (existing != null && !identical(existing, link)) {
        // Deux connexions avec la même personne (chacun a appelé l'autre en
        // même temps). Les deux téléphones gardent la même : celle ouverte
        // par la personne dont l'identifiant est le plus petit.
        final me = identity!.deviceId;
        final smaller = me.compareTo(contactId) < 0 ? me : contactId;
        String initiatorOf(ChatLink l) => l.initiator ? me : contactId;
        if (initiatorOf(link) == smaller && initiatorOf(existing) != smaller) {
          unawaited(existing.close());
        } else {
          unawaited(link.close());
          return;
        }
      }
      _byContact[contactId] = link;
      notifyListeners();
      unawaited(_updateService());
    }, onError: (_) {});

    link.closed.then((_) {
      if (identical(_fileSlot, link)) _fileSlot = null;
      _active.remove(link);
      _byContact.removeWhere((_, l) => identical(l, link));
      notifyListeners();
      unawaited(_updateService());
      // La personne est peut-être juste sortie de portée : on la recherche.
      Timer(const Duration(seconds: 4), () => unawaited(_autoCycle()));
    });
  }

  /// Coupe la connexion avec quelqu'un. On ne le reconnecte pas tout seul
  /// pendant les 5 minutes qui suivent.
  Future<void> disconnect(String contactId) async {
    _noAutoUntil[contactId] = DateTime.now().add(const Duration(minutes: 5));
    await _byContact[contactId]?.close();
  }

  // ---------- Messages ----------

  /// Écrit un message. Il est enregistré tout de suite (« en attente ») et
  /// part immédiatement si le contact est connecté, sinon dès qu'il est à portée.
  Future<void> sendText(String conversationId, String text) async {
    final t = text.trim();
    if (t.isEmpty) return;
    final g = await store.group(conversationId);
    if (g != null) {
      if (!g.canPost(identity!.deviceId)) return;
      await queueGroupText(store, identity!, g, t);
      await _deliverAll();
      return;
    }
    await store.addMessage(
      ChatMessage.draft(contactId: conversationId, text: t),
    );
    await _deliverNow(conversationId);
  }

  /// Envoie un fichier, une image ou un message vocal (à une personne ou à
  /// un groupe). Renvoie un message d'erreur, ou null si tout va bien. Le
  /// fichier est d'abord copié dans le dossier de l'application, pour qu'il
  /// reste disponible même si l'original disparaît.
  Future<String?> sendFile(
    String conversationId, {
    required String sourcePath,
    required String name,
    bool image = false,
    MessageKind? kind,
    int? durationMs,
  }) async {
    try {
      final size = await File(sourcePath).length();
      if (size > maxFileSize) {
        return 'Fichier trop volumineux (maximum '
            '${maxFileSize ~/ (1024 * 1024)} Mo).';
      }
      final stored = await copyIntoStorage(filesDir, sourcePath, name);
      final k = kind ?? (image ? MessageKind.image : MessageKind.file);
      final g = await store.group(conversationId);
      if (g != null) {
        if (!g.canPost(identity!.deviceId)) {
          return g.adminsOnlyPost
              ? 'Seuls les administrateurs peuvent écrire dans ce groupe.'
              : 'Tu ne fais plus partie de ce groupe.';
        }
        await queueGroupFile(
          store,
          identity!,
          g,
          kind: k,
          fileName: name,
          fileSize: size,
          storedPath: stored,
          durationMs: durationMs,
        );
        await _deliverAll();
        return null;
      }
      await store.addMessage(
        ChatMessage.draftFile(
          contactId: conversationId,
          kind: k,
          fileName: name,
          fileSize: size,
          filePath: stored,
          durationMs: durationMs,
        ),
      );
      await _deliverNow(conversationId);
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
      unawaited(_autoCycle()); // on le cherche sans attendre le prochain passage
    }
  }

  /// Fait partir ce qui attend sur toutes les connexions ouvertes.
  Future<void> _deliverAll() async {
    for (final l in _active.toList()) {
      if (l.remoteId == null) continue;
      try {
        await l.flush();
      } catch (_) {}
    }
    unawaited(_autoCycle());
  }

  // ---------- Groupes ----------

  /// Crée un groupe avec des personnes déjà rencontrées. Le groupe se diffuse
  /// tout seul : à ceux qui sont connectés tout de suite, aux autres dès
  /// qu'ils sont à portée.
  Future<Group?> createGroup(String name, List<Contact> members) async {
    final n = name.trim();
    if (identity == null || n.isEmpty || members.isEmpty) return null;
    final g = newGroup(identity!, n, members);
    await store.saveGroup(g);
    await _pushGroup(g);
    unawaited(_autoCycle());
    return g;
  }

  /// Modifie un groupe : réservé au créateur et aux administrateurs. Seul le
  /// créateur nomme les administrateurs et supprime le groupe ; un
  /// administrateur ne peut pas retirer le créateur ni un autre administrateur.
  /// Renvoie la nouvelle version, ou null si la modification est refusée.
  Future<Group?> updateGroup(
    Group g, {
    String? name,
    List<GroupMember>? members,
    List<String>? admins,
    bool? adminsOnlyPost,
  }) async {
    final me = identity?.deviceId;
    if (me == null || !g.isAdmin(me) || !g.active) return null;
    final isCreator = g.creatorId == me;
    if (admins != null && !isCreator) return null;
    if (members != null) {
      final keep = members.map((m) => m.deviceId).toSet();
      if (!keep.contains(g.creatorId)) return null;
      for (final old in g.members) {
        if (keep.contains(old.deviceId)) continue;
        if (!isCreator && g.isAdmin(old.deviceId)) return null;
      }
    }
    final next = editedGroup(
      g,
      by: me,
      name: name,
      members: members,
      admins: admins,
      adminsOnlyPost: adminsOnlyPost,
    );
    await store.saveGroup(next);
    final removed = g.members
        .map((m) => m.deviceId)
        .where((id) => !next.hasMember(id));
    await _pushGroup(next, alsoTo: removed);
    unawaited(_autoCycle());
    return next;
  }

  Future<Group?> addMember(Group g, Contact c) => updateGroup(
    g,
    members: [...g.members, GroupMember(deviceId: c.deviceId, name: c.name)],
  );

  Future<Group?> removeMember(Group g, String deviceId) => updateGroup(
    g,
    members: g.members.where((m) => m.deviceId != deviceId).toList(),
  );

  /// Nomme ou retire un administrateur (créateur uniquement).
  Future<Group?> setAdmin(Group g, String deviceId, bool admin) {
    final list = g.admins.where((a) => a != deviceId).toList();
    if (admin) list.add(deviceId);
    return updateGroup(g, admins: list);
  }

  /// Active ou non le mode annonces (seuls les administrateurs écrivent).
  Future<Group?> setAdminsOnlyPost(Group g, bool on) =>
      updateGroup(g, adminsOnlyPost: on);

  /// Supprime le groupe pour tous ses membres (créateur uniquement).
  Future<bool> closeGroup(Group g) async {
    final me = identity?.deviceId;
    if (me == null || g.creatorId != me || !g.active) return false;
    final next = editedGroup(g, by: me, closed: true);
    await _pushGroup(next);
    await store.saveGroup(next.copyWith(active: false));
    return true;
  }

  /// Quitte un groupe (impossible pour son créateur). Le créateur en est
  /// prévenu, directement ou par un autre membre.
  Future<void> leaveGroup(Group g) async {
    final me = identity;
    if (me == null || g.creatorId == me.deviceId) return;
    final frame = Frame.json(FrameType.groupLeave, {
      'gid': g.id,
      'who': me.deviceId,
    });
    for (final l in _active.toList()) {
      final id = l.remoteId;
      if (id != null && g.hasMember(id)) await l.sendFrame(frame);
    }
    await store.saveGroup(g.copyWith(active: false));
  }

  Future<void> deleteGroup(String id) => store.deleteGroup(id);

  Future<void> _pushGroup(Group g, {Iterable<String> alsoTo = const []}) async {
    final extra = alsoTo.toSet();
    for (final l in _active.toList()) {
      final id = l.remoteId;
      if (id != null && (g.hasMember(id) || extra.contains(id))) {
        await l.sendGroupInfo(g);
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
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
