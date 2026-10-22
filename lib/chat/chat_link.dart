import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../protocol/frame.dart';
import '../protocol/session.dart';
import '../protocol/transport.dart';
import 'chat_store.dart';
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
  }) : sink = File(path).openWrite();

  final int tid;
  final String messageId;
  final String path;
  final int size;
  final IOSink sink;
  final _Hasher hash = _Hasher();
  int received = 0;
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
  }) : session = Session(transport, autoAck: false) {
    _ready.future.ignore();
    _sub = session.frames.listen((f) => _enqueue(() => _handle(f)).ignore());
    unawaited(session.done.then((_) => _onClosed()));
    session
        .sendHello(deviceId: identity.deviceId, name: identity.name)
        .catchError((_) {});
  }

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
  int _tidCounter = 0;
  final Map<String, Completer<bool>> _awaitingAccept = {};
  final Set<String> _aborted = {};
  final Map<String, int> _steps = {};

  /// Se termine quand l'autre s'est présenté (et vaut son identifiant).
  Future<String> get ready => _ready.future;

  /// Se termine quand la connexion est fermée.
  Future<void> get closed => session.done;

  Future<void> close() => session.close();

  /// À appeler après avoir écrit un message : tente de l'envoyer maintenant.
  Future<void> flush() => _enqueue(() => _flush(includeSent: false));

  // Les traitements se font un par un, dans l'ordre d'arrivée.
  Future<void> _enqueue(Future<void> Function() job) {
    final run = _queue.then((_) => job());
    _queue = run.catchError((_) {});
    return run;
  }

  void _onClosed() {
    if (!_ready.isCompleted) {
      _ready
          .completeError(StateError('Connexion fermée avant la présentation'));
    }
    for (final c in _awaitingAccept.values) {
      if (!c.isCompleted) c.complete(false);
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
    await store.addMessage(msg);
    await _safeSend(Frame.json(FrameType.ack, {'id': msg.id}));
  }

  Future<void> _onAck(Map<String, dynamic> json) async {
    final id = json['id'] as String;
    // Un accusé reçu avant le début du transfert : le fichier est déjà chez lui.
    _awaitingAccept.remove(id)?.complete(false);
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
        // Un seul fichier à la fois, en parallèle de la file de traitement.
        if (!_sendingFile) {
          _sendingFile = true;
          unawaited(_sendFile(m));
        }
        continue;
      }
      try {
        await session.send(Frame.text(m.id, m.text, at: m.at));
      } catch (_) {
        return; // connexion perdue : on réessaiera à la prochaine rencontre
      }
      await store.setStatus(m.id, MessageStatus.sent);
    }
  }

  Future<void> _sendFile(ChatMessage m) async {
    var ok = false;
    try {
      final path = m.filePath;
      if (path == null) return;
      final file = File(path);
      if (!await file.exists()) return; // fichier source disparu
      final size = await file.length();
      final tid = ++_tidCounter;
      _aborted.remove(m.id);

      // 1. On propose le fichier et on attend la réponse.
      final accept = Completer<bool>();
      _awaitingAccept[m.id] = accept;
      await session.send(Frame.json(FrameType.fileOffer, {
        'id': m.id,
        'tid': tid,
        'name': m.fileName ?? 'fichier',
        'size': size,
        'mime': m.mime,
        'kind': m.kind == MessageKind.image ? 'image' : 'file',
      }));
      final go = await accept.future
          .timeout(const Duration(seconds: 20), onTimeout: () => false);
      _awaitingAccept.remove(m.id);
      if (!go) return;

      // 2. On envoie le fichier par blocs.
      final hash = _Hasher();
      var sent = 0;
      _report(m.id, 0);
      await for (final piece in file.openRead()) {
        final bytes = piece is Uint8List ? piece : Uint8List.fromList(piece);
        for (var i = 0; i < bytes.length; i += fileChunkSize) {
          if (_aborted.contains(m.id)) return;
          final end = min(i + fileChunkSize, bytes.length);
          final len = end - i;
          final payload = Uint8List(4 + len);
          ByteData.sublistView(payload).setUint32(0, tid);
          payload.setRange(4, 4 + len, bytes, i);
          hash.add(Uint8List.sublistView(bytes, i, end));
          await session.send(Frame(FrameType.fileChunk, payload));
          sent += len;
          if (size > 0) _report(m.id, min(0.99, sent / size));
        }
      }
      if (_aborted.contains(m.id)) return;

      // 3. On annonce la fin, avec l'empreinte pour vérification.
      await session.send(Frame.json(
          FrameType.fileEnd, {'tid': tid, 'sha256': hash.finish()}));
      await store.setStatus(m.id, MessageStatus.sent);
      _report(m.id, 1);
      ok = true;
    } catch (_) {
      // Connexion perdue en route : le fichier repartira à la prochaine
      // rencontre, depuis le début.
    } finally {
      _awaitingAccept.remove(m.id);
      _sendingFile = false;
      if (!ok) _report(m.id, -1);
    }
    if (ok) unawaited(flush().catchError((_) {}));
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

    final existing = await store.message(id);
    if (existing != null) {
      if (existing.outgoing) return _refuse(id, tid, 'refused');
      if (existing.status == MessageStatus.received) {
        // Déjà reçu en entier : on confirme sans retransférer.
        await _safeSend(Frame.json(FrameType.ack, {'id': id}));
        return;
      }
    }

    await _dropIncoming(); // un transfert précédent interrompu
    final name = _safeName(json['name'] as String);
    final path = '${dir.path}${Platform.pathSeparator}${id}_$name';
    if (existing == null) {
      await store.addMessage(ChatMessage(
        id: id,
        contactId: from,
        outgoing: false,
        text: name,
        at: DateTime.now(),
        status: MessageStatus.receiving,
        kind: json['kind'] == 'image' ? MessageKind.image : MessageKind.file,
        fileName: name,
        fileSize: size,
        filePath: path,
        mime: json['mime'] as String?,
      ));
    }
    _incoming = _Incoming(tid: tid, messageId: id, path: path, size: size);
    _report(id, 0);
    await _safeSend(Frame.json(FrameType.fileAccept, {'id': id, 'tid': tid}));
  }

  void _onAccept(Map<String, dynamic> json) {
    _awaitingAccept[json['id'] as String]?.complete(true);
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
    inc.hash.add(data);
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
    final digest = inc.hash.finish();
    if (failure == null &&
        (inc.received != inc.size || digest != json['sha256'])) {
      failure = 'checksum';
    }

    if (failure != null) {
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
    await _safeSend(Frame.json(FrameType.ack, {'id': inc.messageId}));
  }

  Future<void> _onAbort(Map<String, dynamic> json) async {
    final id = json['id'] as String;
    // Côté expéditeur : l'autre refuse ou a échoué.
    _aborted.add(id);
    _awaitingAccept.remove(id)?.complete(false);
    // Côté destinataire : l'expéditeur annule.
    final inc = _incoming;
    if (inc != null && inc.messageId == id) await _dropIncoming();
  }

  Future<void> _abortIncoming(_Incoming inc, String reason) async {
    _incoming = null;
    try {
      await inc.sink.close();
    } catch (_) {}
    try {
      await File(inc.path).delete();
    } catch (_) {}
    _report(inc.messageId, -1);
    await _refuse(inc.messageId, inc.tid, reason);
  }

  Future<void> _dropIncoming() async {
    final inc = _incoming;
    _incoming = null;
    if (inc == null) return;
    _report(inc.messageId, -1);
    try {
      await inc.sink.close();
    } catch (_) {}
  }
}