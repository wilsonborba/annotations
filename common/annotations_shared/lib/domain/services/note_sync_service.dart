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

class CloudIdentityException implements Exception {
  final String message;
  CloudIdentityException(this.message);
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

final class ServerPublicationState {
  const ServerPublicationState({
    required this.published,
    required this.revision,
  });

  final bool published;
  final int revision;
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

  static (String?, String?) _parseRevisions(Map<String, dynamic> payload) {
    String? original;
    String? typed;
    final list = payload['revisions'] ?? payload['representations'];
    if (list is List) {
      for (final item in list) {
        if (item is! Map) continue;
        final rep = item['representation'] as String?;
        final revId = item['revision_id'] as String?;
        if (revId == null || revId.isEmpty) continue;
        if (rep == 'original') original = revId;
        if (rep == 'typed') typed = revId;
      }
    } else if (list is Map) {
      final origVal = list['original'];
      final typedVal = list['typed'];
      if (origVal is String && origVal.isNotEmpty) original = origVal;
      if (typedVal is String && typedVal.isNotEmpty) typed = typedVal;
    }
    return (original, typed);
  }

  static String _requireServerNoteId(Map<String, dynamic> payload) {
    final id = payload['note_id'];
    if (id is String && id.isNotEmpty) return id;
    throw CloudIdentityException('Server response is missing note_id.');
  }

  static (DocumentSchema, NoteDocument) _extractServerConflictDocument(
    Map<String, dynamic> serverResp,
    DocumentSchema fallbackSchema,
  ) {
    final rawReps = serverResp['representations'];
    if (rawReps is List && rawReps.isNotEmpty) {
      final preferredRep = fallbackSchema.family == DocumentFamily.typed
          ? 'typed'
          : 'original';
      final mainRep = serverResp['main_representation'] as String?;
      Map<String, dynamic>? chosen;
      for (final item in rawReps) {
        if (item is! Map) continue;
        final map = Map<String, dynamic>.from(item);
        if (map['document'] is! Map) continue;
        if (map['representation'] == preferredRep) {
          chosen = map;
          break;
        }
        chosen ??= (mainRep != null && map['representation'] == mainRep)
            ? map
            : null;
      }
      chosen ??= rawReps
          .whereType<Map>()
          .map(Map<String, dynamic>.from)
          .firstWhere(
            (m) => m['document'] is Map,
            orElse: () => <String, dynamic>{},
          );
      if (chosen['document'] is Map) {
        final rep = '${chosen['representation'] ?? 'original'}';
        final schemaName = rep == 'typed'
            ? DocumentFamily.typed.schemaName
            : DocumentFamily.original.schemaName;
        final schemaVersion =
            (chosen['schema_version'] as num?)?.toInt() ??
            fallbackSchema.version;
        final serverSchema = DocumentSchema(schemaName, schemaVersion);
        final serverDoc = NoteDocument.fromJson(
          Map<String, dynamic>.from(chosen['document'] as Map),
          schema: serverSchema,
        );
        return (serverSchema, serverDoc);
      }
    }

    final rawSchema = (serverResp['schema'] as Map?) ?? const {};
    final serverSchema = DocumentSchema(
      '${rawSchema['name'] ?? fallbackSchema.name}',
      (rawSchema['version'] as num?)?.toInt() ?? fallbackSchema.version,
    );
    final serverDoc = NoteDocument.fromJson(
      Map<String, dynamic>.from(serverResp['document'] as Map),
      schema: serverSchema,
    );
    return (serverSchema, serverDoc);
  }

