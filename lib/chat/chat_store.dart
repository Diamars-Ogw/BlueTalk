import 'dart:async';

import 'models.dart';

/// Tout ce que l'application garde sur le téléphone.
abstract interface class ChatStore {
  /// Émet à chaque modification (pour rafraîchir l'interface).
  Stream<void> get changes;

  Future<Identity?> loadIdentity();
  Future<void> saveIdentity(Identity identity);

  Future<Contact?> contact(String deviceId);
  Future<List<Contact>> contacts();
  Future<void> upsertContact(Contact contact);

  /// Ajoute un message. Renvoie false s'il existe déjà (même identifiant).
  Future<bool> addMessage(ChatMessage message);

  /// Fait avancer le statut d'un message sortant. Ne recule jamais.
  Future<void> setStatus(String messageId, MessageStatus status);

  /// Les messages d'une conversation, du plus ancien au plus récent.
  Future<List<ChatMessage>> messages(String contactId);

  /// Les messages sortants à (re)livrer : en attente, ou envoyés sans accusé.
  Future<List<ChatMessage>> pendingFor(String contactId);
}

/// Version en mémoire, utilisée par les tests sur PC.
class MemoryChatStore implements ChatStore {
  final StreamController<void> _changes = StreamController<void>.broadcast();
  Identity? _identity;
  final Map<String, Contact> _contacts = {};
  final Map<String, ChatMessage> _messages = {};

  @override
  Stream<void> get changes => _changes.stream;

  @override
  Future<Identity?> loadIdentity() async => _identity;

  @override
  Future<void> saveIdentity(Identity identity) async {
    _identity = identity;
    _changes.add(null);
  }

  @override
  Future<Contact?> contact(String deviceId) async => _contacts[deviceId];

  @override
  Future<List<Contact>> contacts() async =>
      _contacts.values.toList()..sort((a, b) => a.name.compareTo(b.name));

  @override
  Future<void> upsertContact(Contact contact) async {
    _contacts[contact.deviceId] = contact;
    _changes.add(null);
  }

  @override
  Future<bool> addMessage(ChatMessage message) async {
    if (_messages.containsKey(message.id)) return false;
    _messages[message.id] = message;
    _changes.add(null);
    return true;
  }

  @override
  Future<void> setStatus(String messageId, MessageStatus status) async {
    final m = _messages[messageId];
    if (m == null || !m.outgoing || status.index <= m.status.index) return;
    _messages[messageId] = m.withStatus(status);
    _changes.add(null);
  }

  @override
  Future<List<ChatMessage>> messages(String contactId) async =>
      _messages.values.where((m) => m.contactId == contactId).toList()
        ..sort((a, b) => a.at.compareTo(b.at));

  @override
  Future<List<ChatMessage>> pendingFor(String contactId) async =>
      (await messages(contactId))
          .where(
            (m) => m.outgoing && m.status.index < MessageStatus.delivered.index,
          )
          .toList();
}
