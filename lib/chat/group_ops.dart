import 'dart:io';

import 'chat_store.dart';
import 'models.dart';

/// Opérations sur les groupes, indépendantes du Bluetooth : l'application et
/// les tests passent exactement par le même code.

/// Crée un groupe dont [me] est le créateur. Les [others] sont des contacts
/// déjà rencontrés. Le groupe n'est pas encore enregistré.
Group newGroup(Identity me, String name, Iterable<Contact> others) {
  final members = <GroupMember>[
    GroupMember(deviceId: me.deviceId, name: me.name),
    for (final c in others)
      if (c.deviceId != me.deviceId)
        GroupMember(deviceId: c.deviceId, name: c.name),
  ];
  return Group(
    id: generateId(),
    name: name.trim(),
    creatorId: me.deviceId,
    version: 1,
    members: members,
    createdAt: DateTime.now(),
  );
}

/// Nouvelle version d'un groupe, publiée par [by] (créateur ou administrateur).
/// Retirer un membre le retire aussi des administrateurs.
Group editedGroup(
  Group g, {
  required String by,
  String? name,
  List<GroupMember>? members,
  List<String>? admins,
  bool? adminsOnlyPost,
  bool? closed,
}) {
  final nextMembers = members ?? g.members;
  final ids = nextMembers.map((m) => m.deviceId).toSet();
  final nextAdmins = (admins ?? g.admins)
      .where((a) => ids.contains(a) && a != g.creatorId)
      .toList();
  return g.copyWith(
    name: name?.trim(),
    members: members,
    admins: nextAdmins,
    adminsOnlyPost: adminsOnlyPost,
    closed: closed,
    version: g.version + 1,
    editedBy: by,
  );
}

/// Écrit un message dans un groupe : il est enregistré tout de suite, avec
/// un suivi de livraison par membre, et partira dès que possible.
Future<ChatMessage> queueGroupText(
  ChatStore store,
  Identity me,
  Group g,
  String text,
) async {
  final msg = ChatMessage.draft(
    contactId: g.id,
    text: text,
    senderId: me.deviceId,
    senderName: me.name,
  );
  await store.addMessage(msg);
  await store.addDeliveries(
    msg.id,
    g.members.map((m) => m.deviceId).where((d) => d != me.deviceId),
  );
  return msg;
}

/// Écrit un fichier ou une image dans un groupe (déjà copié dans le dossier
/// de l'application, à l'adresse [storedPath]).
Future<ChatMessage> queueGroupFile(
  ChatStore store,
  Identity me,
  Group g, {
  required MessageKind kind,
  required String fileName,
  required int fileSize,
  required String storedPath,
  int? durationMs,
}) async {
  final msg = ChatMessage.draftFile(
    contactId: g.id,
    kind: kind,
    fileName: fileName,
    fileSize: fileSize,
    filePath: storedPath,
    senderId: me.deviceId,
    senderName: me.name,
    durationMs: durationMs,
  );
  await store.addMessage(msg);
  await store.addDeliveries(
    msg.id,
    g.members.map((m) => m.deviceId).where((d) => d != me.deviceId),
  );
  return msg;
}

/// Copie un fichier dans [dir] sous un nom sûr et renvoie son nouvel emplacement.
Future<String> copyIntoStorage(
  Directory dir,
  String sourcePath,
  String name,
) async {
  final safe = name.replaceAll(RegExp(r'[\\/]'), '_');
  final stored = '${dir.path}${Platform.pathSeparator}${generateId()}_$safe';
  await File(sourcePath).copy(stored);
  return stored;
}
