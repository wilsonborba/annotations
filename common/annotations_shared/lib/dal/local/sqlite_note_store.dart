/// The local note store on installed apps: SQLite for documents and metadata,
/// managed attachment copies in the app support folder (technical decision
/// 12, D2, H1.2).
///
/// Durability:
/// - A save is one SQLite transaction with `synchronous=FULL`, so a commit is
///   on disk when [SqliteNoteStore.save] returns. A kill before the commit
///   leaves the previous complete state (https://www.sqlite.org/atomiccommit.html).
/// - An attachment is written to a temporary file, flushed to disk, renamed
///   to its final name and only then recorded. A document can reference it
///   only after that, and a save checks that every referenced file is there.
/// - [SqliteNoteStore.open] removes what a crash left behind: temporary
///   files, copies that were never recorded and recorded copies that no saved
///   note references (the Undo history ends with the app, B11).
///
/// This file uses only `dart:io` and SQLite. It has no network code: nothing
/// in the store leaves the device (D2.1).
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:sqlite3/sqlite3.dart';

import '../../core/local_store_settings.dart';
import '../../domain/models/local_note.dart';
import '../../domain/models/note_document.dart';
import '../../domain/services/local_note_store.dart';

/// Schema steps, applied in order. Step n moves `user_version` from n - 1 to
/// n. A later change adds a step; a released step never changes.
const _schemaSteps = [
  '''
  CREATE TABLE notes (
    id TEXT NOT NULL PRIMARY KEY,
    family TEXT NOT NULL,
    schema_version INTEGER NOT NULL,
    document TEXT NOT NULL,
    title TEXT,
    revision INTEGER NOT NULL,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    sync_state TEXT NOT NULL,
    account_id TEXT
  ) STRICT;
  CREATE TABLE attachments (
    id TEXT NOT NULL PRIMARY KEY,
    file TEXT NOT NULL,
    name TEXT NOT NULL,
    type TEXT NOT NULL,
    size INTEGER NOT NULL,
    created_at INTEGER NOT NULL
  ) STRICT;
  CREATE TABLE note_attachments (
    note_id TEXT NOT NULL REFERENCES notes (id) ON DELETE CASCADE,
    attachment_id TEXT NOT NULL REFERENCES attachments (id),
    PRIMARY KEY (note_id, attachment_id)
  ) STRICT;
  CREATE INDEX note_attachments_by_file ON note_attachments (attachment_id);
  ''',
];

/// The folder of unfinished copies inside the attachment folder. It is on
/// the same file system, so the rename to the final name is atomic.
const _partialFolder = '.partial';

final class SqliteNoteStore implements LocalNoteStore {
  SqliteNoteStore._(this._db, this._files);

  final Database _db;
  final Directory _files;
  final _random = Random.secure();

  /// Opens or creates the store in [folder] (the app support folder),
  /// applies the schema steps and recovers from an interrupted run.
  static Future<SqliteNoteStore> open(
    String folder, {
    LocalStoreSettings settings = const LocalStoreSettings(),
  }) async {
    final files = Directory('$folder/${settings.attachmentFolder}');
    await Directory('${files.path}/$_partialFolder').create(recursive: true);
    final db = sqlite3.open('$folder/${settings.databaseFile}');
    try {
      db
        ..execute('PRAGMA journal_mode = WAL')
        ..execute('PRAGMA synchronous = FULL')
        ..execute('PRAGMA foreign_keys = ON');
      _migrate(db);
      final store = SqliteNoteStore._(db, files);
      await store._recover();
      return store;
    } on Object {
      db.close();
      rethrow;
    }
  }

  static void _migrate(Database db) {
    final from = db.userVersion;
    if (from > _schemaSteps.length) {
      throw const LocalStoreException('newer_store');
    }
    for (var step = from; step < _schemaSteps.length; step++) {
      _transaction(db, () {
        db
          ..execute(_schemaSteps[step])
          ..userVersion = step + 1;
      });
    }
  }