  Future<LocalNote> _recoverMappingByClientId(
    LocalNote note,
    String accountId,
  ) async {
    String? cursor;
    while (true) {
      final resp = await api.request(
        '/me/notes',
        method: 'GET',
        query: {'limit': '100', 'cursor': ?cursor},
      );
      final items = (resp['items'] as List?) ?? const [];
      for (final rawItem in items) {
        if (rawItem is! Map) continue;
        final item = Map<String, dynamic>.from(rawItem);
        if (item['client_note_id'] != note.id) continue;
        final serverNoteId = _requireServerNoteId(item);
        final serverRevision = (item['revision'] as num?)?.toInt();
        final (origRevId, typedRevId) = _parseRevisions(item);
        await store.setSync(
          note.id,
          state: note.syncState,
          accountId: accountId,
          serverNoteId: serverNoteId,
          serverRevision: serverRevision,
          serverOriginalRevisionId: origRevId,
          serverTypedRevisionId: typedRevId,
        );
        return (await store.load(note.id)) ??
            LocalNote(
              id: note.id,
              schema: note.schema,
              document: note.document,
              title: note.title,
              revision: note.revision,
              createdAt: note.createdAt,
              updatedAt: note.updatedAt,
              syncState: note.syncState,
              accountId: accountId,
              serverNoteId: serverNoteId,
              serverRevision: serverRevision,
              serverOriginalRevisionId: origRevId,
              serverTypedRevisionId: typedRevId,
              preparedStudyId: note.preparedStudyId,
            );
      }
      final nextCursor = resp['next_cursor'] as String?;
      if (nextCursor == null || nextCursor.isEmpty || items.isEmpty) break;
      cursor = nextCursor;
    }
    throw CloudIdentityException(
      'Could not recover a cloud note mapping for ${note.id}.',
    );
  }

  Future<LocalNote> _resolveBoundIdentity(
    LocalNote note,
    String accountId, {
    bool requireRevision = false,
    bool allowRepresentationHydration = false,
    Set<String> requiredRepresentationRevisions = const {},
  }) async {
    var current = (await store.load(note.id)) ?? note;
    _requireOwner(current, accountId);
    if (current.isConflictCopy) {
      throw CloudIdentityException(
        'A server conflict copy has no reusable cloud identity and cannot be synced directly.',
      );
    }
    if (current.accountId == null && current.serverNoteId == null) {
      throw CloudIdentityException(
        'Note ${current.id} is not bound to the cloud yet.',
      );
    }
    if (current.serverNoteId == null) {
      current = await _recoverMappingByClientId(current, accountId);
    }
    bool hasRequiredRepresentationRevisions(LocalNote candidate) {
      for (final representation in requiredRepresentationRevisions) {
        if (representation == 'original' &&
            (candidate.serverOriginalRevisionId == null ||
                candidate.serverOriginalRevisionId!.isEmpty)) {
          return false;
        }
        if (representation == 'typed' &&
            (candidate.serverTypedRevisionId == null ||
                candidate.serverTypedRevisionId!.isEmpty)) {
          return false;
        }
      }
      return true;
    }

    final hasRevision = current.serverRevision != null;
    final hasRepresentationRevisions = hasRequiredRepresentationRevisions(
      current,
    );
    if ((!requireRevision || hasRevision) && hasRepresentationRevisions) {
      return current;
    }
    if (!hasRepresentationRevisions &&
        requiredRepresentationRevisions.isNotEmpty &&
        !allowRepresentationHydration) {
      throw CloudIdentityException(
        'Server detail for ${current.serverNoteId} is missing representation revision metadata.',
      );
    }
    final detail = await api.request(
      '/me/notes/${current.serverNoteId}',
      method: 'GET',
    );
    final rev = (detail['revision'] as num?)?.toInt();
    final serverRevision = rev ?? current.serverRevision;
    if (requireRevision && serverRevision == null) {
      throw CloudIdentityException(
        'Server detail for ${current.serverNoteId} is missing revision.',
      );
    }
    final (origRevId, typedRevId) = _parseRevisions(detail);
    final serverOriginalRevisionId = origRevId;
    final serverTypedRevisionId = typedRevId;
    for (final representation in requiredRepresentationRevisions) {
      final revisionId = switch (representation) {
        'original' => serverOriginalRevisionId,
        'typed' => serverTypedRevisionId,
        _ => null,
      };
      if (revisionId == null || revisionId.isEmpty) {
        throw CloudIdentityException(
          'Server detail for ${current.serverNoteId} is missing the $representation representation revision.',
        );
      }
    }
    await store.setSync(
      current.id,
      state: current.syncState,
      accountId: accountId,
      serverNoteId: current.serverNoteId,
      serverRevision: serverRevision,
      serverOriginalRevisionId: serverOriginalRevisionId,
      serverTypedRevisionId: serverTypedRevisionId,
    );
    return (await store.load(current.id)) ??
        LocalNote(
          id: current.id,
          schema: current.schema,
          document: current.document,
          title: current.title,
          revision: current.revision,
          createdAt: current.createdAt,
          updatedAt: current.updatedAt,
          syncState: current.syncState,
          accountId: accountId,
          serverNoteId: current.serverNoteId,
          serverRevision: serverRevision,
          serverOriginalRevisionId: serverOriginalRevisionId,
          serverTypedRevisionId: serverTypedRevisionId,
          preparedStudyId: current.preparedStudyId,
          isConflictCopy: current.isConflictCopy,
        );
  }

