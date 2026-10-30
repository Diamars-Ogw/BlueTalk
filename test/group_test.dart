import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:bluetalk/chat/chat_link.dart';
import 'package:bluetalk/chat/chat_store.dart';
import 'package:bluetalk/chat/group_ops.dart';
import 'package:bluetalk/chat/models.dart';
import 'package:bluetalk/protocol/frame.dart';
import 'package:bluetalk/protocol/memory_transport.dart';
import 'package:bluetalk/protocol/transport.dart';
import 'package:flutter_test/flutter_test.dart';

/// Un téléphone simulé : son stockage, son identité et ses connexions.
class Node implements LinkHub {
  Node(String name)
    : store = MemoryChatStore(),
      identity = Identity.create(name),
      dir = Directory.systemTemp.createTempSync('bluetalk_group_');

  final MemoryChatStore store;
  final Identity identity;
  final Directory dir;
  final List<ChatLink> _links = [];
  final Set<String> _seen = {};
  final List<ChatMessage> notified = [];

  String get id => identity.deviceId;

  @override
  Iterable<ChatLink> get links => _links;

  @override
  bool firstTimeSeen(String key) => _seen.add(key);

  @override
  void messageReceived(ChatMessage message) => notified.add(message);

  @override
  void membershipChanged() {}

  // Envoi d'un seul gros fichier à la fois, comme dans l'application.
  int activeSends = 0;
  int maxActiveSends = 0;
  final Set<ChatLink> _slotHolders = {};
  final Set<String> _receiving = {};
  bool busyFlag = false;

  @override
  bool get transferring => busyFlag || _links.any((l) => l.busy);

  @override
  bool acquireFileSlot(ChatLink link) {
    if (_slotHolders.isNotEmpty && !_slotHolders.contains(link)) return false;
    _slotHolders.add(link);
    activeSends++;
    if (activeSends > maxActiveSends) maxActiveSends = activeSends;
    return true;
  }

  @override
  void releaseFileSlot(ChatLink link) {
    if (_slotHolders.remove(link)) activeSends--;
    // Le prochain qui attendait peut partir.
    for (final l in _links.toList()) {
      unawaited(l.flush().catchError((_) {}));
    }
  }

  @override
  bool beginReceiving(String messageId) => _receiving.add(messageId);

  @override
  void endReceiving(String messageId) => _receiving.remove(messageId);

  Future<void> flushAll() async {
    for (final l in _links.toList()) {
      await l.flush();
    }
  }

  Contact asContact() => Contact(deviceId: id, name: identity.name);

  Future<List<ChatMessage>> inbox(String gid) => store.messages(gid);
}

Node newNode(String name) {
  final n = Node(name);
  addTearDown(() {
    try {
      n.dir.deleteSync(recursive: true);
    } catch (_) {}
  });
  return n;
}

int _seed = 3;

/// Relie deux téléphones. Renvoie leurs deux bouts de connexion.
Future<(ChatLink, ChatLink)> join(
  Node a,
  Node b, {
  int maxChunk = 9,
  Transport Function(Transport)? wrapA,
  void Function(String, double)? progressB,
}) async {
  final (rawA, tb) = createMemoryPair(seed: _seed++, maxChunk: maxChunk);
  final ta = wrapA == null ? rawA : wrapA(rawA);
  final la = ChatLink(
    transport: ta,
    store: a.store,
    identity: a.identity,
    filesDir: a.dir,
    hub: a,
    initiator: true,
  );
  final lb = ChatLink(
    transport: tb,
    store: b.store,
    identity: b.identity,
    filesDir: b.dir,
    hub: b,
    onProgress: progressB,
  );
  a._links.add(la);
  b._links.add(lb);
  unawaited(la.closed.then((_) => a._links.remove(la)));
  unawaited(lb.closed.then((_) => b._links.remove(lb)));
  await Future.wait([la.ready, lb.ready]);
  return (la, lb);
}

