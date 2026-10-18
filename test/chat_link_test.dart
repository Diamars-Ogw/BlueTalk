import 'package:bluetalk/chat/chat_link.dart';
import 'package:bluetalk/chat/chat_store.dart';
import 'package:bluetalk/chat/models.dart';
import 'package:bluetalk/protocol/memory_transport.dart';
import 'package:flutter_test/flutter_test.dart';

class Peer {
  Peer(String name)
    : store = MemoryChatStore(),
      identity = Identity.create(name);
  final MemoryChatStore store;
  final Identity identity;
  String get id => identity.deviceId;
}

Future<(ChatLink, ChatLink)> connect(Peer a, Peer b, {int seed = 5}) async {
  final (ta, tb) = createMemoryPair(seed: seed, maxChunk: 6);
  final la = ChatLink(transport: ta, store: a.store, identity: a.identity);
  final lb = ChatLink(transport: tb, store: b.store, identity: b.identity);
  await Future.wait([la.ready, lb.ready]);
  return (la, lb);
}

Future<void> until(Future<bool> Function() condition) async {
  for (var i = 0; i < 400; i++) {
    if (await condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('Condition jamais atteinte');
}

void main() {
  test(
    'première rencontre : chacun enregistre l\'autre comme contact',
    () async {
      final awa = Peer('Awa');
      final koffi = Peer('Koffi');
      final (la, lb) = await connect(awa, koffi);

      expect((await awa.store.contact(koffi.id))?.name, 'Koffi');
      expect((await koffi.store.contact(awa.id))?.name, 'Awa');

      await la.close();
      await lb.close();
    },
  );

  test('message écrit hors connexion, livré à la rencontre suivante', () async {
    final awa = Peer('Awa');
    final koffi = Peer('Koffi');
    final (l1, l2) = await connect(awa, koffi);
    await l1.close();
    await l2.close();

    // Plus de connexion : le message reste en attente.
    final m = ChatMessage.draft(
      contactId: koffi.id,
      text: 'Cours demain à 8h 📚',
    );
    await awa.store.addMessage(m);
    expect(await awa.store.pendingFor(koffi.id), hasLength(1));

    final (l3, l4) = await connect(awa, koffi, seed: 6);
    await until(() async => (await koffi.store.messages(awa.id)).length == 1);
    await until(
      () async =>
          (await awa.store.messages(koffi.id)).single.status ==
          MessageStatus.delivered,
    );

    final recu = (await koffi.store.messages(awa.id)).single;
    expect(recu.text, 'Cours demain à 8h 📚');
    expect(recu.outgoing, isFalse);
    expect(recu.status, MessageStatus.received);

    await l3.close();
    await l4.close();
  });

  test(
    'message déjà reçu dont l\'accusé s\'est perdu : pas de doublon',
    () async {
      final awa = Peer('Awa');
      final koffi = Peer('Koffi');

      final m = ChatMessage.draft(contactId: koffi.id, text: 'Bonjour');
      await awa.store.addMessage(m);
      await awa.store.setStatus(m.id, MessageStatus.sent);
      // Koffi l'avait déjà enregistré, mais l'accusé n'est jamais revenu.
      await koffi.store.addMessage(
        ChatMessage(
          id: m.id,
          contactId: awa.id,
          outgoing: false,
          text: 'Bonjour',
          at: m.at,
          status: MessageStatus.received,
        ),
      );

      final (la, lb) = await connect(awa, koffi);
      await until(
        () async =>
            (await awa.store.messages(koffi.id)).single.status ==
            MessageStatus.delivered,
      );
      expect(await koffi.store.messages(awa.id), hasLength(1));

      await la.close();
      await lb.close();
    },
  );

  test('conversation en direct, dans les deux sens', () async {
    final awa = Peer('Awa');
    final koffi = Peer('Koffi');
    final (la, lb) = await connect(awa, koffi);

    final q = ChatMessage.draft(contactId: koffi.id, text: 'Question ?');
    await awa.store.addMessage(q);
    await la.flush();
    await until(() async => (await koffi.store.messages(awa.id)).length == 1);

    final r = ChatMessage.draft(contactId: awa.id, text: 'Réponse !');
    await koffi.store.addMessage(r);
    await lb.flush();

    await until(() async {
      final ms = await awa.store.messages(koffi.id);
      return ms.length == 2 &&
          ms.any((m) => m.outgoing && m.status == MessageStatus.delivered);
    });
    await until(
      () async =>
          (await koffi.store.messages(awa.id))
              .any((m) => m.outgoing && m.status == MessageStatus.delivered),
    );

    await la.close();
    await lb.close();
  });

  test('un statut ne recule jamais', () async {
    final store = MemoryChatStore();
    final m = ChatMessage.draft(contactId: 'x', text: 'a');
    await store.addMessage(m);
    await store.setStatus(m.id, MessageStatus.delivered);
    await store.setStatus(m.id, MessageStatus.sent);
    expect((await store.messages('x')).single.status, MessageStatus.delivered);
  });
}