  /// Explicitly syncs [note] for [accountId].
  /// - First upload (`note.accountId == null`): `POST /me/notes` with full document
  ///   and `client_note_id: note.id`; persists returned server `note_id` and `revision`.
  /// - Subsequent syncs (`note.accountId != null`): resolves persisted (or
  ///   recovered via `GET /me/notes`) server `note_id` and `serverRevision`,
  ///   then sends `PATCH /me/notes/{serverNoteId}` or `PUT /me/notes/{serverNoteId}`
  ///   with `If-Match`. Never uses the local note id or local save counter.
  /// - Uses `gzipBody` (`compress: true`).
  /// - On `409 Conflict`, fetches the SERVER version via `GET /me/notes/{serverNoteId}`,
  ///   keeps the LOCAL note unchanged, and saves the SERVER document as a separate conflict copy.
  Future<SyncResult> syncNote(
    LocalNote note, {
    required String accountId,
    NoteDocument? baseDocument,
    int? baseRevision,
  }) async {
    _requireOwner(note, accountId);
    if (note.schema.family == DocumentFamily.typed &&
        note.transcriptionSourceNoteId != null) {
      return _syncTranscribedTyped(note, accountId: accountId);
    }

    final isFirstUpload = note.accountId == null && note.serverNoteId == null;
    final op = (!isFirstUpload && baseDocument != null)
        ? syncOperation(baseDocument, note.document)
        : null;

    final String path;
    final String method;
    final Map<String, String>? headers;
    final Map<String, dynamic> payload;
    String? knownServerNoteId;

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
      final identity = await _resolveBoundIdentity(
        note,
        accountId,
        requireRevision: baseRevision == null,
      );
      knownServerNoteId = identity.serverNoteId!;
      final rev = baseRevision ?? identity.serverRevision;
      if (rev == null) {
        throw CloudIdentityException(
          'Missing authoritative server revision for ${identity.id}.',
        );
      }
      path = '/me/notes/$knownServerNoteId';
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
      final serverNoteId = knownServerNoteId ?? _requireServerNoteId(resp);
      final serverRev = (resp['revision'] as num?)?.toInt();
      final (origRevId, typedRevId) = _parseRevisions(resp);
      await store.setSync(
        note.id,
        state: LocalSyncState.synced,
        accountId: accountId,
        serverNoteId: serverNoteId,
        serverRevision: serverRev,
        serverOriginalRevisionId: origRevId,
        serverTypedRevisionId: typedRevId,
      );
      final updated = (await store.load(note.id)) ?? note;
      return SyncResult.synced(localNote: updated, serverRevision: serverRev);
    } on ApiError catch (err) {
      if (err.status != 409 || knownServerNoteId == null) rethrow;
      // Fetch the authoritative server version; never overwrite the local note.
      final serverResp = await api.request(
        '/me/notes/$knownServerNoteId',
        method: 'GET',
      );
      final serverRev = (serverResp['revision'] as num?)?.toInt() ?? 1;
      final (serverSchema, serverDoc) = _extractServerConflictDocument(
        serverResp,
        note.schema,
      );
      final conflictIdBase = '${note.id}__conflict_$serverRev';
      var conflictId = conflictIdBase;
      var conflictSuffix = 1;
      while (await store.load(conflictId) != null) {
        conflictId = '${conflictIdBase}_$conflictSuffix';
        conflictSuffix++;
      }
      final savedCopy = await store.save(
        LocalNoteDraft(
          id: conflictId,
          schema: serverSchema,
          document: serverDoc,
          title:
              '${serverResp['title'] ?? note.title ?? 'Untitled note'} (server v$serverRev)',
          accountId: accountId,
          isConflictCopy: true,
        ),
      );
      return SyncResult.conflict(
        localNote: note,
        conflictCopy: savedCopy,
        serverRevision: serverRev,
      );
    }
  }

