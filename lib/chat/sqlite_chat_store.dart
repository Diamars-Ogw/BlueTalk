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
      version: 2,
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
          'status INTEGER NOT NULL, '
          'kind INTEGER NOT NULL DEFAULT 0, '
          'file_name TEXT, '
          'file_size INTEGER, '
          'file_path TEXT, '
          'mime TEXT)',
        );
        await db.execute(
          'CREATE INDEX idx_messages_contact ON messages (contact_id, sent_at)',
        );
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await db.execute(
            'ALTER TABLE messages ADD COLUMN kind INTEGER NOT NULL DEFAULT 0',
          );
          await db.execute('ALTER TABLE messages ADD COLUMN file_name TEXT');
          await db.execute('ALTER TABLE messages ADD COLUMN file_size INTEGER');
          await db.execute('ALTER TABLE messages ADD COLUMN file_path TEXT');
          await db.execute('ALTER TABLE messages ADD COLUMN mime TEXT');
        }
      },
    );
    return SqliteChatStore._(db);
  }

  @override
  Stream<void> get changes => _changes.stream;

  // ---------- Identité et réglages ----------

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

  @override
  Future<String?> setting(String key) async {
    final rows = await _db.query(
      'meta',
      where: 'k = ?',
      whereArgs: ['setting.$key'],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first['v'] as String;
  }

  @override
  Future<void> saveSetting(String key, String value) async {
    await _db.insert('meta', {
      'k': 'setting.$key',
      'v': value,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  // ---------- Contacts ----------

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

  // ---------- Messages ----------

  ChatMessage _messageFromRow(Map<String, Object?> r) => ChatMessage(
    id: r['id'] as String,
    contactId: r['contact_id'] as String,
    outgoing: (r['outgoing'] as int) == 1,
    text: r['body'] as String,
    at: DateTime.fromMillisecondsSinceEpoch(r['sent_at'] as int),
    status: MessageStatus.values[r['status'] as int],
    kind: MessageKind.values[(r['kind'] as int?) ?? 0],
    fileName: r['file_name'] as String?,
    fileSize: r['file_size'] as int?,
    filePath: r['file_path'] as String?,
    mime: r['mime'] as String?,
  );

  Map<String, Object?> _messageToRow(ChatMessage m) => {
    'id': m.id,
    'contact_id': m.contactId,
    'outgoing': m.outgoing ? 1 : 0,
    'body': m.text,
    'sent_at': m.at.millisecondsSinceEpoch,
    'status': m.status.index,
    'kind': m.kind.index,
    'file_name': m.fileName,
    'file_size': m.fileSize,
    'file_path': m.filePath,
    'mime': m.mime,
  };

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
      await txn.insert('messages', _messageToRow(m));
      return true;
    });
    if (added) _changes.add(null);
    return added;
  }

  @override
  Future<ChatMessage?> message(String messageId) async {
    final rows = await _db.query(
      'messages',
      where: 'id = ?',
      whereArgs: [messageId],
      limit: 1,
    );
    return rows.isEmpty ? null : _messageFromRow(rows.first);
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
  Future<void> setIncomingState(
    String messageId,
    MessageStatus status, {
    String? filePath,
  }) async {
    await _db.update(
      'messages',
      {'status': status.index, if (filePath != null) 'file_path': filePath},
      where: 'id = ? AND outgoing = 0',
      whereArgs: [messageId],
    );
    _changes.add(null);
  }

  @override
  Future<List<ChatMessage>> messages(String contactId) async {
    final rows = await _db.query(
      'messages',
      where: 'contact_id = ?',
      whereArgs: [contactId],
      orderBy: 'sent_at ASC, rowid ASC',
    );
    return rows.map(_messageFromRow).toList();
  }

  @override
  Future<List<ChatMessage>> pendingFor(String contactId) async {
    final rows = await _db.query(
      'messages',
      where: 'contact_id = ? AND outgoing = 1 AND status < ?',
      whereArgs: [contactId, MessageStatus.delivered.index],
      orderBy: 'sent_at ASC, rowid ASC',
    );
    return rows.map(_messageFromRow).toList();
  }
}
