import 'dart:math';

/// État d'un message. L'ordre compte : un statut ne recule jamais.
enum MessageStatus {
  pending, // écrit, pas encore envoyé
  sent, // écrit sur le canal, aucune preuve de réception
  delivered, // l'autre appareil a confirmé l'avoir enregistré
  received, // message entrant
}

/// Identifiant aléatoire de 128 bits, en hexadécimal.
String generateId() {
  final r = Random.secure();
  return List.generate(
    16,
    (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
}

/// Qui je suis : un identifiant permanent et le nom choisi.
class Identity {
  const Identity({required this.deviceId, required this.name});

  factory Identity.create(String name) =>
      Identity(deviceId: generateId(), name: name.trim());

  final String deviceId;
  final String name;
}

/// Une personne déjà rencontrée.
class Contact {
  const Contact({
    required this.deviceId,
    required this.name,
    this.address,
    this.lastSeen,
  });

  final String deviceId;
  final String name;
  final String? address; // adresse Bluetooth, pour se reconnecter
  final DateTime? lastSeen;
}

class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.contactId,
    required this.outgoing,
    required this.text,
    required this.at,
    required this.status,
  });

  /// Nouveau message écrit par l'utilisateur, en attente d'envoi.
  factory ChatMessage.draft({
    required String contactId,
    required String text,
  }) => ChatMessage(
    id: generateId(),
    contactId: contactId,
    outgoing: true,
    text: text,
    at: DateTime.now(),
    status: MessageStatus.pending,
  );

  final String id;
  final String contactId; // l'autre personne de la conversation
  final bool outgoing;
  final String text;
  final DateTime at;
  final MessageStatus status;

  ChatMessage withStatus(MessageStatus s) => ChatMessage(
    id: id,
    contactId: contactId,
    outgoing: outgoing,
    text: text,
    at: at,
    status: s,
  );
}