  static T _transaction<T>(Database db, T Function() body) {
    db.execute('BEGIN IMMEDIATE');
    try {
      final result = body();
      db.execute('COMMIT');
      return result;
    } on Object {
      db.execute('ROLLBACK');
      rethrow;
    }
  }

  Future<void> _recover() async {
    await for (final entry in Directory(
      '${_files.path}/$_partialFolder',
    ).list()) {
      await entry.delete(recursive: true);
    }
    final orphans = _db.select('''
      SELECT id, file FROM attachments WHERE NOT EXISTS (
        SELECT 1 FROM note_attachments WHERE attachment_id = attachments.id)
    ''');
    _transaction(_db, () {
      for (final row in orphans) {
        _db.execute('DELETE FROM attachments WHERE id = ?', [row['id']]);
      }
    });
    final recorded = {
      for (final row in _db.select('SELECT file FROM attachments'))
        row['file'] as String,
    };
    await for (final entry in _files.list()) {
      final name = entry.uri.pathSegments.lastWhere((s) => s.isNotEmpty);
      if (entry is File && !recorded.contains(name)) await entry.delete();
    }
  }

  String _newId() => [
    for (var i = 0; i < 16; i++) _random.nextInt(256).toRadixString(16),
  ].map((h) => h.padLeft(2, '0')).join();

  File _file(String file) => File('${_files.path}/$file');

  LocalNote _note(Row row) {
    final schema = DocumentSchema(
      row['family'] as String,
      row['schema_version'] as int,
    );
    return LocalNote(
      id: row['id'] as String,
      schema: schema,
      document: NoteDocument.fromJson(
        jsonDecode(row['document'] as String),
        schema: schema,
      ),
      title: row['title'] as String?,
      revision: row['revision'] as int,
      createdAt: DateTime.fromMillisecondsSinceEpoch(row['created_at'] as int),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(row['updated_at'] as int),
      syncState: LocalSyncState.parse(row['sync_state'] as String),
      accountId: row['account_id'] as String?,
    );
  }

  @override
  Future<LocalNote?> load(String id) async {
    final rows = _db.select('SELECT * FROM notes WHERE id = ?', [id]);
    return rows.isEmpty ? null : _note(rows.first);
  }

  @override
  Future<List<LocalNote>> notes() async => [
    for (final row in _db.select(
      'SELECT * FROM notes ORDER BY updated_at DESC, id',
    ))
      _note(row),
  ];

  @override
  Future<LocalNote> save(LocalNoteDraft draft) async {
    final body = jsonEncode(draft.document.toJson());
    final files = referencedFiles(draft.document);
    final now = DateTime.now().millisecondsSinceEpoch;
    _transaction(_db, () {
      for (final id in files) {
        final rows = _db.select('SELECT file FROM attachments WHERE id = ?', [
          id,
        ]);
        if (rows.isEmpty || !_file(rows.first['file'] as String).existsSync()) {
          throw LocalStoreException('missing_attachment', id);
        }
      }
      _db.execute(
        '''
        INSERT INTO notes (id, family, schema_version, document, title,
          revision, created_at, updated_at, sync_state, account_id)
        VALUES (?, ?, ?, ?, ?, 1, ?, ?, ?, NULL)
        ON CONFLICT (id) DO UPDATE SET
          family = excluded.family,
          schema_version = excluded.schema_version,
          document = excluded.document,
          title = excluded.title,
          revision = notes.revision + 1,
          updated_at = excluded.updated_at,
          sync_state = CASE notes.sync_state
            WHEN ? THEN ? ELSE notes.sync_state END
        ''',
        [
          draft.id,
          draft.schema.name,
          draft.schema.version,
          body,
          draft.title,
          now,
          now,
          LocalSyncState.local.code,
          LocalSyncState.synced.code,
          LocalSyncState.changed.code,
        ],
      );
      _db.execute('DELETE FROM note_attachments WHERE note_id = ?', [draft.id]);
      for (final id in files) {
        _db.execute(
          'INSERT INTO note_attachments (note_id, attachment_id) VALUES (?, ?)',
          [draft.id, id],
        );
      }
    });
    return (await load(draft.id))!;
  }

