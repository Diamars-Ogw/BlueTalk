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

/// Le type de message. `audio` (message vocal) est ajouté en dernier pour ne
/// pas changer les valeurs déjà enregistrées dans la base.
enum MessageKind { text, image, file, audio }

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
    this.senderId,
    this.senderName,
    this.durationMs,
  });

  /// Nouveau message texte, en attente d'envoi. Pour un groupe,
  /// [contactId] est l'identifiant du groupe et [senderId] celui de l'auteur.
  factory ChatMessage.draft({
    required String contactId,
    required String text,
    String? senderId,
    String? senderName,
  }) => ChatMessage(
    id: generateId(),
    contactId: contactId,
    outgoing: true,
    text: text,
    at: DateTime.now(),
    status: MessageStatus.pending,
    senderId: senderId,
    senderName: senderName,
  );

  /// Nouveau fichier ou image, en attente d'envoi.
  factory ChatMessage.draftFile({
    required String contactId,
    required MessageKind kind,
    required String fileName,
    required int fileSize,
    required String filePath,
    String? mime,
    String? senderId,
    String? senderName,
    int? durationMs,
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
    senderId: senderId,
    senderName: senderName,
    durationMs: durationMs,
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

  /// Auteur du message, renseigné pour les messages de groupe uniquement
  /// (pour un message sortant, c'est nous).
  final String? senderId;
  final String? senderName;

  /// Durée d'un message vocal, en millisecondes.
  final int? durationMs;

  bool get isFile => kind != MessageKind.text;

  /// Vrai pour un message qui appartient à un groupe.
  bool get isGroupMessage => senderId != null;

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
        senderId: senderId,
        senderName: senderName,
        durationMs: durationMs,
      );

  ChatMessage withStatus(MessageStatus s) => copyWith(status: s);
}

/// État de la livraison d'un message de groupe auprès d'un membre.
/// Ne recule jamais : pending, sent, delivered.
enum DeliveryState { pending, sent, delivered }

/// Combien de membres ont reçu un message de groupe, sur combien.
class DeliveryCount {
  const DeliveryCount(this.delivered, this.total);
  final int delivered;
  final int total;
}

/// Un membre d'un groupe : son identifiant permanent et son nom.
class GroupMember {
  const GroupMember({required this.deviceId, required this.name});

  final String deviceId;
  final String name;
}

/// Un groupe de discussion. Il n'existe sur aucun serveur : chaque membre en
/// garde une copie. Le créateur et les administrateurs qu'il nomme modifient
/// le groupe (chaque modification augmente [version]) ; la copie portant la
/// version la plus élevée l'emporte.
class Group {
  const Group({
    required this.id,
    required this.name,
    required this.creatorId,
    required this.version,
    required this.members,
    required this.createdAt,
    this.active = true,
    this.admins = const [],
    this.adminsOnlyPost = false,
    this.closed = false,
    this.editedBy,
  });

  final String id;
  final String name;
  final String creatorId;
  final int version;
  final List<GroupMember> members;
  final DateTime createdAt;

  /// Faux quand on a quitté le groupe, qu'on en a été retiré ou qu'il a été
  /// supprimé : l'historique reste lisible, mais plus rien ne part ni n'arrive.
  final bool active;

  /// Identifiants des administrateurs nommés par le créateur (le créateur est
  /// toujours administrateur, sans figurer dans cette liste).
  final List<String> admins;

  /// Si vrai, seuls les administrateurs peuvent écrire (mode annonces).
  final bool adminsOnlyPost;

  /// Vrai quand le créateur a supprimé le groupe pour tout le monde.
  final bool closed;

  /// Qui a publié cette version (créateur ou administrateur).
  final String? editedBy;

  bool hasMember(String deviceId) => members.any((m) => m.deviceId == deviceId);

  bool isAdmin(String deviceId) =>
      deviceId == creatorId || admins.contains(deviceId);

  /// Le membre a-t-il le droit d'écrire dans ce groupe ?
  bool canPost(String deviceId) =>
      active && hasMember(deviceId) && (!adminsOnlyPost || isAdmin(deviceId));

  String? nameOf(String deviceId) {
    for (final m in members) {
      if (m.deviceId == deviceId) return m.name;
    }
    return null;
  }

  Group copyWith({
    String? name,
    int? version,
    List<GroupMember>? members,
    bool? active,
    List<String>? admins,
    bool? adminsOnlyPost,
    bool? closed,
    String? editedBy,
  }) => Group(
    id: id,
    name: name ?? this.name,
    creatorId: creatorId,
    version: version ?? this.version,
    members: members ?? this.members,
    createdAt: createdAt,
    active: active ?? this.active,
    admins: admins ?? this.admins,
    adminsOnlyPost: adminsOnlyPost ?? this.adminsOnlyPost,
    closed: closed ?? this.closed,
    editedBy: editedBy ?? this.editedBy,
  );

  /// Deux descriptions disent-elles la même chose ? (hors version et auteur)
  bool sameContent(Group o) {
    List<String> ids(Group g) => (g.members.map((m) => m.deviceId).toList()..sort());
    List<String> names(Group g) => (g.members.map((m) => m.name).toList()..sort());
    bool eq(List<String> a, List<String> b) {
      if (a.length != b.length) return false;
      for (var i = 0; i < a.length; i++) {
        if (a[i] != b[i]) return false;
      }
      return true;
    }

    return name == o.name &&
        adminsOnlyPost == o.adminsOnlyPost &&
        closed == o.closed &&
        eq(ids(this), ids(o)) &&
        eq(names(this), names(o)) &&
        eq(([...admins]..sort()), ([...o.admins]..sort()));
  }

  /// Contenu de la trame GROUP_INFO.
  Map<String, dynamic> toJson() => {
    'gid': id,
    'name': name,
    'creator': creatorId,
    'ver': version,
    'ts': createdAt.millisecondsSinceEpoch,
    'members': [
      for (final m in members) {'id': m.deviceId, 'name': m.name},
    ],
    'admins': admins,
    'only': adminsOnlyPost,
    'closed': closed,
    'by': editedBy ?? creatorId,
  };

  /// Lit une trame GROUP_INFO. Lève une erreur si elle est mal formée.
  /// Les anciennes versions (sans administrateurs) restent lisibles.
  factory Group.fromJson(Map<String, dynamic> j) {
    final members = <GroupMember>[
      for (final m in (j['members'] as List<dynamic>))
        GroupMember(
          deviceId: (m as Map<String, dynamic>)['id'] as String,
          name: m['name'] as String,
        ),
    ];
    return Group(
      id: j['gid'] as String,
      name: j['name'] as String,
      creatorId: j['creator'] as String,
      version: j['ver'] as int,
      members: members,
      createdAt: DateTime.fromMillisecondsSinceEpoch(j['ts'] as int),
      admins: [
        for (final a in (j['admins'] as List<dynamic>? ?? const [])) a as String,
      ],
      adminsOnlyPost: (j['only'] as bool?) ?? false,
      closed: (j['closed'] as bool?) ?? false,
      editedBy: j['by'] as String?,
    );
  }
}