  Future<SyncResult> _syncTranscribedTyped(
    LocalNote typed, {
    required String accountId,
  }) async {
    final sourceId = typed.transcriptionSourceNoteId!;
    final runId = typed.transcriptionRunId;
    final acceptedAtLocalRevision = typed.transcriptionSourceLocalRevision;
    if (runId == null ||
        runId.trim().isEmpty ||
        acceptedAtLocalRevision == null) {
      throw CloudIdentityException(
        'Accepted Typed source metadata is incomplete for ${typed.id}.',
      );
    }
    var source = await store.load(sourceId);
    if (source == null ||
        source.schema.family != DocumentFamily.original ||
        source.revision != acceptedAtLocalRevision) {
      throw CloudIdentityException(
        'The Original changed after this Typed version was accepted.',
      );
    }
    _requireOwner(source, accountId);
    if (typed.transcriptionSourceRevisionId != null &&
        source.serverOriginalRevisionId !=
            typed.transcriptionSourceRevisionId) {
      throw CloudIdentityException(
        'The accepted source revision is no longer current.',
      );
    }
    if (source.accountId == null ||
        source.serverNoteId == null ||
        source.serverRevision == null ||
        source.serverOriginalRevisionId == null ||
        source.syncState != LocalSyncState.synced) {
      final sourceSync = await syncNote(source, accountId: accountId);
      if (sourceSync.isConflict) {
        throw CloudIdentityException(
          'The Original must sync before its Typed version.',
        );
      }
      source = await store.load(sourceId) ?? sourceSync.localNote;
    }
    _requireOwner(source, accountId);
    if (source.serverNoteId == null ||
        source.serverRevision == null ||
        source.serverOriginalRevisionId == null) {
      throw CloudIdentityException(
        'The Original is missing authoritative server revision metadata.',
      );
    }
    if (source.revision != acceptedAtLocalRevision) {
      throw CloudIdentityException(
        'The Original changed after this Typed version was accepted.',
      );
    }
    final response = await api.request(
      '/me/notes/${source.serverNoteId}',
      method: 'PUT',
      headers: {'if-match': '"${source.serverRevision}"'},
      body: {
        'representation': 'typed',
        'schema_version': typed.schema.version,
        'document': typed.document.toJson(),
        'source_revision_id': source.serverOriginalRevisionId,
      },
      compress: true,
    );
    final newServerRevision = (response['revision'] as num?)?.toInt();
    final (responseOriginalRevision, typedRevision) = _parseRevisions(response);
    final originalRevision =
        responseOriginalRevision ?? source.serverOriginalRevisionId;
    if (newServerRevision == null || typedRevision == null) {
      throw CloudIdentityException(
        'Typed sync response is missing authoritative revision metadata.',
      );
    }
    await store.setSync(
      source.id,
      state: LocalSyncState.synced,
      accountId: accountId,
      serverNoteId: source.serverNoteId,
      serverRevision: newServerRevision,
      serverOriginalRevisionId: originalRevision,
      serverTypedRevisionId: typedRevision,
    );
    await store.setSync(
      typed.id,
      state: LocalSyncState.synced,
      accountId: accountId,
      serverNoteId: source.serverNoteId,
      serverRevision: newServerRevision,
      serverOriginalRevisionId: originalRevision,
      serverTypedRevisionId: typedRevision,
    );
    final updated = await store.load(typed.id);
    if (updated == null) throw LocalStoreException('missing_note', typed.id);
    return SyncResult.synced(
      localNote: updated,
      serverRevision: newServerRevision,
    );
  }

