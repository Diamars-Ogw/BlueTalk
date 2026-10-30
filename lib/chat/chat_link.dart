import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../protocol/frame.dart';
import '../protocol/session.dart';
import '../protocol/transport.dart';
import 'chat_store.dart';
import 'diagnostics.dart';
import 'group_ops.dart';
import 'models.dart';

/// Taille des blocs d'un fichier.
const int fileChunkSize = 16 * 1024;

/// Taille maximale d'un fichier accepté.
const int maxFileSize = 100 * 1024 * 1024;

class _DigestCapture implements Sink<Digest> {
  Digest? value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}

/// Calcule l'empreinte SHA-256 au fil de l'eau, sans garder le fichier.
class _Hasher {
  _Hasher() {
    _input = sha256.startChunkedConversion(_out);
  }

  final _DigestCapture _out = _DigestCapture();
  late final Sink<List<int>> _input;

  void add(List<int> data) => _input.add(data);

  String finish() {
    _input.close();
    return _out.value.toString();
  }
}

/// Un fichier en cours de réception.
class _Incoming {
  _Incoming({
    required this.tid,
    required this.messageId,
    required this.path,
    required this.size,
    this.offset = 0,
  }) : sink = File(path).openWrite(
         mode: offset > 0 ? FileMode.append : FileMode.write,
       ),
       received = offset;

  final int tid;
  final String messageId;
  final String path;
  final int size;

  /// Nombre d'octets déjà reçus lors d'une tentative précédente : le fichier
  /// reprend à cet endroit.
  final int offset;
  final IOSink sink;
  int received;
}

/// Empreinte SHA-256 d'un fichier entier, lue par morceaux.
Future<String> _hashFile(File f) async {
  final h = _Hasher();
  await for (final piece in f.openRead()) {
    h.add(piece);
  }
  return h.finish();
}

/// Ce que l'application met à disposition des connexions, pour les groupes :
/// voir les autres connexions (relais des messages, diffusion des reçus),
/// être prévenue d'un message reçu, ne pas diffuser deux fois le même reçu.
abstract interface class LinkHub {
  /// Toutes les connexions actuellement ouvertes.
  Iterable<ChatLink> get links;

  /// Renvoie vrai la première fois qu'on lui donne cette clé. Sert à ne
  /// transmettre chaque reçu de livraison qu'une seule fois.
  bool firstTimeSeen(String key);

  /// Un nouveau message vient d'arriver (pour la notification).
  void messageReceived(ChatMessage message);

  /// La liste des groupes ou de leurs membres a changé.
  void membershipChanged();

  /// Vrai quand un transfert de fichier est en cours quelque part : on évite
  /// alors de chercher d'autres téléphones ou de couper une liaison.
  bool get transferring;

  /// Un seul fichier part à la fois depuis ce téléphone : envoyer le même
  /// fichier à plusieurs membres en parallèle saturait la radio et coupait des
  /// liaisons. Renvoie vrai si la connexion peut commencer à envoyer.
  bool acquireFileSlot(ChatLink link);

  /// Libère la place prise par [acquireFileSlot].
  void releaseFileSlot(ChatLink link);

  /// Un même fichier ne se reçoit que d'une connexion à la fois (il peut
  /// arriver par plusieurs relais). Renvoie faux s'il est déjà en cours.
  bool beginReceiving(String messageId);

  void endReceiving(String messageId);
}

/// Une connexion avec un contact. À l'ouverture : on se présente, on
/// enregistre l'autre comme contact, puis on envoie ce qui attendait.
class ChatLink {
  ChatLink({
    required Transport transport,
    required this.store,
    required this.identity,
    this.address,
    this.filesDir,
    this.onProgress,
    this.initiator = false,
    this.hub,
    Duration? keepAlive,
    this.keepAliveTimeout = const Duration(seconds: 12),
  }) : session = Session(transport, autoAck: false) {
    _ready.future.ignore();
    _sub = session.frames.listen((f) => _enqueue(() => _handle(f)).ignore());
    unawaited(session.done.then((_) => _onClosed()));
    session
        .sendHello(deviceId: identity.deviceId, name: identity.name)
        .catchError((_) {});
    if (keepAlive != null) {
      _keepAliveTimer = Timer.periodic(
        keepAlive,
        (_) => unawaited(_checkAlive()),
      );
    }
  }

  /// Vrai si c'est nous qui avons ouvert la connexion (faux si on l'a reçue).
  /// Sert à départager deux connexions ouvertes en même temps entre les
  /// deux mêmes personnes.
  final bool initiator;

