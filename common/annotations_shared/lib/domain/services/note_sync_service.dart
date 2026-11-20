import 'dart:convert';
import 'dart:io';

import '../models/local_note.dart';
import '../models/note_document.dart';
import '../../dal/remote/api_adapter.dart';
import 'local_note_store.dart';
import 'sync_operation.dart';

class AccountOwnershipException implements Exception {
  final String message;
  AccountOwnershipException(this.message);
  @override
  String toString() => message;
}

enum PublicationRepresentation {
  original('original'),
  typed('typed'),
  both('both');

  const PublicationRepresentation(this.code);
  final String code;
}

final class SyncResult {
  final bool isConflict;
  final LocalNote localNote;
  final LocalNote? conflictCopy;
  final int? serverRevision;

  const SyncResult.synced({required this.localNote, this.serverRevision})
    : isConflict = false,
      conflictCopy = null;

  const SyncResult.conflict({
    required this.localNote,
    required this.conflictCopy,
    this.serverRevision,
  }) : isConflict = true;
}

final class PublicationResult {
  final bool published;
  final int restrictedEmbedCount;
  final Map<String, dynamic>? response;

  const PublicationResult({
    required this.published,
    required this.restrictedEmbedCount,
    this.response,
  });
}

/// Store extension for deleting a local note copy without affecting cloud state.
abstract interface class DeletableLocalNoteStore implements LocalNoteStore {
  Future<void> deleteNote(String id);
}

/// Counts non-public/restricted embedded cards (`reports_embed`, `task_card`, `quiz_card`)
/// in [document] before publishing (annotations_api `lib/domain/publication.rs`).
int countRestrictedEmbeds(NoteDocument document) {
  const embedKinds = {
    'reports_embed',
    'report_embed',
    'task_card',
    'quiz_card',
  };
  var count = 0;
  void visit(Object? v) {
    if (v is Map) {
      final kind = '${v['kind'] ?? v['type'] ?? ''}';
      if (embedKinds.contains(kind)) {
        if (v['restricted'] == true ||
            '${v['visibility'] ?? 'restricted'}' != 'public') {
          count++;
        }
      }
      for (final val in v.values) {
        visit(val);
      }
    } else if (v is List) {
      for (final item in v) {
        visit(item);
      }
    }
  }

  visit(document.toJson());
  return count;
}

/// Explicit per-note sync, publication, account binding, deletion scopes, and
/// headless typed-note API operations aligned with `annotations_api/lib/presentation/notes.rs`
/// and `lib/domain/publication.rs` (annotations#37).
class NoteSyncService {
  final LocalNoteStore store;
  final ApiAdapter api;

  NoteSyncService({required this.store, required this.api});

  /// Returns only notes visible to [accountId]: unbound local notes (`accountId == null`)
  /// plus notes bound to [accountId]. Another account's notes are never exposed.
  Future<List<LocalNote>> notesForAccount(String? accountId) async {
    final all = await store.notes();
    return [
      for (final n in all)
        if (n.accountId == null ||
            (accountId != null && n.accountId == accountId))
          n,
    ];
  }

  void _requireOwner(LocalNote note, String accountId) {
    if (note.accountId != null && note.accountId != accountId) {
      throw AccountOwnershipException(
        'Note ${note.id} is bound to another account and cannot be taken over.',
      );
    }
  }

