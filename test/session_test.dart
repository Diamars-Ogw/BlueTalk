import 'dart:async';
import 'dart:typed_data';

import 'package:bluetalk/protocol/frame.dart';
import 'package:bluetalk/protocol/memory_transport.dart';
import 'package:bluetalk/protocol/session.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Session a;
  late Session b;

  setUp(() {
    final (ta, tb) = createMemoryPair(seed: 3, maxChunk: 5);
    a = Session(ta);
    b = Session(tb);
  });

  tearDown(() async {
    await a.close();
    await b.close();
  });

  test('PING / PONG', () async {
    final delai = await a.ping();
    expect(delai, isA<Duration>());
  });

  test('message texte livré, avec accusé de réception', () async {
    final recu = b.texts.first;
    await a.sendText('m1', 'Bonjour professeur 👋');
    final msg = await recu;
    expect(msg['id'], 'm1');
    expect(msg['text'], 'Bonjour professeur 👋');
  });

  test('conversation dans les deux sens', () async {
    final reponse = a.texts.first;
    b.texts.listen((m) => unawaited(
        b.sendText('r1', 'Reçu : ${m['text']}').catchError((_) {})));
    await a.sendText('m1', 'Question ?');
    expect((await reponse)['text'], 'Reçu : Question ?');
  });

  test('présentation HELLO', () async {
    await a.sendHello(deviceId: 'dev-a', name: 'Professeur');
    final hello = await b.remoteHello;
    expect(hello['name'], 'Professeur');
    expect(hello['deviceId'], 'dev-a');
  });

  test('trames inconnues et octets bruts visibles dans frames', () async {
    final recues = b.frames.take(2).toList();
    await a.send(Frame(200, Uint8List.fromList([1, 2, 3])));
    await a.send(Frame.raw([9, 8, 7]));
    final frames = await recues;
    expect(frames[0].type, 200);
    expect(frames[1].payload, [9, 8, 7]);
  });

  test('50 messages envoyés en parallèle arrivent intacts', () async {
    final recus = <String>[];
    b.texts.listen((m) => recus.add(m['text'] as String));
    final envoyes = [for (var i = 0; i < 50; i++) 'message $i é👋'];
    await Future.wait([
      for (var i = 0; i < 50; i++) a.sendText('id$i', envoyes[i]),
    ]);
    expect(recus, hasLength(50));
    expect(recus.toSet(), envoyes.toSet());
  });

  test('la fermeture d\'un côté est vue par l\'autre', () async {
    await a.close();
    await b.done.timeout(const Duration(seconds: 2));
  });
}