  final LinkHub? hub;

  /// Temps accordé à l'autre pour répondre à un PING avant de couper.
  final Duration keepAliveTimeout;
  Timer? _keepAliveTimer;
  bool _pinging = false;

  final Session session;
  final ChatStore store;
  final Identity identity;
  final String? address; // adresse Bluetooth de l'autre, si on la connaît

  /// Dossier où ranger les fichiers reçus. Sans lui, les fichiers sont refusés.
  final Directory? filesDir;

  /// Avancement d'un transfert : entre 0 et 1 pendant le transfert, 1 quand
  /// il est terminé, -1 quand il s'arrête sans avoir abouti.
  final void Function(String messageId, double progress)? onProgress;

  /// Identifiant du contact, connu après sa présentation.
  String? remoteId;

  static final RegExp _validId = RegExp(r'^[0-9a-f]{8,64}$');

  final Completer<String> _ready = Completer<String>();
  late final StreamSubscription<Frame> _sub;
  Future<void> _queue = Future<void>.value();

  _Incoming? _incoming;
  bool _sendingFile = false;
  bool _closedFlag = false;
  int _tidCounter = 0;
  int _pingMisses = 0;
  final Map<String, int> _fileRetries = {};

  /// Empreinte d'un fichier à envoyer, calculée une seule fois même s'il part
  /// vers plusieurs membres.
  static final Map<String, Future<String>> _fileHashes = {};

  /// Réponse à une proposition de fichier : le décalage où reprendre
  /// (0 = depuis le début), ou -1 si l'autre refuse.
  final Map<String, Completer<int>> _awaitingAccept = {};
  final Set<String> _aborted = {};
  final Map<String, int> _steps = {};

  /// Se termine quand l'autre s'est présenté (et vaut son identifiant).
  Future<String> get ready => _ready.future;

  /// Se termine quand la connexion est fermée.
  Future<void> get closed => session.done;

  Future<void> close() => session.close();

  /// Vrai quand cette connexion envoie ou reçoit un fichier.
  bool get busy => _sendingFile || _incoming != null;

  /// À appeler après avoir écrit un message : tente de l'envoyer maintenant.
  Future<void> flush() => _enqueue(() => _flush(includeSent: false));

  // Les traitements se font un par un, dans l'ordre d'arrivée.
  Future<void> _enqueue(Future<void> Function() job) {
    final run = _queue.then((_) => job());
    _queue = run.catchError((_) {});
    return run;
  }

  /// Détecte une connexion morte (l'autre téléphone est parti sans que le
  /// Bluetooth le signale) : sans réponse à un PING, on ferme.
  Future<void> _checkAlive() async {
    // Pendant un transfert, la radio est saturée : une réponse lente ne veut
    // pas dire que la liaison est morte. On ne vérifie rien (la liaison
    // signale elle-même sa coupure si elle tombe vraiment).
    if (busy || (hub?.transferring ?? false)) {
      _pingMisses = 0;
      return;
    }
    if (_pinging) return;
    _pinging = true;
    try {
      await session.ping(timeout: keepAliveTimeout);
      _pingMisses = 0;
    } catch (_) {
      // Deux silences de suite avant de couper.
      if (++_pingMisses >= 2) {
        Diagnostics.log(
          'Coupure ${remoteId?.substring(0, 6) ?? '?'} : pas de réponse au PING',
        );
        unawaited(close());
      }
    } finally {
      _pinging = false;
    }
  }

  void _onClosed() {
    _closedFlag = true;
    _keepAliveTimer?.cancel();
    Diagnostics.log(
      'Connexion fermée avec ${remoteId?.substring(0, 6) ?? 'inconnu'}'
      '${busy ? ' (pendant un transfert)' : ''}',
    );
    if (!_ready.isCompleted) {
      _ready
          .completeError(StateError('Connexion fermée avant la présentation'));
    }
    for (final c in _awaitingAccept.values) {
      if (!c.isCompleted) c.complete(-1);
    }
    unawaited(_dropIncoming());
    unawaited(_sub.cancel());
  }

