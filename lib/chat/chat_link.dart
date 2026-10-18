import 'dart:async';

import '../protocol/frame.dart';
import '../protocol/session.dart';
import '../protocol/transport.dart';
import 'chat_store.dart';
import 'models.dart';

/// Une connexion avec un contact. À l'ouverture : on se présente, on
/// enregistre l'autre comme contact, puis on envoie ce qui attendait.
class ChatLink {
  ChatLink({
    required Transport transport,
    required this.store,
    required this.identity,
    this.address,
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
  void _onClosed() {
    if (!_ready.isCompleted) {
      _ready.completeError(
        StateError('Connexion fermée avant la présentation'),
      );
    }
    unawaited(_sub.cancel());
  }

  /// Identifiant du contact, connu après sa présentation.
  String? remoteId;

  final Completer<String> _ready = Completer<String>();
  late final StreamSubscription<Frame> _sub;
  Future<void> _queue = Future<void>.value();

  /// Se termine quand l'autre s'est présenté (et vaut son identifiant).
  Future<String> get ready => _ready.future;

  /// Se termine quand la connexion est fermée.
  Future<void> get closed => session.done;

  Future<void> close() => session.close();

  /// À appeler après avoir écrit un message : tente de l'envoyer maintenant.
  Future<void> flush() => _enqueue(_flush);

  // Les traitements se font un par un, dans l'ordre d'arrivée.
  Future<void> _enqueue(Future<void> Function() job) {
    final run = _queue.then((_) => job());
    _queue = run.catchError((_) {});
    return run;
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
      }
    } catch (_) {
      // Trame mal formée ou échec de stockage : on l'ignore,
      // la connexion reste ouverte.
    }
  }

  Future<void> _onHello(Map<String, dynamic> hello) async {
    if (remoteId != null) return;
    final id = hello['deviceId'] as String;
    final name = hello['name'] as String;
    if (id == identity.deviceId) return; // on ne se parle pas à soi-même

    final old = await store.contact(id);
    await store.upsertContact(
      Contact(
        deviceId: id,
        name: name,
        address: address ?? old?.address,
        lastSeen: DateTime.now(),
      ),
    );
    remoteId = id;
    if (!_ready.isCompleted) _ready.complete(id);
    await _flush();
  }

  Future<void> _onText(Map<String, dynamic> json) async {
    final from = remoteId;
    if (from == null) return;
    final msg = ChatMessage(
      id: json['id'] as String,
      contactId: from,
      outgoing: false,
      text: json['text'] as String,
      at: DateTime.fromMillisecondsSinceEpoch(json['ts'] as int),
      status: MessageStatus.received,
    );
    // Doublon possible (renvoi après une coupure) : ignoré par le stockage,
    // mais on confirme quand même, puisque le message est bien chez nous.
    await store.addMessage(msg);
    try {
      await session.send(Frame.json(FrameType.ack, {'id': msg.id}));
    } catch (_) {}
  }

  Future<void> _onAck(Map<String, dynamic> json) async {
    await store.setStatus(json['id'] as String, MessageStatus.delivered);
  }

  Future<void> _flush() async {
    final to = remoteId;
    if (to == null) return;
    for (final m in await store.pendingFor(to)) {
      try {
        await session.send(Frame.text(m.id, m.text, at: m.at));
      } catch (_) {
        return; // connexion perdue : on réessaiera à la prochaine rencontre
      }
      await store.setStatus(m.id, MessageStatus.sent);
    }
  }
}
