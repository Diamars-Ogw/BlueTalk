import 'dart:async';

import 'package:sqflite/sqflite.dart';

import 'chat_store.dart';
import 'models.dart';

class SqliteChatStore implements ChatStore {
  SqliteChatStore._(this._db);

  final Database _db;
  final StreamController<void> _changes = StreamController<void>.broadcast();

  static Future<SqliteChatStore> open({String? path}) async {
    final file = path ?? '${await getDatabasesPath()}/bluetalk.db';
    final db = await openDatabase(
      file,
      version: 1,
      onCreate: (db, version) async {
        await db.execute(
          'CREATE TABLE meta (k TEXT PRIMARY KEY, v TEXT NOT NULL)',
        );
        await db.execute(
          'CREATE TABLE contacts ('
          'device_id TEXT PRIMARY KEY, '
          'name TEXT NOT NULL, '
          'address TEXT, '
          'last_seen INTEGER)',
        );
        await db.execute(
          'CREATE TABLE messages ('
          'id TEXT PRIMARY KEY, '
          'contact_id TEXT NOT NULL, '
          'outgoing INTEGER NOT NULL, '
          'body TEXT NOT NULL, '
          'sent_at INTEGER NOT NULL, '
          'status INTEGER NOT NULL)',
        );
        await db.execute(
          'CREATE INDEX idx_messages_contact ON messages (contact_id, sent_at)',
        );
      },
    );
    return SqliteChatStore._(db);
  }

  @override
  Stream<void> get changes => _changes.stream;

  @override
  Future<Identity?> loadIdentity() async {
    final rows = await _db.query('meta');
    final m = {for (final r in rows) r['k'] as String: r['v'] as String};
    final id = m['device_id'];
    final name = m['name'];
    if (id == null || name == null) return null;
    return Identity(deviceId: id, name: name);
  }

  @override
  Future<void> saveIdentity(Identity identity) async {
    final batch = _db.batch();
    batch.insert('meta', {
      'k': 'device_id',
      'v': identity.deviceId,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    batch.insert('meta', {
      'k': 'name',
      'v': identity.name,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    await batch.commit(noResult: true);
    _changes.add(null);
  }

  Contact _contactFromRow(Map<String, Object?> r) => Contact(
    deviceId: r['device_id'] as String,
    name: r['name'] as String,
    address: r['address'] as String?,
    lastSeen: r['last_seen'] == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(r['last_seen'] as int),
  );

  @override
  Future<Contact?> contact(String deviceId) async {
    final rows = await _db.query(
      'contacts',
      where: 'device_id = ?',
      whereArgs: [deviceId],
      limit: 1,
    );
    return rows.isEmpty ? null : _contactFromRow(rows.first);
  }

  @override
  Future<List<Contact>> contacts() async {
    final rows = await _db.query('contacts', orderBy: 'name COLLATE NOCASE');
    return rows.map(_contactFromRow).toList();
  }

  @override
  Future<void> upsertContact(Contact c) async {
    await _db.insert('contacts', {
      'device_id': c.deviceId,
      'name': c.name,
      'address': c.address,
      'last_seen': c.lastSeen?.millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    _changes.add(null);
  }

  ChatMessage _messageFromRow(Map<String, Object?> r) => ChatMessage(
    id: r['id'] as String,
    contactId: r['contact_id'] as String,
    outgoing: (r['outgoing'] as int) == 1,
    text: r['body'] as String,
    at: DateTime.fromMillisecondsSinceEpoch(r['sent_at'] as int),
    status: MessageStatus.values[r['status'] as int],
  );

  @override
  Future<bool> addMessage(ChatMessage m) async {
    final added = await _db.transaction<bool>((txn) async {
      final exists = await txn.query(
        'messages',
        columns: ['id'],
        where: 'id = ?',
        whereArgs: [m.id],
        limit: 1,
      );
      if (exists.isNotEmpty) return false;
      await txn.insert('messages', {
        'id': m.id,
        'contact_id': m.contactId,
        'outgoing': m.outgoing ? 1 : 0,
        'body': m.text,
        'sent_at': m.at.millisecondsSinceEpoch,
        'status': m.status.index,
      });
      return true;
    });
    if (added) _changes.add(null);
    return added;
  }

  @override
  Future<void> setStatus(String messageId, MessageStatus status) async {
    final n = await _db.update(
      'messages',
      {'status': status.index},
      where: 'id = ? AND outgoing = 1 AND status < ?',
      whereArgs: [messageId, status.index],
    );
    if (n > 0) _changes.add(null);
  }

  @override
  Future<List<ChatMessage>> messages(String contactId) async {
    final rows = await _db.query(
      'messages',
      where: 'contact_id = ?',
      whereArgs: [contactId],
      orderBy: 'sent_at ASC',
    );
    return rows.map(_messageFromRow).toList();
  }

  @override
  Future<List<ChatMessage>> pendingFor(String contactId) async {
    final rows = await _db.query(
      'messages',
      where: 'contact_id = ? AND outgoing = 1 AND status < ?',
      whereArgs: [contactId, MessageStatus.delivered.index],
      orderBy: 'sent_at ASC',
    );
    return rows.map(_messageFromRow).toList();
  }
}