  Future<void> _handle(Frame f) async {
    try {
      switch (f.type) {
        case FrameType.hello:
          await _onHello(f.json);
        case FrameType.text:
          await _onText(f.json);
        case FrameType.ack:
          await _onAck(f.json);
        case FrameType.fileOffer:
          await _onOffer(f.json);
        case FrameType.fileAccept:
          _onAccept(f.json);
        case FrameType.fileChunk:
          await _onChunk(f.payload);
        case FrameType.fileEnd:
          await _onEnd(f.json);
        case FrameType.fileAbort:
          await _onAbort(f.json);
        case FrameType.groupInfo:
          await _onGroupInfo(f.json);
        case FrameType.groupText:
          await _onGroupText(f.json);
        case FrameType.groupReceipt:
          await _onGroupReceipt(f.json);
        case FrameType.groupLeave:
          await _onGroupLeave(f.json);
      }
    } catch (_) {
      // Trame mal formée ou échec de stockage : on l'ignore,
      // la connexion reste ouverte.
    }
  }

  Future<void> _safeSend(Frame f) async {
    try {
      await session.send(f);
    } catch (_) {}
  }

  void _report(String id, double p) {
    final cb = onProgress;
    if (cb == null) return;
    if (p < 0 || p >= 1) {
      _steps.remove(id);
      cb(id, p < 0 ? -1 : 1);
      return;
    }
    final step = (p * 100).floor();
    if (_steps[id] == step) return;
    _steps[id] = step;
    cb(id, p);
  }

  // ---------- Présentation et messages texte ----------

  Future<void> _onHello(Map<String, dynamic> hello) async {
    if (remoteId != null) return;
    final id = hello['deviceId'] as String;
    final name = hello['name'] as String;
    if (id == identity.deviceId) return; // on ne se parle pas à soi-même

    final old = await store.contact(id);
    await store.upsertContact(Contact(
      deviceId: id,
      name: name,
      address: address ?? old?.address,
      lastSeen: DateTime.now(),
    ));
    remoteId = id;
    if (!_ready.isCompleted) _ready.complete(id);
    // Les groupes qu'on a en commun passent avant les messages : l'autre doit
    // connaître le groupe avant d'en recevoir un message.
    for (final g in await store.groups()) {
      if (g.active && g.hasMember(id) && g.hasMember(identity.deviceId)) {
        await _safeSend(Frame.json(FrameType.groupInfo, g.toJson()));
      }
    }
    await _flush(includeSent: true);
  }

  Future<void> _onText(Map<String, dynamic> json) async {
    final from = remoteId;
    if (from == null) return;
    final msg = ChatMessage(
      id: json['id'] as String,
      contactId: from,
      outgoing: false,
      text: json['text'] as String,
      // L'heure de réception sur CE téléphone : les horloges des deux
      // appareils ne sont jamais parfaitement d'accord.
      at: DateTime.now(),
      status: MessageStatus.received,
    );
    // Doublon possible (renvoi après une coupure) : ignoré par le stockage,
    // mais on confirme quand même, puisque le message est bien chez nous.
    final added = await store.addMessage(msg);
    await _safeSend(Frame.json(FrameType.ack, {'id': msg.id}));
    if (added) hub?.messageReceived(msg);
  }

  Future<void> _onAck(Map<String, dynamic> json) async {
    final id = json['id'] as String;
    // Un accusé reçu avant le début du transfert : le fichier est déjà chez lui.
    _awaitingAccept.remove(id)?.complete(-1);
    final m = await store.message(id);
    if (m != null && m.isGroupMessage) {
      // Message de groupe : on note que CE membre l'a reçu.
      final from = remoteId;
      if (from != null) {
        await store.setDelivery(id, from, DeliveryState.delivered);
      }
      return;
    }
    await store.setStatus(id, MessageStatus.delivered);
  }

  // ---------- Envoi ----------

