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
import '../../domain/services/note_sync_service.dart';

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
  // annotations#19: the items of a page document are rows, so an autosave
  // writes only what changed. `notes.document` then keeps the rest of the
  // document. A note saved before this step still holds its items inline and
  // moves to rows at its next save.
  '''
  CREATE TABLE note_items (
    note_id TEXT NOT NULL REFERENCES notes (id) ON DELETE CASCADE,
    item_id TEXT NOT NULL,
    position INTEGER NOT NULL,
    hash INTEGER NOT NULL,
    body TEXT NOT NULL,
    PRIMARY KEY (note_id, item_id)
  ) STRICT;
  ''',
  // annotations#63: persist server note identity and authoritative server
  // revisions separately from local id and local save revision.
  '''
  ALTER TABLE notes ADD COLUMN server_note_id TEXT;
  ALTER TABLE notes ADD COLUMN server_revision INTEGER;
  ALTER TABLE notes ADD COLUMN server_original_revision_id TEXT;
  ALTER TABLE notes ADD COLUMN server_typed_revision_id TEXT;
  ''',
  // Conflict copies are owner-bound local documents without a reusable cloud id.
  'ALTER TABLE notes ADD COLUMN is_conflict_copy INTEGER NOT NULL DEFAULT 0;',
  // NotesUI51: retain only the owner-scoped prepared study id. The setup stays
  // in Certifications and clears when the trusted note identity/revision changes.
  'ALTER TABLE notes ADD COLUMN prepared_study_id TEXT;',
  // An accepted private transcription stays a separate local Typed document,
  // with an explicit source/run relation for later owner-authorized sync.
  '''
  ALTER TABLE notes ADD COLUMN transcription_source_note_id TEXT;
  ALTER TABLE notes ADD COLUMN transcription_run_id TEXT;
  ALTER TABLE notes ADD COLUMN transcription_source_revision_id TEXT;
  ALTER TABLE notes ADD COLUMN transcription_source_hash TEXT;
  ALTER TABLE notes ADD COLUMN transcription_source_local_revision INTEGER;
  ''',
];

/// A stable 64-bit hash of an item body, to find changed items: FNV-1a and
/// djb2 over the UTF-16 units, 32 bits each, so a changed item is never
/// taken for an unchanged one by chance in practice.
int _hash(String body) {
  var a = 0x811c9dc5, b = 5381;
  for (final unit in body.codeUnits) {
    a = ((a ^ unit) * 0x01000193) & 0xffffffff;
    b = ((b << 5) + b + unit) & 0xffffffff;
  }
  return (a << 32) | b;
}

/// The folder of unfinished copies inside the attachment folder. It is on
/// the same file system, so the rename to the final name is atomic.
const _partialFolder = '.partial';

