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
      version: 4,
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
          'mime TEXT, '
          'sender_id TEXT, '
          'sender_name TEXT, '
          'duration_ms INTEGER)',
        );
        await db.execute(
          'CREATE INDEX idx_messages_contact ON messages (contact_id, sent_at)',
        );
        await _createGroupTables(db);
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
        if (oldVersion < 3) {
          await db.execute('ALTER TABLE messages ADD COLUMN sender_id TEXT');
          await db.execute('ALTER TABLE messages ADD COLUMN sender_name TEXT');
          await _createGroupTables(db);
        }
        if (oldVersion < 4) {
          await db.execute('ALTER TABLE messages ADD COLUMN duration_ms INTEGER');
          // Les groupes créés avant cette version n'avaient pas ces réglages.
          await db.execute("ALTER TABLE groups ADD COLUMN admins TEXT NOT NULL DEFAULT ''");
          await db.execute('ALTER TABLE groups ADD COLUMN admins_only INTEGER NOT NULL DEFAULT 0');
          await db.execute('ALTER TABLE groups ADD COLUMN closed INTEGER NOT NULL DEFAULT 0');
          await db.execute('ALTER TABLE groups ADD COLUMN edited_by TEXT');
        }
      },
    );
    return SqliteChatStore._(db);
  }

  static Future<void> _createGroupTables(Database db) async {
    await db.execute(
      'CREATE TABLE groups ('
      'id TEXT PRIMARY KEY, '
      'name TEXT NOT NULL, '
      'creator_id TEXT NOT NULL, '
      'version INTEGER NOT NULL, '
      'created_at INTEGER NOT NULL, '
      'active INTEGER NOT NULL DEFAULT 1, '
      "admins TEXT NOT NULL DEFAULT '', "
      'admins_only INTEGER NOT NULL DEFAULT 0, '
      'closed INTEGER NOT NULL DEFAULT 0, '
      'edited_by TEXT)',
    );
    await db.execute(
      'CREATE TABLE group_members ('
      'group_id TEXT NOT NULL, '
      'device_id TEXT NOT NULL, '
      'name TEXT NOT NULL, '
      'PRIMARY KEY (group_id, device_id))',
    );
    await db.execute(
      'CREATE TABLE deliveries ('
      'message_id TEXT NOT NULL, '
      'member_id TEXT NOT NULL, '
      'state INTEGER NOT NULL DEFAULT 0, '
      'PRIMARY KEY (message_id, member_id))',
    );
    await db.execute(
      'CREATE INDEX idx_deliveries_member ON deliveries (member_id, state)',
    );
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
    senderId: r['sender_id'] as String?,
    senderName: r['sender_name'] as String?,
    durationMs: r['duration_ms'] as int?,
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
    'sender_id': m.senderId,
    'sender_name': m.senderName,
    'duration_ms': m.durationMs,
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

  // ---------- Groupes ----------

  Future<Group> _groupFromRow(Map<String, Object?> r) async {
    final id = r['id'] as String;
    final rows = await _db.query(
      'group_members',
      where: 'group_id = ?',
      whereArgs: [id],
      orderBy: 'name COLLATE NOCASE',
    );
    return Group(
      id: id,
      name: r['name'] as String,
      creatorId: r['creator_id'] as String,
      version: r['version'] as int,
      createdAt: DateTime.fromMillisecondsSinceEpoch(r['created_at'] as int),
      active: (r['active'] as int) == 1,
      admins: ((r['admins'] as String?) ?? '')
          .split(',')
          .where((a) => a.isNotEmpty)
          .toList(),
      adminsOnlyPost: ((r['admins_only'] as int?) ?? 0) == 1,
      closed: ((r['closed'] as int?) ?? 0) == 1,
      editedBy: r['edited_by'] as String?,
      members: [
        for (final m in rows)
          GroupMember(
            deviceId: m['device_id'] as String,
            name: m['name'] as String,
          ),
      ],
    );
  }

  @override
  Future<Group?> group(String id) async {
    final rows = await _db.query(
      'groups',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    return rows.isEmpty ? null : _groupFromRow(rows.first);
  }

  @override
  Future<List<Group>> groups() async {
    final rows = await _db.query('groups', orderBy: 'name COLLATE NOCASE');
    return [for (final r in rows) await _groupFromRow(r)];
  }

  @override
  Future<void> saveGroup(Group g) async {
    await _db.transaction((txn) async {
      await txn.insert('groups', {
        'id': g.id,
        'name': g.name,
        'creator_id': g.creatorId,
        'version': g.version,
        'created_at': g.createdAt.millisecondsSinceEpoch,
        'active': g.active ? 1 : 0,
        'admins': g.admins.join(','),
        'admins_only': g.adminsOnlyPost ? 1 : 0,
        'closed': g.closed ? 1 : 0,
        'edited_by': g.editedBy,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      await txn.delete(
        'group_members',
        where: 'group_id = ?',
        whereArgs: [g.id],
      );
      for (final m in g.members) {
        await txn.insert('group_members', {
          'group_id': g.id,
          'device_id': m.deviceId,
          'name': m.name,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
    });
    _changes.add(null);
  }

  @override
  Future<void> deleteGroup(String id) async {
    await _db.transaction((txn) async {
      await txn.delete(
        'deliveries',
        where: 'message_id IN (SELECT id FROM messages WHERE contact_id = ?)',
        whereArgs: [id],
      );
      await txn.delete('messages', where: 'contact_id = ?', whereArgs: [id]);
      await txn.delete('group_members', where: 'group_id = ?', whereArgs: [id]);
      await txn.delete('groups', where: 'id = ?', whereArgs: [id]);
    });
    _changes.add(null);
  }

  @override
  Future<void> addDeliveries(
    String messageId,
    Iterable<String> memberIds,
  ) async {
    await _db.transaction((txn) async {
      for (final id in memberIds) {
        await txn.insert('deliveries', {
          'message_id': messageId,
          'member_id': id,
          'state': DeliveryState.pending.index,
        }, conflictAlgorithm: ConflictAlgorithm.ignore);
      }
    });
  }

  @override
  Future<DeliveryState?> delivery(String messageId, String memberId) async {
    final rows = await _db.query(
      'deliveries',
      columns: ['state'],
      where: 'message_id = ? AND member_id = ?',
      whereArgs: [messageId, memberId],
      limit: 1,
    );
    return rows.isEmpty
        ? null
        : DeliveryState.values[rows.first['state'] as int];
  }

  @override
  Future<void> setDelivery(
    String messageId,
    String memberId,
    DeliveryState state,
  ) async {
    final changed = await _db.transaction<bool>((txn) async {
      final n = await txn.update(
        'deliveries',
        {'state': state.index},
        where: 'message_id = ? AND member_id = ? AND state < ?',
        whereArgs: [messageId, memberId, state.index],
      );
      if (n == 0) return false;
      final r = await txn.rawQuery(
        'SELECT COUNT(*) AS total, '
        'SUM(CASE WHEN state = ? THEN 1 ELSE 0 END) AS done, '
        'SUM(CASE WHEN state >= ? THEN 1 ELSE 0 END) AS sent '
        'FROM deliveries WHERE message_id = ?',
        [DeliveryState.delivered.index, DeliveryState.sent.index, messageId],
      );
      final total = (r.first['total'] as int?) ?? 0;
      final done = (r.first['done'] as int?) ?? 0;
      final sent = (r.first['sent'] as int?) ?? 0;
      final target = (total > 0 && done == total)
          ? MessageStatus.delivered
          : (sent > 0 ? MessageStatus.sent : MessageStatus.pending);
      await txn.update(
        'messages',
        {'status': target.index},
        where: 'id = ? AND outgoing = 1 AND status < ?',
        whereArgs: [messageId, target.index],
      );
      return true;
    });
    if (changed) _changes.add(null);
  }

  @override
  Future<List<ChatMessage>> pendingGroupFor(String memberId) async {
    final rows = await _db.rawQuery(
      'SELECT m.* FROM messages m '
      'JOIN deliveries d ON d.message_id = m.id '
      'WHERE d.member_id = ? AND d.state < ? '
      'ORDER BY m.sent_at ASC, m.rowid ASC',
      [memberId, DeliveryState.delivered.index],
    );
    return rows.map(_messageFromRow).toList();
  }

  @override
  Future<Map<String, DeliveryCount>> deliveryCounts(String groupId) async {
    final rows = await _db.rawQuery(
      'SELECT m.id AS id, COUNT(d.member_id) AS total, '
      'SUM(CASE WHEN d.state = ? THEN 1 ELSE 0 END) AS done '
      'FROM messages m JOIN deliveries d ON d.message_id = m.id '
      'WHERE m.contact_id = ? AND m.outgoing = 1 GROUP BY m.id',
      [DeliveryState.delivered.index, groupId],
    );
    return {
      for (final r in rows)
        r['id'] as String: DeliveryCount(
          (r['done'] as int?) ?? 0,
          (r['total'] as int?) ?? 0,
        ),
    };
  }
}