  /// [includeSent] : à la connexion, on renvoie aussi ce qui a été envoyé sans
  /// accusé. Ensuite, on n'envoie que ce qui n'est pas encore parti.
  Future<void> _flush({required bool includeSent}) async {
    final to = remoteId;
    if (to == null) return;
    for (final m in await store.pendingFor(to)) {
      if (!includeSent && m.status != MessageStatus.pending) continue;
      if (m.isFile) {
        _startFile(m);
        continue;
      }
      try {
        await session.send(Frame.text(m.id, m.text, at: m.at));
      } catch (_) {
        return; // connexion perdue : on réessaiera à la prochaine rencontre
      }
      await store.setStatus(m.id, MessageStatus.sent);
    }

    // Groupes : nos propres messages, et ceux d'autres membres qu'on relaie,
    // tant que ce membre ne les a pas confirmés.
    for (final m in await store.pendingGroupFor(to)) {
      final state = await store.delivery(m.id, to);
      if (state == null || state == DeliveryState.delivered) continue;
      if (!includeSent && state != DeliveryState.pending) continue;
      final g = await store.group(m.contactId);
      if (g == null || !g.active || !g.hasMember(to)) continue;
      if (m.isFile) {
        // Un fichier de groupe part de son auteur, ou d'un membre qui l'a déjà
        // reçu en entier (relais).
        if (m.outgoing || m.status == MessageStatus.received) _startFile(m);
        continue;
      }
      final origin = m.senderId ?? identity.deviceId;
      try {
        await session.send(Frame.json(FrameType.groupText, {
          'gid': g.id,
          'id': m.id,
          'from': origin,
          'fname': m.senderName ?? g.nameOf(origin) ?? '',
          'text': m.text,
          'ts': m.at.millisecondsSinceEpoch,
        }));
      } catch (_) {
        return;
      }
      await store.setDelivery(m.id, to, DeliveryState.sent);
    }
  }

  /// Les petits fichiers (messages vocaux, petites images) partent tout de
  /// suite ; les gros attendent leur tour : un seul à la fois depuis ce
  /// téléphone, sinon la radio est saturée et les liaisons se coupent.
  static const int _smallFile = 256 * 1024;

  void _startFile(ChatMessage m) {
    if (_sendingFile || _closedFlag) return;
    final small = (m.fileSize ?? _smallFile + 1) <= _smallFile;
    var slot = false;
    if (!small) {
      if (!(hub?.acquireFileSlot(this) ?? true)) return;
      slot = hub != null;
    }
    _sendingFile = true;
    unawaited(_sendFile(m, slotHeld: slot));
  }

  /// Après un échec, on retente quelques secondes plus tard si la liaison
  /// tient toujours (le fichier reprend là où il s'était arrêté).
  void _scheduleRetry(String id) {
    if (_closedFlag) return;
    final n = (_fileRetries[id] ?? 0) + 1;
    _fileRetries[id] = n;
    if (n > 10) return;
    Timer(Duration(seconds: min(4 * n, 30)), () {
      if (!_closedFlag) unawaited(flush().catchError((_) {}));
    });
  }

  String _kindName(MessageKind k) => switch (k) {
    MessageKind.image => 'image',
    MessageKind.audio => 'audio',
    _ => 'file',
  };

  Future<void> _sendFile(ChatMessage m, {required bool slotHeld}) async {
    var ok = false;
    final peer = remoteId?.substring(0, 6) ?? '?';
    try {
      final path = m.filePath;
      if (path == null) return;
      final file = File(path);
      if (!await file.exists()) return; // fichier source disparu
      final size = await file.length();

      // L'empreinte du fichier entier, calculée une seule fois : elle permet
      // de vérifier le fichier même quand il arrive en plusieurs reprises.
      final sha = await (_fileHashes[m.id] ??= _hashFile(file));
      final tid = ++_tidCounter;
      _aborted.remove(m.id);

      // 1. On propose le fichier et on attend la réponse (avec, si une
      //    tentative précédente a été interrompue, l'endroit où reprendre).
      final accept = Completer<int>();
      _awaitingAccept[m.id] = accept;
      final origin = m.senderId ?? identity.deviceId;
      await session.send(Frame.json(FrameType.fileOffer, {
        'id': m.id,
        'tid': tid,
        'name': m.fileName ?? 'fichier',
        'size': size,
        'sha256': sha,
        'mime': m.mime,
        'kind': _kindName(m.kind),
        if (m.durationMs != null) 'dur': m.durationMs,
        if (m.isGroupMessage) 'gid': m.contactId,
        if (m.isGroupMessage) 'from': origin,
        if (m.isGroupMessage) 'fname': m.senderName ?? identity.name,
      }));
      final offset = await accept.future
          .timeout(const Duration(seconds: 20), onTimeout: () => -1);
      _awaitingAccept.remove(m.id);
      if (offset < 0) {
        Diagnostics.log('Envoi vers $peer : refusé ou sans réponse');
        return;
      }
      if (offset > size) {
        // Incohérence : on demande à l'autre de repartir de zéro.
        await _safeSend(Frame.json(FrameType.fileAbort,
            {'id': m.id, 'tid': tid, 'reason': 'restart'}));
        return;
      }
      Diagnostics.log(
        'Envoi vers $peer : ${m.fileName} ($size o), '
        '${offset > 0 ? 'reprise à $offset o' : 'depuis le début'}',
      );

      // 2. On envoie le fichier par blocs, à partir du décalage.
      var sent = offset;
      _report(m.id, size > 0 ? min(0.99, sent / size) : 0);
      await for (final piece in file.openRead(offset)) {
        final bytes = piece is Uint8List ? piece : Uint8List.fromList(piece);
        for (var i = 0; i < bytes.length; i += fileChunkSize) {
          if (_aborted.contains(m.id)) return;
          final end = min(i + fileChunkSize, bytes.length);
          final len = end - i;
          final payload = Uint8List(4 + len);
          ByteData.sublistView(payload).setUint32(0, tid);
          payload.setRange(4, 4 + len, bytes, i);
          await session.send(Frame(FrameType.fileChunk, payload));
          sent += len;
          if (size > 0) _report(m.id, min(0.99, sent / size));
        }
      }
      if (_aborted.contains(m.id)) return;

      // 3. On annonce la fin, avec l'empreinte pour vérification.
      await session.send(
          Frame.json(FrameType.fileEnd, {'tid': tid, 'sha256': sha}));
      final to = remoteId;
      if (m.isGroupMessage && to != null) {
        await store.setDelivery(m.id, to, DeliveryState.sent);
      } else {
        await store.setStatus(m.id, MessageStatus.sent);
      }
      _report(m.id, 1);
      ok = true;
      Diagnostics.log('Envoi vers $peer terminé : ${m.fileName}');
    } catch (e) {
      // Connexion perdue en route : on retentera, en reprenant où on s'était
      // arrêté.
      Diagnostics.log('Envoi vers $peer interrompu : $e');
      _fileHashes.remove(m.id);
    } finally {
      _awaitingAccept.remove(m.id);
      _sendingFile = false;
      if (slotHeld) hub?.releaseFileSlot(this);
      if (!ok) {
        _report(m.id, -1);
        _scheduleRetry(m.id);
      }
    }
    if (ok) {
      _fileRetries.remove(m.id);
      unawaited(flush().catchError((_) {}));
    }
  }

