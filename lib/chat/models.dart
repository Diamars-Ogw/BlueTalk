import 'dart:math';

/// État d'un message. Pour un message sortant, un statut ne recule jamais
/// (pending, sent, delivered dans cet ordre).
enum MessageStatus {
  pending, // écrit, pas encore envoyé
  sent, // écrit sur le canal, aucune preuve de réception
  delivered, // l'autre appareil a confirmé l'avoir enregistré
  received, // message entrant, complet
  receiving, // fichier entrant en cours de réception
}

enum MessageKind { text, image, file }

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
  final String? address;
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
    this.kind = MessageKind.text,
    this.fileName,
    this.fileSize,
    this.filePath,
    this.mime,
  });

  /// Nouveau message texte, en attente d'envoi.
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

  /// Nouveau fichier ou image, en attente d'envoi.
  factory ChatMessage.draftFile({
    required String contactId,
    required MessageKind kind,
    required String fileName,
    required int fileSize,
    required String filePath,
    String? mime,
  }) => ChatMessage(
    id: generateId(),
    contactId: contactId,
    outgoing: true,
    text: fileName,
    at: DateTime.now(),
    status: MessageStatus.pending,
    kind: kind,
    fileName: fileName,
    fileSize: fileSize,
    filePath: filePath,
    mime: mime,
  );

  final String id;
  final String contactId;
  final bool outgoing;
  final String text;
  final DateTime at;
  final MessageStatus status;
  final MessageKind kind;
  final String? fileName;
  final int? fileSize;
  final String? filePath;
  final String? mime;

  bool get isFile => kind != MessageKind.text;

  ChatMessage copyWith({MessageStatus? status, String? filePath}) =>
      ChatMessage(
        id: id,
        contactId: contactId,
        outgoing: outgoing,
        text: text,
        at: at,
        status: status ?? this.status,
        kind: kind,
        fileName: fileName,
        fileSize: fileSize,
        filePath: filePath ?? this.filePath,
        mime: mime,
      );

  ChatMessage withStatus(MessageStatus s) => copyWith(status: s);
}