  /// Explicitly syncs [note] for [accountId].
  /// - First upload (`note.accountId == null`): `POST /me/notes` with full document.
  /// - Subsequent syncs (`note.accountId != null`): `PATCH /me/notes/{id}` (with `syncOperation`
  ///   when [baseDocument] is present) or `PUT /me/notes/{id}`, always sending `If-Match`.
  /// - Uses `gzipBody` (`compress: true`).
  /// - On `409 Conflict`, fetches the SERVER version via `GET /me/notes/{id}`, keeps the
  ///   LOCAL note unchanged, and saves the SERVER document as a separate conflict copy.
  Future<SyncResult> syncNote(
    LocalNote note, {
    required String accountId,
    NoteDocument? baseDocument,
    int? baseRevision,
  }) async {
    _requireOwner(note, accountId);

    final isFirstUpload = note.accountId == null;
    final op = (!isFirstUpload && baseDocument != null)
        ? syncOperation(baseDocument, note.document)
        : null;

    final String path;
    final String method;
    final Map<String, String>? headers;
    final Map<String, dynamic> payload;

    final repKey = note.schema.family == DocumentFamily.typed
        ? 'typed'
        : 'original';
    final usePatch =
        op != null && note.schema.family == DocumentFamily.original;

    if (isFirstUpload) {
      path = '/me/notes';
      method = 'POST';
      headers = null;
      payload = {
        'client_note_id': note.id,
        'main_representation': repKey,
        if (note.title != null && note.title!.trim().isNotEmpty)
          'metadata': {'title': note.title},
        'representations': {
          repKey: {
            'schema_version': note.schema.version,
            'document': note.document.toJson(),
          },
        },
      };
    } else {
      final rev = baseRevision ?? note.revision;
      path = '/me/notes/${note.id}';
      method = usePatch ? 'PATCH' : 'PUT';
      headers = {'if-match': '"$rev"'};
      payload = usePatch
          ? {
              'original': op,
              if (note.title != null && note.title!.trim().isNotEmpty)
                'metadata': {'title': note.title},
            }
          : {
              'representation': repKey,
              'schema_version': note.schema.version,
              'document': note.document.toJson(),
            };
    }

    try {
      final resp = await api.request(
        path,
        method: method,
        body: payload,
        headers: headers,
        compress: true,
      );
      await store.setSync(
        note.id,
        state: LocalSyncState.synced,
        accountId: accountId,
      );
      final updated = (await store.load(note.id)) ?? note;
      return SyncResult.synced(
        localNote: updated,
        serverRevision: (resp['revision'] as num?)?.toInt(),
      );
    } on ApiError catch (err) {
      if (err.status != 409) rethrow;
      // Fetch the authoritative server version; never overwrite the local note.
      final serverResp = await api.request(
        '/me/notes/${note.id}',
        method: 'GET',
      );
      final serverRev = (serverResp['revision'] as num?)?.toInt() ?? 1;
      final rawSchema = (serverResp['schema'] as Map?) ?? const {};
      final serverSchema = DocumentSchema(
        '${rawSchema['name'] ?? note.schema.name}',
        (rawSchema['version'] as num?)?.toInt() ?? note.schema.version,
      );
      final serverDoc = NoteDocument.fromJson(
        Map<String, dynamic>.from(serverResp['document'] as Map),
        schema: serverSchema,
      );
      final conflictId = '${note.id}__conflict_$serverRev';
      final serverCopy = await store.save(
        LocalNoteDraft(
          id: conflictId,
          schema: serverSchema,
          document: serverDoc,
          title:
              '${serverResp['title'] ?? note.title ?? 'Untitled note'} (server v$serverRev)',
        ),
      );
      return SyncResult.conflict(
        localNote: note,
        conflictCopy: serverCopy,
        serverRevision: serverRev,
      );
    }
  }

  /// Publishes [note] via `PUT /me/notes/{note_id}/publication` (`If-Match: <pubRev>`).
  /// When restricted embeds exist and [allowRestrictedEmbeds] is false, returns a warning
  /// result with `published: false` and `restrictedEmbedCount`.
  Future<PublicationResult> publishNote(
    LocalNote note, {
    required String accountId,
    required PublicationRepresentation representation,
    int publicationRevision = 0,
    bool allowRestrictedEmbeds = false,
    String language = 'en',
    String? originalRevisionId,
    String? typedRevisionId,
  }) async {
    _requireOwner(note, accountId);
    final restricted = countRestrictedEmbeds(note.document);
    if (restricted > 0 && !allowRestrictedEmbeds) {
      return PublicationResult(
        published: false,
        restrictedEmbedCount: restricted,
      );
    }

    final reps = <String, String>{};
    if (representation == PublicationRepresentation.original ||
        representation == PublicationRepresentation.both) {
      reps['original'] = originalRevisionId ?? '${note.revision}';
    }
    if (representation == PublicationRepresentation.typed ||
        representation == PublicationRepresentation.both) {
      reps['typed'] = typedRevisionId ?? '${note.revision}';
    }

    final resp = await api.request(
      '/me/notes/${note.id}/publication',
      method: 'PUT',
      headers: {'if-match': '"$publicationRevision"'},
      body: {'language': language, 'representations': reps},
      compress: true,
    );
    await store.setSync(
      note.id,
      state: LocalSyncState.synced,
      accountId: accountId,
    );
    return PublicationResult(
      published: true,
      restrictedEmbedCount: restricted,
      response: resp,
    );
  }

  /// Deletion scope 1: removes only the local device copy from [store].
  Future<void> deleteLocalCopy(String noteId) async {
    if (store is DeletableLocalNoteStore) {
      await (store as DeletableLocalNoteStore).deleteNote(noteId);
    } else {
      throw UnsupportedError('Store does not support local note deletion');
    }
  }

  /// Deletion scope 2: deletes the cloud note via `DELETE /me/notes/{note_id}`
  /// with `If-Match` and `?delete_owned_reports=true` when requested.
  Future<void> deleteCloudNote(
    String noteId, {
    required String accountId,
    required int expectedRevision,
    bool deleteOwnedReports = false,
  }) async {
    final existing = await store.load(noteId);
    if (existing != null) _requireOwner(existing, accountId);
    await api.request(
      '/me/notes/$noteId',
      method: 'DELETE',
      headers: {'if-match': '"$expectedRevision"'},
      query: deleteOwnedReports ? {'delete_owned_reports': 'true'} : null,
    );
    if (existing != null) {
      await store.setSync(noteId, state: LocalSyncState.local, accountId: null);
    }
  }

  /// Deletion scope 3: unpublishes via `DELETE /me/notes/{note_id}/publication`.
  Future<void> unpublishNote(
    String noteId, {
    required String accountId,
    required int publicationRevision,
  }) async {
    final existing = await store.load(noteId);
    if (existing != null) _requireOwner(existing, accountId);
    await api.request(
      '/me/notes/$noteId/publication',
      method: 'DELETE',
      headers: {'if-match': '"$publicationRevision"'},
    );
  }