  // ---------- Réception ----------

  String _safeName(String raw) {
    var n = raw.split(RegExp(r'[\\/]')).last; // retire tout chemin
    n = n.replaceAll(RegExp(r'[<>:"|?*\x00-\x1f]'), '_').trim();
    while (n.startsWith('.')) {
      n = n.substring(1);
    }
    if (n.isEmpty) n = 'fichier';
    if (n.length > 80) n = n.substring(n.length - 80);
    return n;
  }

  Future<void> _refuse(String id, int tid, String reason) => _safeSend(
      Frame.json(FrameType.fileAbort, {'id': id, 'tid': tid, 'reason': reason}));

  Future<void> _onOffer(Map<String, dynamic> json) async {
    final from = remoteId;
    if (from == null) return;
    final id = json['id'] as String;
    final tid = json['tid'] as int;
    final size = json['size'] as int;
    final dir = filesDir;

    if (dir == null) return _refuse(id, tid, 'no_storage');
    if (!_validId.hasMatch(id) || size < 0 || size > maxFileSize) {
      return _refuse(id, tid, 'refused');
    }

    // Fichier de groupe : son auteur est un membre qui a le droit d'écrire, et
    // il peut nous arriver directement ou par un autre membre (relais).
    final gid = json['gid'] as String?;
    var conversation = from;
    String? senderId;
    String? senderName;
    if (gid != null) {
      final g = await store.group(gid);
      final origin = (json['from'] as String?) ?? from;
      if (g == null ||
          !g.active ||
          !g.hasMember(identity.deviceId) ||
          !g.hasMember(from) ||
          !g.hasMember(origin) ||
          !g.canPost(origin)) {
        return _refuse(id, tid, 'refused');
      }
      if (origin == identity.deviceId) {
        // Notre propre fichier qui nous revient par un relais.
        await _safeSend(Frame.json(FrameType.ack, {'id': id}));
        return;
      }
      conversation = gid;
      senderId = origin;
      senderName = g.nameOf(origin) ?? (json['fname'] as String?) ?? 'Membre';
    }

    final existing = await store.message(id);
    if (existing != null) {
      if (existing.outgoing) return _refuse(id, tid, 'refused');
      if (existing.status == MessageStatus.received) {
        // Déjà reçu en entier : on confirme sans retransférer.
        await _safeSend(Frame.json(FrameType.ack, {'id': id}));
        return;
      }
    }

    await _dropIncoming(); // un transfert précédent interrompu, sur cette liaison
    // Ce fichier arrive peut-être déjà par une autre liaison.
    if (hub != null && !hub!.beginReceiving(id)) {
      return _refuse(id, tid, 'busy');
    }

    final name = _safeName(json['name'] as String);
    final path =
        existing?.filePath ?? '${dir.path}${Platform.pathSeparator}${id}_$name';

    // Reprise : si une partie du fichier est déjà là, on continue à la suite.
    var offset = 0;
    if (existing != null) {
      final partial = File(path);
      if (await partial.exists()) {
        final len = await partial.length();
        if (len > 0 && len <= size) {
          offset = len;
        } else {
          try {
            await partial.delete();
          } catch (_) {}
        }
      }
    }

    final kindName = json['kind'];
    if (existing == null) {
      await store.addMessage(ChatMessage(
        id: id,
        contactId: conversation,
        outgoing: false,
        text: name,
        at: DateTime.now(),
        status: MessageStatus.receiving,
        kind: kindName == 'image'
            ? MessageKind.image
            : kindName == 'audio'
                ? MessageKind.audio
                : MessageKind.file,
        fileName: name,
        fileSize: size,
        filePath: path,
        mime: json['mime'] as String?,
        senderId: senderId,
        senderName: senderName,
        durationMs: json['dur'] as int?,
      ));
    }
    _incoming = _Incoming(
      tid: tid,
      messageId: id,
      path: path,
      size: size,
      offset: offset,
    );
    Diagnostics.log(
      'Réception de ${from.substring(0, 6)} : $name ($size o), '
      '${offset > 0 ? 'reprise à $offset o' : 'depuis le début'}',
    );
    _report(id, size > 0 ? offset / size : 0);
    await _safeSend(Frame.json(
        FrameType.fileAccept, {'id': id, 'tid': tid, 'offset': offset}));
  }