  /// Publishes [note] via `PUT /me/notes/{serverNoteId}/publication` (`If-Match: <pubRev>`).
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

    var noteToPublish = note;
    var syncedLocalNote = false;
    if (note.accountId == null && note.serverNoteId == null) {
      final synced = await syncNote(note, accountId: accountId);
      if (synced.isConflict) {
        throw CloudIdentityException(
          'The note changed on the server and cannot be published until the conflict is resolved.',
        );
      }
      noteToPublish = synced.localNote;
      syncedLocalNote = true;
    }
    final requiredRepresentationRevisions = <String>{
      if ((representation == PublicationRepresentation.original ||
              representation == PublicationRepresentation.both) &&
          originalRevisionId == null)
        'original',
      if ((representation == PublicationRepresentation.typed ||
              representation == PublicationRepresentation.both) &&
          typedRevisionId == null)
        'typed',
    };
    final identity = await _resolveBoundIdentity(
      noteToPublish,
      accountId,
      allowRepresentationHydration: syncedLocalNote,
      requiredRepresentationRevisions: requiredRepresentationRevisions,
    );
    final serverNoteId = identity.serverNoteId!;
    final reps = <String, String>{};
    if (representation == PublicationRepresentation.original ||
        representation == PublicationRepresentation.both) {
      reps['original'] = _requireRepresentationRevision(
        originalRevisionId ?? identity.serverOriginalRevisionId,
        'original',
      );
    }
    if (representation == PublicationRepresentation.typed ||
        representation == PublicationRepresentation.both) {
      reps['typed'] = _requireRepresentationRevision(
        typedRevisionId ?? identity.serverTypedRevisionId,
        'typed',
      );
    }

