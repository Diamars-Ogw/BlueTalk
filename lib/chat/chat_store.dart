import 'dart:async';

import 'models.dart';

/// Tout ce que l'application garde sur le téléphone.
abstract interface class ChatStore {
  /// Émet à chaque modification (pour rafraîchir l'interface).
  Stream<void> get changes;

  Future<Identity?> loadIdentity();
  Future<void> saveIdentity(Identity identity);

  Future<String?> setting(String key);
  Future<void> saveSetting(String key, String value);

  Future<Contact?> contact(String deviceId);
  Future<List<Contact>> contacts();
  Future<void> upsertContact(Contact contact);

  /// Ajoute un message. Renvoie false s'il existe déjà (même identifiant).
  Future<bool> addMessage(ChatMessage message);

  Future<ChatMessage?> message(String messageId);

  /// Fait avancer le statut d'un message sortant. Ne recule jamais.
  Future<void> setStatus(String messageId, MessageStatus status);

  /// Met à jour un message entrant (réception d'un fichier terminée).
  Future<void> setIncomingState(
    String messageId,
    MessageStatus status, {
    String? filePath,
  });

  /// Les messages d'une conversation, du plus ancien au plus récent.
  Future<List<ChatMessage>> messages(String contactId);

  /// Les messages sortants à (re)livrer : en attente, ou envoyés sans accusé.
  Future<List<ChatMessage>> pendingFor(String contactId);

  // ---------- Groupes ----------

  Future<Group?> group(String id);

  /// Tous les groupes, y compris ceux qu'on a quittés.
  Future<List<Group>> groups();

  /// Crée ou remplace un groupe et sa liste de membres.
  Future<void> saveGroup(Group group);

  /// Supprime un groupe, son historique et ses suivis de livraison.
  Future<void> deleteGroup(String id);

  /// Prépare le suivi de livraison d'un message de groupe : une ligne
  /// « en attente » par membre. Sans effet pour les lignes déjà présentes.
  Future<void> addDeliveries(String messageId, Iterable<String> memberIds);

  /// Où en est la livraison à ce membre, ou null s'il n'y a pas de suivi.
  Future<DeliveryState?> delivery(String messageId, String memberId);

  /// Fait avancer la livraison à un membre (ne recule jamais). Met aussi à
  /// jour le statut d'ensemble d'un message sortant : « envoyé » dès qu'un
  /// membre l'a reçu des mains de l'expéditeur, « reçu » quand tous l'ont.
  Future<void> setDelivery(
    String messageId,
    String memberId,
    DeliveryState state,
  );

  /// Les messages de groupe (les nôtres, ou ceux qu'on relaie) qui n'ont pas
  /// encore été confirmés par ce membre, du plus ancien au plus récent.
  Future<List<ChatMessage>> pendingGroupFor(String memberId);

  /// Pour chaque message sortant d'un groupe : combien de membres l'ont reçu.
  Future<Map<String, DeliveryCount>> deliveryCounts(String groupId);
}

/// Version en mémoire, utilisée par les tests sur PC.
class MemoryChatStore implements ChatStore {
  final StreamController<void> _changes = StreamController<void>.broadcast();
  Identity? _identity;
  final Map<String, String> _settings = {};
  final Map<String, Contact> _contacts = {};
  final Map<String, ChatMessage> _messages = {};
  final Map<String, Group> _groups = {};
  final Map<String, Map<String, DeliveryState>> _deliveries = {};

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
  Future<String?> setting(String key) async => _settings[key];

  @override
  Future<void> saveSetting(String key, String value) async {
    _settings[key] = value;
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
  Future<ChatMessage?> message(String messageId) async => _messages[messageId];

  @override
  Future<void> setStatus(String messageId, MessageStatus status) async {
    final m = _messages[messageId];
    if (m == null || !m.outgoing || status.index <= m.status.index) return;
    _messages[messageId] = m.withStatus(status);
    _changes.add(null);
  }

  @override
  Future<void> setIncomingState(
    String messageId,
    MessageStatus status, {
    String? filePath,
  }) async {
    final m = _messages[messageId];
    if (m == null || m.outgoing) return;
    _messages[messageId] = m.copyWith(status: status, filePath: filePath);
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

  // ---------- Groupes ----------

  @override
  Future<Group?> group(String id) async => _groups[id];

  @override
  Future<List<Group>> groups() async =>
      _groups.values.toList()..sort((a, b) => a.name.compareTo(b.name));

  @override
  Future<void> saveGroup(Group group) async {
    _groups[group.id] = group;
    _changes.add(null);
  }

  @override
  Future<void> deleteGroup(String id) async {
    _groups.remove(id);
    final ids = _messages.values
        .where((m) => m.contactId == id)
        .map((m) => m.id)
        .toList();
    for (final mid in ids) {
      _messages.remove(mid);
      _deliveries.remove(mid);
    }
    _changes.add(null);
  }

  @override
  Future<void> addDeliveries(
    String messageId,
    Iterable<String> memberIds,
  ) async {
    final rows = _deliveries.putIfAbsent(messageId, () => {});
    for (final id in memberIds) {
      rows.putIfAbsent(id, () => DeliveryState.pending);
    }
  }

  @override
  Future<DeliveryState?> delivery(String messageId, String memberId) async =>
      _deliveries[messageId]?[memberId];

  @override
  Future<void> setDelivery(
    String messageId,
    String memberId,
    DeliveryState state,
  ) async {
    final rows = _deliveries[messageId];
    final cur = rows?[memberId];
    if (rows == null || cur == null || state.index <= cur.index) return;
    rows[memberId] = state;
    final m = _messages[messageId];
    if (m != null && m.outgoing) {
      final all = rows.values.every((d) => d == DeliveryState.delivered);
      final any = rows.values.any((d) => d.index >= DeliveryState.sent.index);
      final target = all
          ? MessageStatus.delivered
          : (any ? MessageStatus.sent : MessageStatus.pending);
      if (target.index > m.status.index) {
        _messages[messageId] = m.withStatus(target);
      }
    }
    _changes.add(null);
  }

  @override
  Future<List<ChatMessage>> pendingGroupFor(String memberId) async {
    final out = <ChatMessage>[];
    _deliveries.forEach((messageId, rows) {
      final state = rows[memberId];
      final m = _messages[messageId];
      if (state != null && state != DeliveryState.delivered && m != null) {
        out.add(m);
      }
    });
    out.sort((a, b) => a.at.compareTo(b.at));
    return out;
  }

  @override
  Future<Map<String, DeliveryCount>> deliveryCounts(String groupId) async {
    final out = <String, DeliveryCount>{};
    for (final m in _messages.values) {
      if (m.contactId != groupId || !m.outgoing) continue;
      final rows = _deliveries[m.id];
      if (rows == null) continue;
      out[m.id] = DeliveryCount(
        rows.values.where((d) => d == DeliveryState.delivered).length,
        rows.length,
      );
    }
    return out;
  }
}
