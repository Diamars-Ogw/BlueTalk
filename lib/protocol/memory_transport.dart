import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'transport.dart';

class _MemoryEnd implements Transport {
  _MemoryEnd(this._rnd, this._maxChunk);

  final Random _rnd;
  final int _maxChunk;
  final StreamController<Uint8List> _in = StreamController<Uint8List>();
  late final _MemoryEnd _peer;
  Future<void> _tail = Future<void>.value();
  bool _closed = false;

  @override
  Stream<Uint8List> get incoming => _in.stream;

  @override
  Future<void> send(Uint8List bytes) {
    if (_closed) return Future<void>.error(StateError('Canal fermé'));
    // Les écritures sont mises en file : comme sur un vrai flux Bluetooth,
    // deux envois simultanés ne s'entrecroisent pas.
    final run = _tail.then((_) => _write(bytes));
    _tail = run.catchError((_) {});
    return run;
  }

  Future<void> _write(Uint8List bytes) async {
    var pos = 0;
    while (pos < bytes.length) {
      // Le récepteur reçoit des morceaux de taille aléatoire, comme avec
      // le Bluetooth : le décodeur doit s'en accommoder.
      final n = min(1 + _rnd.nextInt(_maxChunk), bytes.length - pos);
      final chunk = Uint8List.fromList(bytes.sublist(pos, pos + n));
      pos += n;
      await Future<void>.delayed(Duration.zero);
      if (_closed || _peer._in.isClosed) return;
      _peer._in.add(chunk);
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    if (!_peer._in.isClosed) unawaited(_peer._in.close());
    if (!_in.isClosed) unawaited(_in.close());
  }
}

/// Crée deux extrémités reliées : ce qu'on envoie sur l'une arrive sur
/// l'autre, découpé en morceaux de 1 à [maxChunk] octets.
(Transport, Transport) createMemoryPair({int seed = 1, int maxChunk = 7}) {
  final rnd = Random(seed);
  final a = _MemoryEnd(rnd, maxChunk);
  final b = _MemoryEnd(rnd, maxChunk);
  a._peer = b;
  b._peer = a;
  return (a, b);
}