    final resp = await api.request(
      '/me/notes/$serverNoteId/publication',
      method: 'PUT',
      headers: {'if-match': '"$publicationRevision"'},
      body: {'language': language, 'representations': reps},
      compress: true,
    );
    await store.setSync(
      note.id,
      state: LocalSyncState.synced,
      accountId: accountId,
      serverNoteId: serverNoteId,
      serverRevision: identity.serverRevision,
      serverOriginalRevisionId: identity.serverOriginalRevisionId,
      serverTypedRevisionId: identity.serverTypedRevisionId,
    );
    return PublicationResult(
      published: true,
      restrictedEmbedCount: restricted,
      response: resp,
    );
  }

  /// Reads the server-owned publication state and its If-Match revision.
  /// `null` means the note is currently unpublished; revision zero is only
  /// used when creating its first publication.
  Future<ServerPublicationState?> publicationState(
    LocalNote note, {
    required String accountId,
  }) async {
    if (note.accountId == null && note.serverNoteId == null) return null;
    final identity = await _resolveBoundIdentity(note, accountId);
    final serverNoteId = identity.serverNoteId;
    if (serverNoteId == null) return null;
    final response = await api.request('/me/notes/$serverNoteId/publication');
    final revision = response['revision'];
    if (revision is! int || revision < 0) {
      throw CloudIdentityException(
        'The server returned no authoritative publication revision.',
      );
    }
    return ServerPublicationState(
      published: response['published'] == true,
      revision: revision,
    );
  }

  static String _requireRepresentationRevision(String? revisionId, String rep) {
    if (revisionId == null || revisionId.isEmpty) {
      throw CloudIdentityException(
        'Missing authoritative $rep representation revision id.',
      );
    }
    return revisionId;
  }

  /// Deletion scope 1: removes only the local device copy from [store].
  Future<void> deleteLocalCopy(String noteId) async {
    if (store is DeletableLocalNoteStore) {
      await (store as DeletableLocalNoteStore).deleteNote(noteId);
    } else {
      throw UnsupportedError('Store does not support local note deletion');
    }
  }

  /// Deletion scope 2: deletes the cloud note via `DELETE /me/notes/{serverNoteId}`
  /// with `If-Match` and `?delete_owned_reports=true` when requested.
  Future<void> deleteCloudNote(
    String noteId, {
    required String accountId,
    int? expectedRevision,
    bool deleteOwnedReports = false,
  }) async {
    final existing = await store.load(noteId);
    if (existing == null) {
      throw CloudIdentityException(
        'Note $noteId does not exist locally to resolve its server identity.',
      );
    }
    final identity = await _resolveBoundIdentity(
      existing,
      accountId,
      requireRevision: expectedRevision == null,
    );
    final rev = expectedRevision ?? identity.serverRevision;
    if (rev == null) {
      throw CloudIdentityException(
        'Missing authoritative server revision for ${existing.id}.',
      );
    }
    await api.request(
      '/me/notes/${identity.serverNoteId}',
      method: 'DELETE',
      headers: {'if-match': '"$rev"'},
      query: deleteOwnedReports ? {'delete_owned_reports': 'true'} : null,
    );
    await store.setSync(noteId, state: LocalSyncState.local, accountId: null);
  }

  /// Deletion scope 3: unpublishes via `DELETE /me/notes/{serverNoteId}/publication`.
  Future<void> unpublishNote(
    String noteId, {
    required String accountId,
    required int publicationRevision,
  }) async {
    final existing = await store.load(noteId);
    if (existing == null) {
      throw CloudIdentityException(
        'Note $noteId does not exist locally to resolve its server identity.',
      );
    }
    final identity = await _resolveBoundIdentity(existing, accountId);
    await api.request(
      '/me/notes/${identity.serverNoteId}/publication',
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
    final noteId = _requireServerNoteId(created);
    final (_, parsedTypedRevId) = _parseRevisions(created);
    final repId = _requireRepresentationRevision(parsedTypedRevId, 'typed');
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

  /// Every project: id to display name (the workspace filter, #38).
  Map<String, String> get projects => Map.unmodifiable(_projectNamesById);

  /// Project names used by the currently scoped notes only.
  Map<String, String> projectsForNotes(Iterable<LocalNote> notes) {
    final ids = <String>{};
    for (final note in notes) {
      final id = _projectByNoteId[note.id];
      if (id != null) ids.add(id);
    }
    final names = <String, String>{};
    for (final id in ids) {
      final name = _projectNamesById[id];
      if (name != null) names[id] = name;
    }
    return Map.unmodifiable(names);
  }

  /// Every tag in use, sorted (the workspace filter, #38).
  List<String> get tags =>
      ({for (final t in _tagsByNoteId.values) ...t}.toList()..sort());

  /// Tags used by the currently scoped notes only.
  List<String> tagsForNotes(Iterable<LocalNote> notes) =>
      ({for (final note in notes) ...?_tagsByNoteId[note.id]}.toList()..sort());

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

  /// Syncs local catalog data for [note] through its server identity.
  /// Catalog entries use [LocalNote.id]; cloud routes use [LocalNote.serverNoteId].
  Future<void> syncProjectAndTags(
    ApiAdapter api, {
    required String accountId,
    required LocalNote note,
  }) async {
    final serverNoteId = note.serverNoteId;
    final serverRevision = note.serverRevision;
    if (note.accountId != accountId ||
        note.isConflictCopy ||
        serverNoteId == null ||
        serverRevision == null) {
      throw CloudIdentityException(
        'Project and tag sync needs this account to own a note with authoritative server identity and revision.',
      );
    }
    final projectId = _projectByNoteId[note.id];
    if (projectId != null) {
      final name = _projectNamesById[projectId] ?? projectId;
      await api.request(
        '/me/projects',
        method: 'POST',
        body: {'project_id': projectId, 'name': name},
      );
      await api.request(
        '/me/projects/$projectId/notes/$serverNoteId',
        method: 'PUT',
      );
    }
    await api.request(
      '/me/notes/$serverNoteId',
      method: 'PATCH',
      headers: {'if-match': '"$serverRevision"'},
      body: {
        'metadata': {'tags': tagsForNote(note.id).toList()..sort()},
      },
      compress: true,
    );
  }
}
