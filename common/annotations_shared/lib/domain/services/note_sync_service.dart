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

  const SyncResult.synced({
    required this.localNote,
    this.serverRevision,
  })  : isConflict = false,
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

/// Counts non-public/restricted report embeds in [document] before publishing.
int countRestrictedEmbeds(NoteDocument document) {
  var count = 0;
  void visit(Object? v) {
    if (v is Map) {
      if (v['kind'] == 'report_embed' || v['type'] == 'report_embed') {
        final vis = '${v['visibility'] ?? 'public'}';
        if (vis != 'public') count++;
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
/// headless typed-note API operations (annotations#37).
class NoteSyncService {
  final LocalNoteStore store;
  final ApiAdapter api;
  final Future<void> Function(String noteId)? onDeleteLocal;

  NoteSyncService({
    required this.store,
    required this.api,
    this.onDeleteLocal,
  });

  /// Returns only notes visible to [accountId]: unbound local notes (`accountId == null`)
  /// plus notes bound to [accountId]. Another account's notes are never exposed.
  Future<List<LocalNote>> notesForAccount(String? accountId) async {
    final all = await store.notes();
    return [
      for (final n in all)
        if (n.accountId == null || (accountId != null && n.accountId == accountId)) n,
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
  /// - First upload sends the whole document and binds [note] to [accountId].
  /// - Subsequent syncs compute `syncOperation(baseDocument, note.document)` and send
  ///   a compressed (`gzipBody`) incremental operation.
  /// - On 409 Conflict, keeps the local note untouched and saves the server version
  ///   as a separate conflict copy for review.
  Future<SyncResult> syncNote(
    LocalNote note, {
    required String accountId,
    NoteDocument? baseDocument,
    int? baseRevision,
  }) async {
    _requireOwner(note, accountId);

    final isFirstUpload = note.accountId == null || baseDocument == null;
    final op = isFirstUpload ? null : syncOperation(baseDocument, note.document);

    final path = isFirstUpload ? '/me/notes' : '/me/notes/${note.id}';
    final method = isFirstUpload ? 'POST' : 'PATCH';
    final payload = isFirstUpload
        ? <String, dynamic>{
            'note_id': note.id,
            'title': note.title,
            'schema': {'name': note.schema.name, 'version': note.schema.version},
            'document': note.document.toJson(),
          }
        : <String, dynamic>{
            'base_revision': baseRevision ?? note.revision,
            'title': note.title,
            if (op != null) 'operation': op else 'document': note.document.toJson(),
          };

    try {
      final resp = await api.request(
        path,
        method: method,
        body: payload,
        compress: true,
      );
      await store.setSync(note.id, state: LocalSyncState.synced, accountId: accountId);
      final updated = (await store.load(note.id)) ?? note;
      return SyncResult.synced(
        localNote: updated,
        serverRevision: (resp['revision'] as num?)?.toInt(),
      );
    } on ApiError catch (err) {
      if (err.status != 409) rethrow;
      final conflictId = '${note.id}__conflict_${DateTime.now().millisecondsSinceEpoch}';
      final remoteCopy = await store.save(
        LocalNoteDraft(
          id: conflictId,
          schema: note.schema,
          document: note.document,
          title: '${note.title ?? 'Untitled note'} (conflict copy)',
        ),
      );
      return SyncResult.conflict(localNote: note, conflictCopy: remoteCopy);
    }
  }

  /// Publishes [note] with [representation] (`original`, `typed`, or `both`).
  /// If restricted embeds exist and [allowRestrictedEmbeds] is false, returns a warning
  /// result with `published: false` and `restrictedEmbedCount`.
  Future<PublicationResult> publishNote(
    LocalNote note, {
    required String accountId,
    required PublicationRepresentation representation,
    bool allowRestrictedEmbeds = false,
  }) async {
    _requireOwner(note, accountId);
    final restricted = countRestrictedEmbeds(note.document);
    if (restricted > 0 && !allowRestrictedEmbeds) {
      return PublicationResult(published: false, restrictedEmbedCount: restricted);
    }

    final resp = await api.request(
      '/me/notes/${note.id}/publish',
      method: 'POST',
      body: {
        'representation': representation.code,
      },
      compress: true,
    );
    await store.setSync(note.id, state: LocalSyncState.synced, accountId: accountId);
    return PublicationResult(
      published: true,
      restrictedEmbedCount: restricted,
      response: resp,
    );
  }

  /// Deletion scope 1: removes only the local device copy.
  Future<void> deleteLocalCopy(String noteId) async {
    if (onDeleteLocal != null) {
      await onDeleteLocal!(noteId);
    }
  }

  /// Deletion scope 2: deletes the cloud note (optionally cascading owned Reports).
  Future<void> deleteCloudNote(
    String noteId, {
    required String accountId,
    bool cascadeOwnedReports = false,
  }) async {
    final existing = await store.load(noteId);
    if (existing != null) _requireOwner(existing, accountId);
    await api.request(
      '/me/notes/$noteId',
      method: 'DELETE',
      query: cascadeOwnedReports ? {'cascade_reports': 'true'} : null,
    );
    if (existing != null) {
      await store.setSync(noteId, state: LocalSyncState.local, accountId: null);
    }
  }

  /// Deletion scope 3: unpublishes the note while keeping cloud and local copies.
  Future<void> unpublishNote(String noteId, {required String accountId}) async {
    final existing = await store.load(noteId);
    if (existing != null) _requireOwner(existing, accountId);
    await api.request('/me/notes/$noteId/unpublish', method: 'POST');
  }

  /// Creates and publishes a typed note directly via the API without opening the editor.
  Future<Map<String, dynamic>> createAndPublishTypedNote({
    required String accountId,
    required String title,
    required List<Map<String, Object?>> blocks,
    PublicationRepresentation representation = PublicationRepresentation.typed,
  }) async {
    final created = await api.request(
      '/me/notes',
      method: 'POST',
      body: {
        'account_id': accountId,
        'title': title,
        'schema': {'name': DocumentFamily.typed.schemaName, 'version': 1},
        'document': {'blocks': blocks},
      },
      compress: true,
    );
    final noteId = '${created['note_id'] ?? created['id']}';
    return api.request(
      '/me/notes/$noteId/publish',
      method: 'POST',
      body: {'representation': representation.code},
      compress: true,
    );
  }
}

/// Local + synced project and tag catalog following backend normalization rules.
class ProjectTagCatalog {
  final Map<String, String> _projectsByNormalizedName = {};
  final Map<String, Set<String>> _tagsByNoteId = {};
  final Map<String, String> _projectByNoteId = {};

  static String normalizeProjectName(String name) => name.trim().toLowerCase();

  String createLocalProject(String id, String displayName) {
    final norm = normalizeProjectName(displayName);
    if (norm.isEmpty) throw ArgumentError('Project name cannot be empty');
    if (_projectsByNormalizedName.containsKey(norm)) {
      throw StateError('Duplicate project name: $displayName');
    }
    _projectsByNormalizedName[norm] = id;
    return id;
  }

  void assignNoteToProject(String noteId, String projectId) {
    _projectByNoteId[noteId] = projectId;
  }

  String? projectForNote(String noteId) => _projectByNoteId[noteId];

  void addTag(String noteId, String tag) {
    final clean = tag.trim().toLowerCase();
    if (clean.isEmpty) return;
    _tagsByNoteId.putIfAbsent(noteId, () => <String>{}).add(clean);
  }

  void removeTag(String noteId, String tag) {
    _tagsByNoteId[noteId]?.remove(tag.trim().toLowerCase());
  }

  Set<String> tagsForNote(String noteId) =>
      Set.unmodifiable(_tagsByNoteId[noteId] ?? const <String>{});

  Future<Map<String, dynamic>> syncNoteMetadata(ApiAdapter api, String noteId) =>
      api.request(
        '/me/notes/$noteId/metadata',
        method: 'PATCH',
        body: {
          'project_id': _projectByNoteId[noteId],
          'tags': tagsForNote(noteId).toList()..sort(),
        },
        compress: true,
      );
}