  /// Creates and publishes a typed note directly via the API without opening the editor.
  /// Never sends `account_id` in the body (identity comes from the gateway).
  Future<Map<String, dynamic>> createAndPublishTypedNote({
    required String title,
    required List<Map<String, Object?>> blocks,
    PublicationRepresentation representation = PublicationRepresentation.typed,
    String language = 'en',
    String? clientNoteId,
  }) async {
    final cid =
        clientNoteId ?? 'typed_${DateTime.now().microsecondsSinceEpoch}';
    final created = await api.request(
      '/me/notes',
      method: 'POST',
      body: {
        'client_note_id': cid,
        'main_representation': 'typed',
        'metadata': {'title': title},
        'representations': {
          'typed': {
            'schema_version': 1,
            'document': {'blocks': blocks},
          },
        },
      },
      compress: true,
    );
    final noteId = '${created['note_id'] ?? created['id']}';
    final repId =
        '${created['typed_revision_id'] ?? created['revision_id'] ?? created['revision'] ?? 1}';
    return api.request(
      '/me/notes/$noteId/publication',
      method: 'PUT',
      headers: const {'if-match': '"0"'},
      body: {
        'language': language,
        'representations': {'typed': repId},
      },
      compress: true,
    );
  }
}

/// Persistent local + synced project and tag catalog (`annotations_api/lib/presentation/projects.rs`).
class ProjectTagCatalog {
  final File? persistenceFile;
  final Map<String, String> _projectsByNormalizedName = {};
  final Map<String, String> _projectNamesById = {};
  final Map<String, Set<String>> _tagsByNoteId = {};
  final Map<String, String> _projectByNoteId = {};

  ProjectTagCatalog({this.persistenceFile}) {
    _loadFromDisk();
  }

  static String normalizeProjectName(String name) => name.trim().toLowerCase();

  void _loadFromDisk() {
    final f = persistenceFile;
    if (f == null || !f.existsSync()) return;
    final raw = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
    final projs = (raw['projects'] as Map?) ?? const {};
    for (final e in projs.entries) {
      final id = '${e.key}';
      final name = '${e.value}';
      _projectNamesById[id] = name;
      _projectsByNormalizedName[normalizeProjectName(name)] = id;
    }
    final noteProjs = (raw['note_projects'] as Map?) ?? const {};
    for (final e in noteProjs.entries) {
      _projectByNoteId['${e.key}'] = '${e.value}';
    }
    final noteTags = (raw['note_tags'] as Map?) ?? const {};
    for (final e in noteTags.entries) {
      _tagsByNoteId['${e.key}'] = ((e.value as List?) ?? const [])
          .map((t) => '$t')
          .toSet();
    }
  }

  void _saveToDisk() {
    final f = persistenceFile;
    if (f == null) return;
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(
      jsonEncode({
        'projects': _projectNamesById,
        'note_projects': _projectByNoteId,
        'note_tags': {
          for (final e in _tagsByNoteId.entries)
            e.key: (e.value.toList()..sort()),
        },
      }),
    );
  }

  String createLocalProject(String id, String displayName) {
    final norm = normalizeProjectName(displayName);
    if (norm.isEmpty) throw ArgumentError('Project name cannot be empty');
    if (_projectsByNormalizedName.containsKey(norm)) {
      throw StateError('Duplicate project name: $displayName');
    }
    _projectsByNormalizedName[norm] = id;
    _projectNamesById[id] = displayName.trim();
    _saveToDisk();
    return id;
  }

  void assignNoteToProject(String noteId, String projectId) {
    _projectByNoteId[noteId] = projectId;
    _saveToDisk();
  }

  String? projectForNote(String noteId) => _projectByNoteId[noteId];

  void addTag(String noteId, String tag) {
    final clean = tag.trim().toLowerCase();
    if (clean.isEmpty) return;
    _tagsByNoteId.putIfAbsent(noteId, () => <String>{}).add(clean);
    _saveToDisk();
  }

  void removeTag(String noteId, String tag) {
    _tagsByNoteId[noteId]?.remove(tag.trim().toLowerCase());
    _saveToDisk();
  }

  Set<String> tagsForNote(String noteId) =>
      Set.unmodifiable(_tagsByNoteId[noteId] ?? const <String>{});

  Future<void> syncProjectAndTags(
    ApiAdapter api, {
    required String noteId,
    required int noteRevision,
  }) async {
    final projectId = _projectByNoteId[noteId];
    if (projectId != null) {
      final name = _projectNamesById[projectId] ?? projectId;
      await api.request(
        '/me/projects',
        method: 'POST',
        body: {'project_id': projectId, 'name': name},
      );
      await api.request('/me/projects/$projectId/notes/$noteId', method: 'PUT');
    }
    await api.request(
      '/me/notes/$noteId',
      method: 'PATCH',
      headers: {'if-match': '"$noteRevision"'},
      body: {
        'metadata': {'tags': tagsForNote(noteId).toList()..sort()},
      },
      compress: true,
    );
  }
}
