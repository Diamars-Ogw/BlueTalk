import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:bluetalk/chat/chat_link.dart';
import 'package:bluetalk/chat/chat_store.dart';
import 'package:bluetalk/chat/models.dart';
import 'package:bluetalk/protocol/memory_transport.dart';
import 'package:flutter_test/flutter_test.dart';

class Peer {
  Peer(String name)
    : store = MemoryChatStore(),
      identity = Identity.create(name),
      dir = Directory.systemTemp.createTempSync('bluetalk_test_');

  final MemoryChatStore store;
  final Identity identity;
  final Directory dir;
  int progressCalls = 0;
  String get id => identity.deviceId;
}

Peer newPeer(String name) {
  final p = Peer(name);
  addTearDown(() {
    try {
      p.dir.deleteSync(recursive: true);
    } catch (_) {}
  });
  return p;
}

Uint8List randomBytes(int n, int seed) {
  final r = Random(seed);
  return Uint8List.fromList(List.generate(n, (_) => r.nextInt(256)));
}

Future<(ChatLink, ChatLink)> connect(Peer a, Peer b, {int seed = 5}) async {
  final (ta, tb) = createMemoryPair(seed: seed, maxChunk: 3000);
  final la = ChatLink(
    transport: ta,
    store: a.store,
    identity: a.identity,
    filesDir: a.dir,
    onProgress: (_, __) => a.progressCalls++,
  );
  final lb = ChatLink(
    transport: tb,
    store: b.store,
    identity: b.identity,
    filesDir: b.dir,
    onProgress: (_, __) => b.progressCalls++,
  );
  await Future.wait([la.ready, lb.ready]);
  return (la, lb);
}

Future<void> until(Future<bool> Function() condition) async {
  for (var i = 0; i < 2000; i++) {
    if (await condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('Condition jamais atteinte');
}

/// Crée un fichier source chez [from] et l'enregistre comme message en attente.
Future<ChatMessage> addFile(
  Peer from,
  Peer to,
  String name,
  Uint8List bytes, {
  MessageKind kind = MessageKind.file,
}) async {
  final path = '${from.dir.path}${Platform.pathSeparator}src_${generateId()}';
  await File(path).writeAsBytes(bytes);
  final m = ChatMessage.draftFile(
    contactId: to.id,
    kind: kind,
    fileName: name,
    fileSize: bytes.length,
    filePath: path,
  );
  await from.store.addMessage(m);
  return m;
}

void main() {
  test(
    'fichier écrit hors connexion, livré intact à la rencontre suivante',
    () async {
      final awa = newPeer('Awa');
      final koffi = newPeer('Koffi');
      final (l1, l2) = await connect(awa, koffi);
      await l1.close();
      await l2.close();

      final bytes = randomBytes(250000, 1);
      await addFile(awa, koffi, 'cours.pdf', bytes);

      final (l3, l4) = await connect(awa, koffi, seed: 6);
      await until(() async {
        final ms = await koffi.store.messages(awa.id);
        return ms.length == 1 && ms.single.status == MessageStatus.received;
      });

      final recu = (await koffi.store.messages(awa.id)).single;
      expect(recu.kind, MessageKind.file);
      expect(recu.fileName, 'cours.pdf');
      expect(recu.fileSize, bytes.length);
      expect(await File(recu.filePath!).readAsBytes(), orderedEquals(bytes));

      await until(
        () async =>
            (await awa.store.messages(koffi.id)).single.status ==
            MessageStatus.delivered,
      );

      await l3.close();
      await l4.close();
    },
  );

  test('un fichier déjà reçu n\'est pas retransféré', () async {
    final awa = newPeer('Awa');
    final koffi = newPeer('Koffi');
    final bytes = randomBytes(40000, 2);

    final m = await addFile(
      awa,
      koffi,
      'photo.jpg',
      bytes,
      kind: MessageKind.image,
    );
    await awa.store.setStatus(m.id, MessageStatus.sent);

    // Koffi a déjà le fichier, mais l'accusé s'est perdu.
    final chezKoffi =
        '${koffi.dir.path}${Platform.pathSeparator}${m.id}_photo.jpg';
    await File(chezKoffi).writeAsBytes(bytes);
    await koffi.store.addMessage(
      ChatMessage(
        id: m.id,
        contactId: awa.id,
        outgoing: false,
        text: 'photo.jpg',
        at: DateTime.now(),
        status: MessageStatus.received,
        kind: MessageKind.image,
        fileName: 'photo.jpg',
        fileSize: bytes.length,
        filePath: chezKoffi,
      ),
    );

    final (la, lb) = await connect(awa, koffi);
    await until(
      () async =>
          (await awa.store.messages(koffi.id)).single.status ==
          MessageStatus.delivered,
    );

    expect(await koffi.store.messages(awa.id), hasLength(1));
    expect(koffi.progressCalls, 0); // aucun octet n'a été retransféré

    await la.close();
    await lb.close();
  });

  test(
    'un nom de fichier piégé reste dans le dossier de l\'application',
    () async {
      final awa = newPeer('Awa');
      final koffi = newPeer('Koffi');
      final (la, lb) = await connect(awa, koffi);

      await addFile(
        awa,
        koffi,
        '../../evil.txt',
        Uint8List.fromList([1, 2, 3]),
      );
      await la.flush();

      await until(() async {
        final ms = await koffi.store.messages(awa.id);
        return ms.length == 1 && ms.single.status == MessageStatus.received;
      });

      final recu = (await koffi.store.messages(awa.id)).single;
      expect(recu.fileName, 'evil.txt');
      expect(recu.filePath!.contains('..'), isFalse);
      expect(File(recu.filePath!).parent.path, koffi.dir.path);
      expect(await File(recu.filePath!).readAsBytes(), [1, 2, 3]);

      await la.close();
      await lb.close();
    },
  );
}