  void _onAccept(Map<String, dynamic> json) {
    final c = _awaitingAccept[json['id'] as String];
    if (c != null && !c.isCompleted) c.complete((json['offset'] as int?) ?? 0);
  }

  Future<void> _onChunk(Uint8List payload) async {
    final inc = _incoming;
    if (inc == null || payload.length < 4) return;
    final tid = ByteData.sublistView(payload, 0, 4).getUint32(0);
    if (tid != inc.tid) return;
    final data = Uint8List.sublistView(payload, 4);
    inc.received += data.length;
    if (inc.received > inc.size) {
      await _abortIncoming(inc, 'too_big');
      return;
    }
    inc.sink.add(data);
    if (inc.size > 0) _report(inc.messageId, min(0.99, inc.received / inc.size));
  }

  Future<void> _onEnd(Map<String, dynamic> json) async {
    final inc = _incoming;
    if (inc == null || json['tid'] != inc.tid) return;
    _incoming = null;

    String? failure;
    try {
      await inc.sink.flush();
      await inc.sink.close();
    } catch (_) {
      failure = 'io';
    }
    if (failure == null && inc.received != inc.size) failure = 'checksum';
    if (failure == null) {
      // Le fichier peut être arrivé en plusieurs reprises : on vérifie le
      // fichier entier tel qu'il est sur le disque.
      try {
        if (await _hashFile(File(inc.path)) != json['sha256']) {
          failure = 'checksum';
        }
      } catch (_) {
        failure = 'io';
      }
    }
    hub?.endReceiving(inc.messageId);

    if (failure != null) {
      Diagnostics.log('Réception ${inc.messageId.substring(0, 6)} : échec ($failure)');
      try {
        await File(inc.path).delete();
      } catch (_) {}
      _report(inc.messageId, -1);
      await _refuse(inc.messageId, inc.tid, failure);
      return;
    }
    await store.setIncomingState(inc.messageId, MessageStatus.received,
        filePath: inc.path);
    _report(inc.messageId, 1);
    Diagnostics.log('Réception terminée : ${inc.path.split(Platform.pathSeparator).last}');
    await _safeSend(Frame.json(FrameType.ack, {'id': inc.messageId}));
    final done = await store.message(inc.messageId);
    if (done == null) return;
    if (done.isGroupMessage) {
      // On garde le fichier pour le faire suivre aux membres qui ne l'ont pas.
      final g = await store.group(done.contactId);
      final from = remoteId;
      if (g != null && g.active && from != null) {
        await _relayGroupMessage(done, g, from);
      }
    }
    hub?.messageReceived(done);
  }

