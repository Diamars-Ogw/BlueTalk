import 'dart:async';
import 'dart:typed_data';

import 'frame.dart';
import 'transport.dart';

/// Une conversation entre deux appareils, par-dessus un [Transport].
/// Elle répond seule aux PING, accuse réception des textes et attend les
/// accusés de ses propres messages.
class Session {
  Session(this._transport) {
    _remoteHello.future.ignore();
    _sub = _transport.incoming.listen(
      _onData,
      onDone: _onDone,
      onError: (Object _) => _onDone(),
    );
  }

  final Transport _transport;
  final FrameDecoder _decoder = FrameDecoder();
  late final StreamSubscription<Uint8List> _sub;

  final _frames = StreamController<Frame>.broadcast();
  final _texts = StreamController<Map<String, dynamic>>.broadcast();
  final _pendingAcks = <String, Completer<void>>{};
  final _pongWaiters = <Completer<void>>[];
  final _remoteHello = Completer<Map<String, dynamic>>();
  final _done = Completer<void>();
  bool _closed = false;

  /// Erreur de protocole ayant provoqué la fermeture, le cas échéant.
  Object? error;

  /// Toutes les trames reçues, y compris les types inconnus et les octets
  /// bruts. C'est ce qu'affichera le mode test.
  Stream<Frame> get frames => _frames.stream;

  /// Les messages texte reçus (contenu JSON : id, text, ts).
  Stream<Map<String, dynamic>> get texts => _texts.stream;

  /// La présentation (HELLO) de l'autre appareil.
  Future<Map<String, dynamic>> get remoteHello => _remoteHello.future;

  /// Se termine quand la session est fermée, par nous ou par l'autre.
  Future<void> get done => _done.future;

  Future<void> send(Frame frame) {
    if (_closed) return Future<void>.error(StateError('Session fermée'));
    return _transport.send(encodeFrame(frame));
  }

  Future<void> sendHello({required String deviceId, required String name}) =>
      send(Frame.json(FrameType.hello, {
        'deviceId': deviceId,
        'name': name,
        'protocol': protocolVersion,
      }));

  /// Envoie un texte et attend l'accusé de réception de l'autre appareil.
  /// Si l'accusé n'arrive pas à temps, lève une [TimeoutException].
  Future<void> sendText(String id, String text,
      {Duration timeout = const Duration(seconds: 5)}) async {
    final c = Completer<void>();
    c.future.ignore();
    _pendingAcks[id] = c;
    try {
      await send(Frame.text(id, text));
      await c.future.timeout(timeout);
    } finally {
      _pendingAcks.remove(id);
    }
  }

  /// Envoie un PING et renvoie le temps mis pour recevoir le PONG.
  Future<Duration> ping(
      {Duration timeout = const Duration(seconds: 5)}) async {
    final c = Completer<void>();
    c.future.ignore();
    _pongWaiters.add(c);
    final sw = Stopwatch()..start();
    try {
      await send(Frame(FrameType.ping, Uint8List(0)));
      await c.future.timeout(timeout);
    } finally {
      _pongWaiters.remove(c);
    }
    return sw.elapsed;
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    for (final c in _pendingAcks.values) {
      if (!c.isCompleted) c.completeError(StateError('Session fermée'));
    }
    _pendingAcks.clear();
    for (final c in _pongWaiters) {
      if (!c.isCompleted) c.completeError(StateError('Session fermée'));
    }
    _pongWaiters.clear();
    if (!_remoteHello.isCompleted) {
      _remoteHello.completeError(StateError('Session fermée'));
    }
    await _sub.cancel();
    await _transport.close();
    unawaited(_frames.close());
    unawaited(_texts.close());
    if (!_done.isCompleted) _done.complete();
  }

  void _onDone() => unawaited(close());

  void _onData(Uint8List data) {
    final List<Frame> received;
    try {
      received = _decoder.feed(data);
    } on ProtocolException catch (e) {
      // Flux invalide : on ne sait plus où commence la trame suivante.
      error = e;
      unawaited(close());
      return;
    }
    for (final frame in received) {
      _dispatch(frame);
    }
  }

  void _dispatch(Frame f) {
    if (!_frames.isClosed) _frames.add(f);
    try {
      switch (f.type) {
        case FrameType.hello:
          {
            if (!_remoteHello.isCompleted) _remoteHello.complete(f.json);
          }
        case FrameType.text:
          {
            final data = f.json;
            if (!_texts.isClosed) _texts.add(data);
            unawaited(_safeSend(Frame.json(FrameType.ack, {'id': data['id']})));
          }
        case FrameType.ack:
          {
            _pendingAcks.remove(f.json['id'])?.complete();
          }
        case FrameType.ping:
          {
            unawaited(_safeSend(Frame(FrameType.pong, Uint8List(0))));
          }
        case FrameType.pong:
          {
            if (_pongWaiters.isNotEmpty) _pongWaiters.removeAt(0).complete();
          }
      }
    } on FormatException {
      // Contenu JSON invalide : on ignore cette trame, la connexion reste ouverte.
    } on TypeError {
      // Contenu JSON de forme inattendue : même traitement.
    }
  }

  Future<void> _safeSend(Frame f) async {
    try {
      await send(f);
    } catch (_) {
      // Connexion déjà coupée : rien à faire.
    }
  }
}