Future<void> until(Future<bool> Function() condition) async {
  for (var i = 0; i < 1500; i++) {
    if (await condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('Condition jamais atteinte');
}

Future<Group> makeGroup(Node creator, List<Node> others, [String name = 'Classe']) async {
  final g = newGroup(creator.identity, name, others.map((n) => n.asContact()));
  await creator.store.saveGroup(g);
  return g;
}

Future<ChatMessage> say(Node n, Group g, String text) async {
  final m = await queueGroupText(n.store, n.identity, g, text);
  await n.flushAll();
  return m;
}

Future<List<String>> texts(Node n, String gid) async =>
    [for (final m in await n.inbox(gid)) m.text];

void main() {
  test('le groupe se propage aux membres dès qu\'ils se connectent', () async {
    final a = newNode('Awa');
    final b = newNode('Koffi');
    final c = newNode('Mireille');
    final g = await makeGroup(a, [b, c]);
    await join(a, b);
    await join(a, c);

    await until(() async => await b.store.group(g.id) != null);
    await until(() async => await c.store.group(g.id) != null);
    final gb = (await b.store.group(g.id))!;
    expect(gb.name, 'Classe');
    expect(gb.members, hasLength(3));
    expect(gb.creatorId, a.id);
  });

  test('un message de groupe arrive chez tous, avec son auteur', () async {
    final a = newNode('Awa');
    final b = newNode('Koffi');
    final c = newNode('Mireille');
    final g = await makeGroup(a, [b, c]);
    await join(a, b);
    await join(a, c);
    await until(() async => await b.store.group(g.id) != null);
    await until(() async => await c.store.group(g.id) != null);

    final m = await say(a, g, 'Bonjour à tous');
    await until(() async => (await texts(b, g.id)).isNotEmpty);
    await until(() async => (await texts(c, g.id)).isNotEmpty);

    final got = (await b.inbox(g.id)).single;
    expect(got.text, 'Bonjour à tous');
    expect(got.senderId, a.id);
    expect(got.senderName, 'Awa');
    expect(got.outgoing, isFalse);

    // L'auteur voit « reçu par 2 sur 2 » et le message passe à « reçu ».
    await until(() async {
      final counts = await a.store.deliveryCounts(g.id);
      return counts[m.id]?.delivered == 2;
    });
    await until(
      () async => (await a.store.message(m.id))!.status == MessageStatus.delivered,
    );
    expect(b.notified, hasLength(1));
  });

  test('trois personnes écrivent en même temps : tout le monde voit tout', () async {
    final a = newNode('Awa');
    final b = newNode('Koffi');
    final c = newNode('Mireille');
    final g = await makeGroup(a, [b, c]);
    await join(a, b);
    await join(a, c);
    await join(b, c);
    await until(() async => await b.store.group(g.id) != null);
    await until(() async => await c.store.group(g.id) != null);

    await Future.wait([
      for (var i = 0; i < 5; i++) say(a, g, 'A$i'),
      for (var i = 0; i < 5; i++) say(b, g, 'B$i'),
      for (var i = 0; i < 5; i++) say(c, g, 'C$i'),
    ]);
    for (final n in [a, b, c]) {
      await until(() async => (await n.inbox(g.id)).length == 15);
    }
    for (final n in [a, b, c]) {
      final all = await texts(n, g.id);
      expect(all.toSet(), hasLength(15)); // aucun doublon, aucun manque
    }
  });

  test('relais : Awa et Mireille ne se voient pas, Koffi fait passer', () async {
    final a = newNode('Awa');
    final b = newNode('Koffi');
    final c = newNode('Mireille');
    final g = await makeGroup(a, [b, c]);
    await join(a, b);
    await join(b, c); // pas de lien entre Awa et Mireille
    await until(() async => await c.store.group(g.id) != null);

    final m = await say(a, g, 'Message relayé');
    await until(() async => (await texts(c, g.id)).contains('Message relayé'));
    final got = (await c.inbox(g.id)).single;
    expect(got.senderId, a.id); // c'est bien Awa l'auteur, pas Koffi

    // Awa apprend que Mireille l'a eu, sans l'avoir jamais rencontrée.
    await until(() async {
      final counts = await a.store.deliveryCounts(g.id);
      return counts[m.id]?.delivered == 2;
    });
    // Et le message n'est pas dupliqué chez Koffi ni chez Awa.
    expect(await texts(b, g.id), ['Message relayé']);
    expect(await texts(a, g.id), ['Message relayé']);
  });

  test('un membre absent reçoit le message à sa prochaine connexion', () async {
    final a = newNode('Awa');
    final b = newNode('Koffi');
    final c = newNode('Mireille');
    final g = await makeGroup(a, [b, c]);
    final (ab, _) = await join(a, b);
    await until(() async => await b.store.group(g.id) != null);

    final m = await say(a, g, 'Tu me reçois ?');
    await until(() async => (await texts(b, g.id)).isNotEmpty);
    final counts = await a.store.deliveryCounts(g.id);
    expect(counts[m.id]!.delivered, lessThan(2)); // Mireille n'est pas là
    expect((await a.store.message(m.id))!.status, isNot(MessageStatus.delivered));

    await ab.close();
    await until(() async => a.links.isEmpty);

    // Mireille arrive plus tard : elle reçoit le groupe, puis le message.
    await join(a, c);
    await until(() async => (await texts(c, g.id)).contains('Tu me reçois ?'));
    await until(
      () async => (await a.store.message(m.id))!.status == MessageStatus.sent ||
          (await a.store.message(m.id))!.status == MessageStatus.delivered,
    );
  });

  test('un nouveau membre rencontré chez un autre membre reçoit le groupe', () async {
    final a = newNode('Awa');
    final b = newNode('Koffi');
    final d = newNode('Didier');
    final g = await makeGroup(a, [b]);
    await join(a, b);
    await until(() async => await b.store.group(g.id) != null);

    // Awa ajoute Didier (version 2), puis part : seul Koffi garde la copie.
    final g2 = editedGroup(g, by: a.id, members: [...g.members,
        GroupMember(deviceId: d.id, name: 'Didier')]);
    await a.store.saveGroup(g2);
    for (final l in a.links) {
      await l.sendGroupInfo(g2);
    }
    await until(() async => (await b.store.group(g.id))!.version == 2);
    for (final l in a.links.toList()) {
      await l.close();
    }

    await join(b, d); // Didier ne connaît que Koffi
    await until(() async => await d.store.group(g.id) != null);
    expect((await d.store.group(g.id))!.members, hasLength(3));
  });

  test('un membre retiré apprend qu\'il ne fait plus partie du groupe', () async {
    final a = newNode('Awa');
    final b = newNode('Koffi');
    final c = newNode('Mireille');
    final g = await makeGroup(a, [b, c]);
    await join(a, b);
    await join(a, c);
    await until(() async => await c.store.group(g.id) != null);

    final g2 = editedGroup(g,
        by: a.id,
        members: g.members.where((m) => m.deviceId != c.id).toList());
    await a.store.saveGroup(g2);
    for (final l in a.links) {
      await l.sendGroupInfo(g2);
    }
    // Mireille est retirée : on lui envoie aussi la nouvelle version.
    await until(() async => (await c.store.group(g.id))!.active == false);
    expect((await b.store.group(g.id))!.members, hasLength(2));

    // Après son retrait, elle ne reçoit plus rien.
    await say(a, g2, 'Entre nous');
    await until(() async => (await texts(b, g.id)).contains('Entre nous'));
    expect(await texts(c, g.id), isEmpty);
  });

  test('personne d\'autre que le créateur ne peut modifier un groupe', () async {
    final a = newNode('Awa');
    final b = newNode('Koffi');
    final x = newNode('Intrus');
    final g = await makeGroup(a, [b]);
    await join(a, b);
    await until(() async => await b.store.group(g.id) != null);
    final (xb, _) = await join(x, b);

    // L'intrus prétend être le créateur, avec une version plus élevée.
    final fake = Group(
      id: g.id,
      name: 'Piraté',
      creatorId: x.id,
      version: 99,
      members: [
        GroupMember(deviceId: x.id, name: 'Intrus'),
        GroupMember(deviceId: b.id, name: 'Koffi'),
      ],
      createdAt: DateTime.now(),
    );
    await xb.sendGroupInfo(fake);
    await Future<void>.delayed(const Duration(milliseconds: 150));
    final kept = (await b.store.group(g.id))!;
    expect(kept.name, 'Classe');
    expect(kept.creatorId, a.id);
  });

  test('un message d\'un non-membre est ignoré', () async {
    final a = newNode('Awa');
    final b = newNode('Koffi');
    final x = newNode('Intrus');
    final g = await makeGroup(a, [b]);
    await join(a, b);
    await until(() async => await b.store.group(g.id) != null);
    final (xb, _) = await join(x, b);

    await xb.sendFrame(Frame.json(FrameType.groupText, {
      'gid': g.id,
      'id': generateId(),
      'from': x.id,
      'fname': 'Intrus',
      'text': 'spam',
      'ts': 0,
    }));
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(await texts(b, g.id), isEmpty);
  });

  test('départ d\'un membre : le créateur publie une nouvelle version', () async {
    final a = newNode('Awa');
    final b = newNode('Koffi');
    final c = newNode('Mireille');
    final g = await makeGroup(a, [b, c]);
    await join(a, b);
    await join(a, c);
    await until(() async => await c.store.group(g.id) != null);

    // Mireille quitte : elle l'annonce, puis marque le groupe comme quitté.
    final cg = (await c.store.group(g.id))!;
    for (final l in c.links) {
      await l.sendFrame(Frame.json(FrameType.groupLeave, {'gid': g.id, 'who': c.id}));
    }
    await c.store.saveGroup(cg.copyWith(active: false));

    await until(() async => (await a.store.group(g.id))!.version == 2);
    expect((await a.store.group(g.id))!.hasMember(c.id), isFalse);
    await until(() async => (await b.store.group(g.id))!.version == 2);
    expect((await b.store.group(g.id))!.hasMember(c.id), isFalse);
  });

  test('un fichier de groupe est reçu intact par chaque membre', () async {
    final a = newNode('Awa');
    final b = newNode('Koffi');
    final c = newNode('Mireille');
    final g = await makeGroup(a, [b, c]);
    await join(a, b);
    await join(a, c);
    await until(() async => await b.store.group(g.id) != null);
    await until(() async => await c.store.group(g.id) != null);

    final bytes = Uint8List.fromList(List.generate(50000, (i) => (i * 7) % 256));
    final src = File('${a.dir.path}${Platform.pathSeparator}src.bin')
      ..writeAsBytesSync(bytes);
    final stored = await copyIntoStorage(a.dir, src.path, 'cours.pdf');
    final m = await queueGroupFile(a.store, a.identity, g,
        kind: MessageKind.file,
        fileName: 'cours.pdf',
        fileSize: bytes.length,
        storedPath: stored);
    await a.flushAll();

    for (final n in [b, c]) {
      await until(() async {
        final ms = await n.inbox(g.id);
        return ms.isNotEmpty && ms.single.status == MessageStatus.received;
      });
      final got = (await n.inbox(g.id)).single;
      expect(got.senderId, a.id);
      expect(File(got.filePath!).readAsBytesSync(), orderedEquals(bytes));
    }
    await until(
      () async => (await a.store.message(m.id))!.status == MessageStatus.delivered,
    );
  });

  fileAndAdminTests();

  test('connexion vivante : le PING régulier ne la coupe pas', () async {
    final a = newNode('Awa');
    final b = newNode('Koffi');
    final (ta, tb) = createMemoryPair(seed: 1, maxChunk: 9);
    final la = ChatLink(
      transport: ta,
      store: a.store,
      identity: a.identity,
      keepAlive: const Duration(milliseconds: 40),
      keepAliveTimeout: const Duration(milliseconds: 200),
    );
    final lb = ChatLink(transport: tb, store: b.store, identity: b.identity);
    await Future.wait([la.ready, lb.ready]);
    var closed = false;
    unawaited(la.closed.then((_) => closed = true));
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(closed, isFalse);
    await la.close();
    await lb.close();
  });

  test('connexion morte : sans réponse au PING, elle est fermée', () async {
    final a = newNode('Awa');
    final deaf = _DeafTransport();
    final la = ChatLink(
      transport: deaf,
      store: a.store,
      identity: a.identity,
      keepAlive: const Duration(milliseconds: 40),
      keepAliveTimeout: const Duration(milliseconds: 100),
    );
    await la.closed.timeout(const Duration(seconds: 3));
  });
}


/// Compte les octets envoyés par un téléphone sur une liaison.
class _CountingTransport implements Transport {
  _CountingTransport(this.inner);
  final Transport inner;
  int sent = 0;

  @override
  Stream<Uint8List> get incoming => inner.incoming;

  @override
  Future<void> send(Uint8List bytes) {
    sent += bytes.length;
    return inner.send(bytes);
  }

  @override
  Future<void> close() => inner.close();
}

Uint8List _bytes(int n) => Uint8List.fromList(List.generate(n, (i) => (i * 31 + 7) % 251));

Future<ChatMessage> _bigFile(Node n, String to, Uint8List data, String name,
    {MessageKind kind = MessageKind.file, int? durationMs}) async {
  final src = File('${n.dir.path}${Platform.pathSeparator}${generateId()}.bin')
    ..writeAsBytesSync(data);
  final m = ChatMessage.draftFile(
    contactId: to,
    kind: kind,
    fileName: name,
    fileSize: data.length,
    filePath: src.path,
    durationMs: durationMs,
  );
  await n.store.addMessage(m);
  return m;
}

void fileAndAdminTests() {
  test('un fichier interrompu reprend là où il s\'était arrêté', () async {
    final a = newNode('Awa');
    final b = newNode('Koffi');
    final data = _bytes(600 * 1024);
    var cut = false;
    late ChatLink lbRef;
    final (la, lb) = await join(
      a,
      b,
      maxChunk: 4096,
      progressB: (id, p) {
        if (!cut && p >= 0.4 && p < 1) {
          cut = true;
          unawaited(lbRef.close());
        }
      },
    );
    lbRef = lb;
    final m = await _bigFile(a, b.id, data, 'video.mp4');
    await a.flushAll();
    await until(() async => cut);
    await until(() async => a.links.isEmpty && b.links.isEmpty);
    await until(() async => !la.busy); // l'envoi interrompu se nettoie

    // La moitié environ est déjà chez Koffi.
    final partial = (await b.store.message(m.id))!;
    expect(partial.status, MessageStatus.receiving);
    expect(File(partial.filePath!).lengthSync(), greaterThan(100 * 1024));

    // Ils se retrouvent : le fichier reprend, il ne repart pas de zéro.
    late _CountingTransport counter;
    await join(a, b, maxChunk: 4096, wrapA: (t) => counter = _CountingTransport(t));
    await until(
      () async => (await b.store.message(m.id))!.status == MessageStatus.received,
    );
    final done = await b.store.message(m.id);
    expect(File(done!.filePath!).readAsBytesSync(), orderedEquals(data));
    expect(counter.sent, lessThan(data.length * 0.8));
    await until(
      () async => (await a.store.message(m.id))!.status == MessageStatus.delivered,
    );
  });

  test('un fichier de groupe part vers un membre à la fois, et arrive à tous', () async {
    final a = newNode('Awa');
    final b = newNode('Koffi');
    final c = newNode('Mireille');
    final g = await makeGroup(a, [b, c]);
    await join(a, b, maxChunk: 4096);
    await join(a, c, maxChunk: 4096);
    await join(b, c, maxChunk: 4096);
    await until(() async => await b.store.group(g.id) != null);
    await until(() async => await c.store.group(g.id) != null);

    final data = _bytes(400 * 1024);
    final src = File('${a.dir.path}${Platform.pathSeparator}in.bin')
      ..writeAsBytesSync(data);
    final stored = await copyIntoStorage(a.dir, src.path, 'cours.pdf');
    final m = await queueGroupFile(a.store, a.identity, g,
        kind: MessageKind.file,
        fileName: 'cours.pdf',
        fileSize: data.length,
        storedPath: stored);
    await a.flushAll();

    for (final n in [b, c]) {
      await until(() async {
        final ms = await n.inbox(g.id);
        return ms.isNotEmpty && ms.single.status == MessageStatus.received;
      });
      final got = (await n.inbox(g.id)).single;
      expect(File(got.filePath!).readAsBytesSync(), orderedEquals(data));
      expect(got.senderId, a.id);
    }
    expect(a.maxActiveSends, 1); // jamais deux gros envois en même temps
    await until(
      () async => (await a.store.message(m.id))!.status == MessageStatus.delivered,
    );
    // Un seul exemplaire chez chacun, malgré les deux chemins possibles.
    expect(await b.inbox(g.id), hasLength(1));
    expect(await c.inbox(g.id), hasLength(1));
  });

  test('relais : un fichier passe par un membre pour atteindre un autre', () async {
    final a = newNode('Awa');
    final b = newNode('Koffi');
    final c = newNode('Mireille');
    final g = await makeGroup(a, [b, c]);
    await join(a, b, maxChunk: 4096);
    await join(b, c, maxChunk: 4096); // Awa et Mireille ne se voient pas
    await until(() async => await c.store.group(g.id) != null);

    final data = _bytes(150 * 1024);
    final src = File('${a.dir.path}${Platform.pathSeparator}in.bin')
      ..writeAsBytesSync(data);
    final stored = await copyIntoStorage(a.dir, src.path, 'photo.jpg');
    final m = await queueGroupFile(a.store, a.identity, g,
        kind: MessageKind.image,
        fileName: 'photo.jpg',
        fileSize: data.length,
        storedPath: stored);
    await a.flushAll();

    await until(() async {
      final ms = await c.inbox(g.id);
      return ms.isNotEmpty && ms.single.status == MessageStatus.received;
    });
    final got = (await c.inbox(g.id)).single;
    expect(File(got.filePath!).readAsBytesSync(), orderedEquals(data));
    expect(got.senderId, a.id);
    expect(got.kind, MessageKind.image);
    // Awa apprend que Mireille l'a, sans l'avoir croisée.
    await until(() async {
      final counts = await a.store.deliveryCounts(g.id);
      return counts[m.id]?.delivered == 2;
    });
  });

  test('un message vocal garde sa durée et son type', () async {
    final a = newNode('Awa');
    final b = newNode('Koffi');
    await join(a, b, maxChunk: 4096);
    final voice = _bytes(40 * 1024);
    final m = await _bigFile(a, b.id, voice, 'vocal.m4a',
        kind: MessageKind.audio, durationMs: 12500);
    await a.flushAll();
    await until(() async {
      final got = await b.store.message(m.id);
      return got != null && got.status == MessageStatus.received;
    });
    final got = (await b.store.message(m.id))!;
    expect(got.kind, MessageKind.audio);
    expect(got.durationMs, 12500);
    expect(File(got.filePath!).readAsBytesSync(), orderedEquals(voice));
    expect(a.maxActiveSends, 0); // un petit fichier n'attend pas son tour
  });

  test('un vocal dans un groupe arrive à chacun', () async {
    final a = newNode('Awa');
    final b = newNode('Koffi');
    final c = newNode('Mireille');
    final g = await makeGroup(a, [b, c]);
    await join(a, b, maxChunk: 4096);
    await join(a, c, maxChunk: 4096);
    await until(() async => await b.store.group(g.id) != null);
    await until(() async => await c.store.group(g.id) != null);
    final voice = _bytes(30 * 1024);
    final src = File('${a.dir.path}${Platform.pathSeparator}v.m4a')
      ..writeAsBytesSync(voice);
    final stored = await copyIntoStorage(a.dir, src.path, 'vocal.m4a');
    await queueGroupFile(a.store, a.identity, g,
        kind: MessageKind.audio,
        fileName: 'vocal.m4a',
        fileSize: voice.length,
        storedPath: stored,
        durationMs: 4200);
    await a.flushAll();
    for (final n in [b, c]) {
      await until(() async {
        final ms = await n.inbox(g.id);
        return ms.isNotEmpty && ms.single.status == MessageStatus.received;
      });
      final got = (await n.inbox(g.id)).single;
      expect(got.kind, MessageKind.audio);
      expect(got.durationMs, 4200);
    }
  });

  test('admin : le créateur nomme un administrateur, qui peut modifier le groupe', () async {
    final a = newNode('Awa');
    final b = newNode('Koffi');
    final c = newNode('Mireille');
    final g = await makeGroup(a, [b, c]);
    await join(a, b);
    await join(a, c);
    await join(b, c);
    await until(() async => await c.store.group(g.id) != null);
    await until(() async => await b.store.group(g.id) != null);

    final g2 = editedGroup(g, by: a.id, admins: [b.id]);
    await a.store.saveGroup(g2);
    for (final l in a.links) {
      await l.sendGroupInfo(g2);
    }
    await until(() async => (await c.store.group(g.id))!.isAdmin(b.id));

    // Koffi, devenu administrateur, renomme le groupe.
    final gb = (await b.store.group(g.id))!;
    final g3 = editedGroup(gb, by: b.id, name: 'Équipe');
    await b.store.saveGroup(g3);
    for (final l in b.links) {
      await l.sendGroupInfo(g3);
    }
    await until(() async => (await a.store.group(g.id))!.name == 'Équipe');
    await until(() async => (await c.store.group(g.id))!.name == 'Équipe');
  });

  test('admin : un simple membre ne peut pas modifier le groupe', () async {
    final a = newNode('Awa');
    final b = newNode('Koffi');
    final c = newNode('Mireille');
    final g = await makeGroup(a, [b, c]);
    await join(a, b);
    await join(a, c);
    await join(b, c);
    await until(() async => await b.store.group(g.id) != null);
    await until(() async => await c.store.group(g.id) != null);

    final gc = (await c.store.group(g.id))!;
    final forged = editedGroup(gc, by: c.id, name: 'Piraté', admins: [c.id]);
    for (final l in c.links) {
      await l.sendGroupInfo(forged);
    }
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect((await a.store.group(g.id))!.name, 'Classe');
    expect((await b.store.group(g.id))!.name, 'Classe');
    expect((await a.store.group(g.id))!.isAdmin(c.id), isFalse);
  });

  test('admin : en mode annonces, seul un administrateur peut écrire', () async {
    final a = newNode('Awa');
    final b = newNode('Koffi');
    final g = await makeGroup(a, [b]);
    await join(a, b);
    await until(() async => await b.store.group(g.id) != null);

    final g2 = editedGroup(g, by: a.id, adminsOnlyPost: true);
    await a.store.saveGroup(g2);
    for (final l in a.links) {
      await l.sendGroupInfo(g2);
    }
    await until(() async => (await b.store.group(g.id))!.adminsOnlyPost);
    expect((await b.store.group(g.id))!.canPost(b.id), isFalse);
    expect((await b.store.group(g.id))!.canPost(a.id), isTrue);

    // Koffi force l'envoi : Awa ne l'affiche pas.
    final gb = (await b.store.group(g.id))!;
    await queueGroupText(b.store, b.identity, gb, 'Je passe en force');
    await b.flushAll();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(await texts(a, g.id), isEmpty);

    // Awa, elle, peut écrire.
    await say(a, g2, 'Annonce');
    await until(() async => (await texts(b, g.id)).contains('Annonce'));
  });

  test('admin : le créateur supprime le groupe pour tout le monde', () async {
    final a = newNode('Awa');
    final b = newNode('Koffi');
    final c = newNode('Mireille');
    final g = await makeGroup(a, [b, c]);
    await join(a, b);
    await join(a, c);
    await until(() async => await b.store.group(g.id) != null);
    await until(() async => await c.store.group(g.id) != null);

    final closed = editedGroup(g, by: a.id, closed: true);
    await a.store.saveGroup(closed.copyWith(active: false));
    for (final l in a.links) {
      await l.sendGroupInfo(closed);
    }
    for (final n in [b, c]) {
      await until(() async {
        final got = (await n.store.group(g.id))!;
        return got.closed && !got.active;
      });
    }
  });

  test('admin : retirer un membre le retire aussi des administrateurs', () {
    final me = Identity.create('Awa');
    final b = Contact(deviceId: generateId(), name: 'Koffi');
    final g = newGroup(me, 'Classe', [b]);
    final g2 = editedGroup(g, by: me.deviceId, admins: [b.deviceId]);
    expect(g2.isAdmin(b.deviceId), isTrue);
    final g3 = editedGroup(g2,
        by: me.deviceId,
        members: g2.members.where((m) => m.deviceId != b.deviceId).toList());
    expect(g3.isAdmin(b.deviceId), isFalse);
    expect(g3.version, 3);
  });

  test('quelqu\'un qui a quitté le groupe n\'y revient pas par une copie périmée', () async {
    final a = newNode('Awa');
    final c = newNode('Mireille');
    final g = await makeGroup(a, [c]);
    await join(a, c);
    await until(() async => await c.store.group(g.id) != null);
    final gc = (await c.store.group(g.id))!;
    await c.store.saveGroup(gc.copyWith(active: false)); // Mireille quitte

    final stale = editedGroup(g, by: a.id, name: 'Autre nom');
    await a.store.saveGroup(stale);
    for (final l in a.links) {
      await l.sendGroupInfo(stale);
    }
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect((await c.store.group(g.id))!.active, isFalse);
  });
}

/// Un canal qui avale tout et ne répond jamais : un téléphone parti sans prévenir.
class _DeafTransport implements Transport {
  final StreamController<Uint8List> _in = StreamController<Uint8List>();

  @override
  Stream<Uint8List> get incoming => _in.stream;

  @override
  Future<void> send(Uint8List bytes) async {}

  @override
  Future<void> close() async {
    if (!_in.isClosed) await _in.close();
  }
}