  @override
  Future<void> setSync(
    String id, {
    required LocalSyncState state,
    required String? accountId,
  }) async {
    _db.execute(
      'UPDATE notes SET sync_state = ?, account_id = ? WHERE id = ?',
      [state.code, accountId, id],
    );
    if (_db.updatedRows == 0) throw LocalStoreException('missing_note', id);
  }

  /// The final file name: the new id and the extension of the original name,
  /// so that other apps can open the copy.
  String _fileName(String id, String name) {
    final dot = name.lastIndexOf('.');
    final ext = dot < 0 ? '' : name.substring(dot + 1);
    return RegExp(r'^[A-Za-z0-9]{1,10}$').hasMatch(ext) ? '$id.$ext' : id;
  }

  /// Writes the copy with [write] to a temporary file, flushes it to disk,
  /// renames it and records it.
  Future<LocalAttachment> _keep(
    String name,
    String type,
    Future<void> Function(RandomAccessFile out) write,
  ) async {
    final id = _newId();
    final file = _fileName(id, name);
    final partial = File('${_files.path}/$_partialFolder/$file');
    final out = await partial.open(mode: FileMode.writeOnly);
    try {
      await write(out);
      await out.flush();
    } on Object {
      await out.close();
      await partial.delete();
      rethrow;
    }
    await out.close();
    final size = await partial.length();
    await partial.rename(_file(file).path);
    _db.execute(
      'INSERT INTO attachments (id, file, name, type, size, created_at) '
      'VALUES (?, ?, ?, ?, ?, ?)',
      [id, file, name, type, size, DateTime.now().millisecondsSinceEpoch],
    );
    return LocalAttachment(
      id: id,
      name: name,
      type: type,
      size: size,
      path: _file(file).path,
    );
  }

  @override
  Future<LocalAttachment> importFile(
    String sourcePath, {
    required String type,
  }) async {
    final source = File(sourcePath);
    final name = source.uri.pathSegments.last;
    try {
      return await _keep(name, type, (out) async {
        await for (final chunk in source.openRead()) {
          await out.writeFrom(chunk);
        }
      });
    } on FileSystemException {
      throw LocalStoreException('unreadable_file', name);
    }
  }

  @override
  Future<LocalAttachment> importBytes(
    Uint8List bytes, {
    required String name,
    required String type,
  }) => _keep(name, type, (out) => out.writeFrom(bytes));

  @override
  Future<LocalAttachment?> attachment(String id) async {
    final rows = _db.select('SELECT * FROM attachments WHERE id = ?', [id]);
    if (rows.isEmpty) return null;
    final row = rows.first;
    final file = _file(row['file'] as String);
    if (!await file.exists()) return null;
    return LocalAttachment(
      id: id,
      name: row['name'] as String,
      type: row['type'] as String,
      size: row['size'] as int,
      path: file.path,
    );
  }

  @override
  Future<Uint8List?> readAttachment(String id) async {
    final found = await attachment(id);
    return found == null ? null : File(found.path).readAsBytes();
  }

  @override
  Future<void> discardAttachment(String id) async {
    final rows = _db.select(
      '''
      SELECT file FROM attachments WHERE id = ? AND NOT EXISTS (
        SELECT 1 FROM note_attachments WHERE attachment_id = attachments.id)
      ''',
      [id],
    );
    if (rows.isEmpty) return;
    _db.execute('DELETE FROM attachments WHERE id = ?', [id]);
    final file = _file(rows.first['file'] as String);
    if (await file.exists()) await file.delete();
  }

  @override
  Future<void> close() async => _db.close();
}