  Future<void> _onAbort(Map<String, dynamic> json) async {
    final id = json['id'] as String;
    Diagnostics.log('Transfert $id : abandon (${json['reason']})'.replaceFirst(id, id.substring(0, 6)));
    // Côté expéditeur : l'autre refuse ou a échoué.
    _aborted.add(id);
    _awaitingAccept.remove(id)?.complete(-1);
    // Côté destinataire : l'expéditeur annule.
    final inc = _incoming;
    if (inc != null && inc.messageId == id) {
      await _dropIncoming();
      if (json['reason'] == 'restart') {
        try {
          await File(inc.path).delete();
        } catch (_) {}
      }
    }
  }

  Future<void> _abortIncoming(_Incoming inc, String reason) async {
    _incoming = null;
    hub?.endReceiving(inc.messageId);
    try {
      await inc.sink.close();
    } catch (_) {}
    try {
      await File(inc.path).delete();
    } catch (_) {}
    _report(inc.messageId, -1);
    await _refuse(inc.messageId, inc.tid, reason);
  }

  /// Fait suivre un message de groupe qu'on vient de recevoir (texte ou
  /// fichier) aux membres qui ne l'ont pas encore, et prévient tout le monde
  /// qu'on l'a, pour que l'auteur finisse par le savoir.
  Future<void> _relayGroupMessage(ChatMessage msg, Group g, String from) async {
    final me = identity.deviceId;
    final origin = msg.senderId ?? from;
    await store.addDeliveries(
      msg.id,
      g.members.map((m) => m.deviceId).where((d) => d != me && d != origin),
    );
    if (from != origin) {
      await store.setDelivery(msg.id, from, DeliveryState.delivered);
    }
    final receipt = Frame.json(FrameType.groupReceipt, {
      'gid': g.id,
      'id': msg.id,
      'by': me,
    });
    hub?.firstTimeSeen('${msg.id}:$me');
    _sendToMembers(g, receipt);
    _flushOthers();
  }

  // ---------- Groupes ----------

  /// Envoie une trame sans jamais lever d'erreur (utile depuis l'application).
  Future<void> sendFrame(Frame f) => _safeSend(f);

  /// Envoie la description d'un groupe à l'autre.
  Future<void> sendGroupInfo(Group g) =>
      _safeSend(Frame.json(FrameType.groupInfo, g.toJson()));

  /// Envoie une trame à toutes les connexions dont l'autre est membre de [g].
  void _sendToMembers(Group g, Frame f, {ChatLink? except}) {
    final h = hub;
    if (h == null) return;
    for (final l in h.links) {
      if (identical(l, except)) continue;
      final id = l.remoteId;
      if (id != null && g.hasMember(id)) unawaited(l._safeSend(f));
    }
  }

  /// Fait partir ce qui attend sur les autres connexions (relais).
  void _flushOthers() {
    final h = hub;
    if (h == null) return;
    for (final l in h.links) {
      if (identical(l, this) || l.remoteId == null) continue;
      unawaited(l.flush().catchError((_) {}));
    }
  }

  Future<void> _onGroupInfo(Map<String, dynamic> json) async {
    if (remoteId == null) return;
    final incoming = Group.fromJson(json);
    final me = identity.deviceId;
    final existing = await store.group(incoming.id);
    final by = incoming.editedBy ?? incoming.creatorId;

    if (existing != null) {
      // Seul le créateur qui l'a fondé garde la main sur ce groupe.
      if (existing.creatorId != incoming.creatorId) return;
      // Seuls le créateur et les administrateurs (selon la version qu'on
      // connaît) peuvent publier une modification.
      if (!existing.isAdmin(by)) return;
      if (incoming.version < existing.version) return;
      if (incoming.version == existing.version) {
        // Deux administrateurs ont modifié en même temps : le plus grand
        // identifiant l'emporte, mais seulement si le contenu diffère.
        final current = existing.editedBy ?? existing.creatorId;
        if (incoming.sameContent(existing) || by.compareTo(current) <= 0) {
          return;
        }
      }
      // Quelqu'un qui a quitté le groupe n'y revient pas sur une copie
      // périmée : il faut d'abord supprimer le groupe de son téléphone.
      if (!existing.active && !existing.closed && existing.hasMember(me)) {
        return;
      }
    } else if (!incoming.isAdmin(by)) {
      return;
    }

    if (!incoming.hasMember(me)) {
      // Une version plus récente ne nous compte plus : on a été retiré.
      if (existing != null && existing.active) {
        await store.saveGroup(incoming.copyWith(active: false));
        hub?.membershipChanged();
      }
      return;
    }
    // Groupe supprimé par le créateur : l'historique reste, plus rien ne passe.
    await store.saveGroup(
      incoming.closed ? incoming.copyWith(active: false) : incoming,
    );
    // On fait suivre aux autres membres connectés (une seule fois : seule une
    // version plus récente est acceptée).
    _sendToMembers(incoming, Frame.json(FrameType.groupInfo, json),
        except: this);
    hub?.membershipChanged();
  }