final class SqliteNoteStore
    implements DeletableLocalNoteStore, AtomicTypedNoteStore {
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

  LocalNote _note(Row row, {NoteDocument? document}) {
    final schema = DocumentSchema(
      row['family'] as String,
      row['schema_version'] as int,
    );
    final id = row['id'] as String;
    if (document != null) return _local(row, id, schema, document);
    final json = jsonDecode(row['document'] as String) as Map<String, Object?>;
    if (!json.containsKey('items') && schema.family != DocumentFamily.typed) {
      json['items'] = [
        for (final item in _db.select(
          'SELECT body FROM note_items WHERE note_id = ? ORDER BY position',
          [id],
        ))
          jsonDecode(item['body'] as String),
      ];
    }
    return _local(row, id, schema, NoteDocument.fromJson(json, schema: schema));
  }

  LocalNote _local(
    Row row,
    String id,
    DocumentSchema schema,
    NoteDocument document,
  ) {
    return LocalNote(
      id: id,
      schema: schema,
      document: document,
      title: row['title'] as String?,
      revision: row['revision'] as int,
      createdAt: DateTime.fromMillisecondsSinceEpoch(row['created_at'] as int),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(row['updated_at'] as int),
      syncState: LocalSyncState.parse(row['sync_state'] as String),
      accountId: row['account_id'] as String?,
      serverNoteId: row['server_note_id'] as String?,
      serverRevision: row['server_revision'] as int?,
      serverOriginalRevisionId: row['server_original_revision_id'] as String?,
      serverTypedRevisionId: row['server_typed_revision_id'] as String?,
      preparedStudyId: row['prepared_study_id'] as String?,
      transcriptionSourceNoteId: row['transcription_source_note_id'] as String?,
      transcriptionRunId: row['transcription_run_id'] as String?,
      transcriptionSourceRevisionId:
          row['transcription_source_revision_id'] as String?,
      transcriptionSourceHash: row['transcription_source_hash'] as String?,
      transcriptionSourceLocalRevision:
          row['transcription_source_local_revision'] as int?,
      isConflictCopy: row['is_conflict_copy'] == 1,
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

  /// Item rows written by the last [save]: how far an autosave reached
  /// (annotations#19 measures that it follows the change, not the note).
  int lastSavedItems = 0;

  /// The stored body and hash of an item object: an unchanged item that the
  /// editor keeps (annotations#62) is not serialized again.
  final _bodies = Expando<(String, int)>('item bodies');

  @override
  Future<LocalNote> save(LocalNoteDraft draft) => _save(draft);

  @override
  Future<LocalNote> saveTypedForSource(
    LocalNoteDraft draft, {
    required String sourceNoteId,
    required String? targetOwnerId,
  }) => _save(
    draft,
    expectedTypedSourceNoteId: sourceNoteId,
    typedTargetOwnerId: targetOwnerId,
  );

  Future<LocalNote> _save(
    LocalNoteDraft draft, {
    String? expectedTypedSourceNoteId,
    String? typedTargetOwnerId,
  }) async {
    final document = draft.document;
    final List<(String, String, int)>? items;
    final String body;
    if (document is PaperDocument) {
      body = jsonEncode(document.toJsonWithoutItems());
      items = [
        for (final item in document.items)
          () {
            final cached = _bodies[item] ??= () {
              final text = jsonEncode(item.toJson());
              return (text, _hash(text));
            }();
            return (item.id!, cached.$1, cached.$2);
          }(),
      ];
    } else {
      body = jsonEncode(document.toJson());
      items = null;
    }
    final files = referencedFiles(draft.document);
    final now = DateTime.now().millisecondsSinceEpoch;
    _transaction(_db, () {
      if (expectedTypedSourceNoteId != null) {
        final existing = _db.select(
          'SELECT account_id, transcription_source_note_id FROM notes WHERE id = ?',
          [draft.id],
        );
        if (existing.isNotEmpty) {
          final sourceNoteId =
              existing.first['transcription_source_note_id'] as String?;
          final ownerId = existing.first['account_id'] as String?;
          if (sourceNoteId != expectedTypedSourceNoteId) {
            throw StateError('The Typed note id is used by another source.');
          }
          if (ownerId != null && ownerId != typedTargetOwnerId) {
            throw StateError('The Typed note belongs to another owner.');
          }
        }
      }
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
          revision, created_at, updated_at, sync_state, account_id,
          is_conflict_copy, transcription_source_note_id,
          transcription_run_id, transcription_source_revision_id,
          transcription_source_hash, transcription_source_local_revision)
        VALUES (?, ?, ?, ?, ?, 1, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT (id) DO UPDATE SET
          family = excluded.family,
          schema_version = excluded.schema_version,
          document = excluded.document,
          title = excluded.title,
          revision = notes.revision + 1,
          updated_at = excluded.updated_at,
          sync_state = CASE notes.sync_state
            WHEN ? THEN ? ELSE notes.sync_state END
          , transcription_source_note_id = COALESCE(
              excluded.transcription_source_note_id,
              notes.transcription_source_note_id)
          , transcription_run_id = COALESCE(
              excluded.transcription_run_id, notes.transcription_run_id)
          , transcription_source_revision_id = COALESCE(
              excluded.transcription_source_revision_id,
              notes.transcription_source_revision_id)
          , transcription_source_hash = COALESCE(
              excluded.transcription_source_hash,
              notes.transcription_source_hash)
          , transcription_source_local_revision = COALESCE(
              excluded.transcription_source_local_revision,
              notes.transcription_source_local_revision)
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
          draft.accountId,
          draft.isConflictCopy ? 1 : 0,
          draft.transcriptionSourceNoteId,
          draft.transcriptionRunId,
          draft.transcriptionSourceRevisionId,
          draft.transcriptionSourceHash,
          draft.transcriptionSourceLocalRevision,
          LocalSyncState.synced.code,
          LocalSyncState.changed.code,
        ],
      );
      if (items != null) _saveItems(draft.id, items);
      _db.execute('DELETE FROM note_attachments WHERE note_id = ?', [draft.id]);
      for (final id in files) {
        _db.execute(
          'INSERT INTO note_attachments (note_id, attachment_id) VALUES (?, ?)',
          [draft.id, id],
        );
      }
    });
    // The saved document is the draft's: only the metadata is read back, so
    // an autosave of a large note does not decode it again (annotations#19).
    final row = _db.select('SELECT * FROM notes WHERE id = ?', [draft.id]);
    return _note(row.first, document: draft.document);
  }

  /// Writes the item rows that differ from the stored ones: new or changed
  /// bodies, moved positions and removed items. Unchanged items are not
  /// written.
  void _saveItems(String noteId, List<(String, String, int)> items) {
    final stored = <String, (int, int)>{
      for (final row in _db.select(
        'SELECT item_id, position, hash FROM note_items WHERE note_id = ?',
        [noteId],
      ))
        row['item_id'] as String: (row['position'] as int, row['hash'] as int),
    };
    var written = 0;
    final upsert = _db.prepare(
      'INSERT INTO note_items (note_id, item_id, position, hash, body) '
      'VALUES (?, ?, ?, ?, ?) ON CONFLICT (note_id, item_id) DO UPDATE SET '
      'position = excluded.position, hash = excluded.hash, body = excluded.body',
    );
    final move = _db.prepare(
      'UPDATE note_items SET position = ? WHERE note_id = ? AND item_id = ?',
    );
    try {
      for (var i = 0; i < items.length; i++) {
        final (id, body, hash) = items[i];
        final before = stored.remove(id);
        if (before == null || before.$2 != hash) {
          upsert.execute([noteId, id, i, hash, body]);
          written++;
        } else if (before.$1 != i) {
          move.execute([i, noteId, id]);
          written++;
        }
      }
    } finally {
      upsert.close();
      move.close();
    }
    for (final id in stored.keys) {
      _db.execute('DELETE FROM note_items WHERE note_id = ? AND item_id = ?', [
        noteId,
        id,
      ]);
      written++;
    }
    lastSavedItems = written;
  }

  @override
  Future<void> setSync(
    String id, {
    required LocalSyncState state,
    required String? accountId,
    String? serverNoteId,
    int? serverRevision,
    String? serverOriginalRevisionId,
    String? serverTypedRevisionId,
  }) async {
    _db.execute(
      '''
      UPDATE notes SET
        sync_state = ?,
        server_note_id = CASE
          WHEN ? IS NULL THEN NULL
          WHEN account_id IS NOT NULL AND account_id != ? THEN ?
          ELSE COALESCE(?, server_note_id)
        END,
        server_revision = CASE
          WHEN ? IS NULL THEN NULL
          WHEN account_id IS NOT NULL AND account_id != ? THEN ?
          ELSE COALESCE(?, server_revision)
        END,
        server_original_revision_id = CASE
          WHEN ? IS NULL THEN NULL
          WHEN account_id IS NOT NULL AND account_id != ? THEN ?
          ELSE COALESCE(?, server_original_revision_id)
        END,
        server_typed_revision_id = CASE
          WHEN ? IS NULL THEN NULL
          WHEN account_id IS NOT NULL AND account_id != ? THEN ?
          ELSE COALESCE(?, server_typed_revision_id)
        END,
        prepared_study_id = CASE
          WHEN ? IS NULL THEN NULL
          WHEN account_id IS NOT NULL AND account_id != ? THEN NULL
          WHEN ? IS NOT NULL AND server_note_id IS NOT ? THEN NULL
          WHEN ? IS NOT NULL AND server_revision IS NOT ? THEN NULL
          ELSE prepared_study_id
        END,
        account_id = ?
      WHERE id = ?
      ''',
      [
        state.code,
        accountId,
        accountId,
        serverNoteId,
        serverNoteId,
        accountId,
        accountId,
        serverRevision,
        serverRevision,
        accountId,
        accountId,
        serverOriginalRevisionId,
        serverOriginalRevisionId,
        accountId,
        accountId,
        serverTypedRevisionId,
        serverTypedRevisionId,
        accountId,
        accountId,
        serverNoteId,
        serverNoteId,
        serverRevision,
        serverRevision,
        accountId,
        id,
      ],
    );
    if (_db.updatedRows == 0) throw LocalStoreException('missing_note', id);
  }

  @override
  Future<void> savePreparedStudyReference(
    String id, {
    required String accountId,
    required String serverNoteId,
    required int serverRevision,
    required String studyId,
  }) async {
    if (studyId.trim().isEmpty) {
      throw ArgumentError.value(studyId, 'studyId');
    }
    _db.execute(
      '''
      UPDATE notes SET prepared_study_id = ?
      WHERE id = ? AND account_id = ? AND server_note_id = ?
        AND server_revision = ? AND sync_state = ? AND is_conflict_copy = 0
      ''',
      [
        studyId,
        id,
        accountId,
        serverNoteId,
        serverRevision,
        LocalSyncState.synced.code,
      ],
    );
    if (_db.updatedRows == 0) {
      throw LocalStoreException('study_reference_conflict', id);
    }
  }

  @override
  Future<void> clearPreparedStudyReference(
    String id, {
    required String accountId,
    required String serverNoteId,
    required String studyId,
  }) async {
    _db.execute(
      '''
      UPDATE notes SET prepared_study_id = NULL
      WHERE id = ? AND account_id = ? AND server_note_id = ?
        AND prepared_study_id = ?
      ''',
      [id, accountId, serverNoteId, studyId],
    );
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

  /// Deletes only the local note row and its item/attachment links from SQLite.
  @override
  Future<void> deleteNote(String id) async {
    _transaction(_db, () {
      _db.execute('DELETE FROM note_items WHERE note_id = ?', [id]);
      _db.execute('DELETE FROM note_attachments WHERE note_id = ?', [id]);
      _db.execute('DELETE FROM notes WHERE id = ?', [id]);
    });
  }

  @override
  Future<void> close() async => _db.close();
}
