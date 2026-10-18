import 'dart:math';
import 'dart:typed_data';

import 'package:bluetalk/protocol/frame.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List concat(List<Uint8List> parts) =>
    Uint8List.fromList([for (final p in parts) ...p]);

void main() {
  test('aller-retour d\'un message texte libre', () {
    const texte = 'Bonjour professeur 👋 éàç <test> {"a":1}';
    final out = FrameDecoder().feed(encodeFrame(Frame.text('m1', texte)));
    expect(out, hasLength(1));
    expect(out.first.type, FrameType.text);
    expect(out.first.json['text'], texte);
    expect(out.first.json['id'], 'm1');
  });

  test('trame sans contenu (PING)', () {
    final bytes = encodeFrame(Frame(FrameType.ping, Uint8List(0)));
    expect(bytes.length, headerSize);
    final out = FrameDecoder().feed(bytes);
    expect(out.single.type, FrameType.ping);
    expect(out.single.payload, isEmpty);
  });

  test('plusieurs trames dans un seul morceau', () {
    final data = concat([
      encodeFrame(Frame.text('1', 'a')),
      encodeFrame(Frame.text('2', 'b')),
      encodeFrame(Frame(FrameType.pong, Uint8List(0))),
    ]);
    final out = FrameDecoder().feed(data);
    expect(out.map((f) => f.type),
        [FrameType.text, FrameType.text, FrameType.pong]);
  });

  test('octets reçus un par un', () {
    final data = concat([
      encodeFrame(Frame.text('1', 'bonjour')),
      encodeFrame(Frame.text('2', 'réponse')),
    ]);
    final decoder = FrameDecoder();
    final got = <Frame>[];
    for (final b in data) {
      got.addAll(decoder.feed([b]));
    }
    expect(got.map((f) => f.json['text']), ['bonjour', 'réponse']);
  });

  test('découpage aléatoire de trames de tailles variées', () {
    final rnd = Random(7);
    final sent = <Frame>[
      for (var i = 0; i < 60; i++)
        Frame(FrameType.raw,
            Uint8List.fromList(List.generate(rnd.nextInt(5000), (_) => rnd.nextInt(256))))
    ];
    final data = concat(sent.map(encodeFrame).toList());

    final decoder = FrameDecoder();
    final got = <Frame>[];
    var pos = 0;
    while (pos < data.length) {
      final n = min(1 + rnd.nextInt(700), data.length - pos);
      got.addAll(decoder.feed(data.sublist(pos, pos + n)));
      pos += n;
    }

    expect(got, hasLength(sent.length));
    for (var i = 0; i < sent.length; i++) {
      expect(got[i].type, sent[i].type);
      expect(got[i].payload, orderedEquals(sent[i].payload));
    }
  });

  test('un type inconnu est transmis sans erreur', () {
    final out = FrameDecoder()
        .feed(encodeFrame(Frame(200, Uint8List.fromList([1, 2, 3]))));
    expect(out.single.type, 200);
    expect(out.single.payload, [1, 2, 3]);
  });

  test('longueur absurde refusée', () {
    final bad = Uint8List.fromList([protocolVersion, 2, 0x7F, 0xFF, 0xFF, 0xFF]);
    expect(() => FrameDecoder().feed(bad), throwsA(isA<ProtocolException>()));
  });

  test('version inconnue refusée', () {
    final bad = Uint8List.fromList([9, 2, 0, 0, 0, 0]);
    expect(() => FrameDecoder().feed(bad), throwsA(isA<ProtocolException>()));
  });
}