  Future<void> _onGroupText(Map<String, dynamic> json) async {
    final from = remoteId;
    if (from == null) return;
    final gid = json['gid'] as String;
    final id = json['id'] as String;
    final origin = json['from'] as String;
    final text = json['text'] as String;
    if (!_validId.hasMatch(id)) return;

    final g = await store.group(gid);
    final me = identity.deviceId;
    if (g == null ||
        !g.active ||
        !g.hasMember(me) ||
        !g.hasMember(from) ||
        !g.hasMember(origin)) {
      return; // pas de confirmation : l'expéditeur réessaiera plus tard
    }
    if (origin == me) {
      // Notre propre message qui nous revient par un relais.
      await _safeSend(Frame.json(FrameType.ack, {'id': id}));
      return;
    }
    if (!g.canPost(origin)) {
      // Mode annonces : seul un administrateur peut écrire. On confirme pour
      // que l'expéditeur arrête de réessayer, sans garder le message.
      await _safeSend(Frame.json(FrameType.ack, {'id': id}));
      return;
    }

    final msg = ChatMessage(
      id: id,
      contactId: gid,
      outgoing: false,
      text: text,
      at: DateTime.now(),
      status: MessageStatus.received,
      senderId: origin,
      senderName: g.nameOf(origin) ?? (json['fname'] as String? ?? ''),
    );
    final added = await store.addMessage(msg);
    // Confirmation au voisin qui nous l'a remis (même si on l'avait déjà).
    await _safeSend(Frame.json(FrameType.ack, {'id': id}));
    if (!added) return;

    await _relayGroupMessage(msg, g, from);
    hub?.messageReceived(msg);
  }

  Future<void> _onGroupReceipt(Map<String, dynamic> json) async {
    final gid = json['gid'] as String;
    final id = json['id'] as String;
    final by = json['by'] as String;
    final m = await store.message(id);
    if (m == null || m.contactId != gid || !m.isGroupMessage) return;
    if (by == identity.deviceId) return;

    await store.setDelivery(id, by, DeliveryState.delivered);
    if (m.outgoing && m.senderId == identity.deviceId) return; // jusqu'à nous
    // Un relais : on fait suivre, une seule fois.
    if (hub?.firstTimeSeen('$id:$by') != true) return;
    final g = await store.group(gid);
    if (g == null) return;
    _sendToMembers(g, Frame.json(FrameType.groupReceipt, json), except: this);
  }

  Future<void> _onGroupLeave(Map<String, dynamic> json) async {
    if (remoteId == null) return;
    final gid = json['gid'] as String;
    final who = json['who'] as String;
    final g = await store.group(gid);
    if (g == null || !g.active || !g.hasMember(who)) return;
    if (who == g.creatorId || who == identity.deviceId) return;
    final rest = g.members.where((m) => m.deviceId != who).toList();
    if (g.isAdmin(identity.deviceId)) {
      // Le créateur ou un administrateur officialise le départ.
      final next = editedGroup(g, by: identity.deviceId, members: rest);
      await store.saveGroup(next);
      for (final l in hub?.links ?? const <ChatLink>[]) {
        final id = l.remoteId;
        if (id != null && (next.hasMember(id) || id == who)) {
          unawaited(l.sendGroupInfo(next));
        }
      }
    } else {
      // Les autres retirent simplement le membre de leur copie et font suivre.
      await store.saveGroup(g.copyWith(members: rest));
      _sendToMembers(g, Frame.json(FrameType.groupLeave, json), except: this);
    }
    hub?.membershipChanged();
  }

  Future<void> _dropIncoming() async {
    final inc = _incoming;
    _incoming = null;
    if (inc == null) return;
    hub?.endReceiving(inc.messageId);
    _report(inc.messageId, -1);
    try {
      await inc.sink.close();
    } catch (_) {}
  }
}