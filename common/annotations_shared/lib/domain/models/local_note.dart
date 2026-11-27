/// A note kept on the device by the local store (D1, D2). The document body
/// is the versioned document of annotations#19; the other fields are store
/// metadata outside the body.
library;

import 'note_document.dart';

/// Where a local note stands against the private cloud (D2, H8.1). Nothing
/// moves to the cloud from this value: sync and publication are explicit user
/// actions (annotations#37).
enum LocalSyncState {
  /// Never synced. The note exists only on this device.
  local('local'),

  /// The local note matches its last synced cloud copy.
  synced('synced'),

  /// The note changed on this device after its last sync.
  changed('changed');

  const LocalSyncState(this.code);

  /// The stored value.
  final String code;

  static LocalSyncState parse(String code) =>
      values.firstWhere((s) => s.code == code, orElse: () => local);
}

/// The content of one save: the complete document and its title.
final class LocalNoteDraft {
  const LocalNoteDraft({
    required this.id,
    required this.schema,
    required this.document,
    this.title,
    this.accountId,
    this.transcriptionSourceNoteId,
    this.transcriptionRunId,
    this.transcriptionSourceRevisionId,
    this.transcriptionSourceHash,
    this.transcriptionSourceLocalRevision,
    this.isConflictCopy = false,
  });

  final String id;
  final DocumentSchema schema;
  final NoteDocument document;

  /// Null until the user names the note (D1.1: the page shows Untitled note).
  final String? title;

  /// Optional owner binding for a new local copy, such as a server conflict
  /// copy. Existing-note saves preserve the binding already stored.
  final String? accountId;

  /// Source/run identity for a separately stored accepted Typed version.
  final String? transcriptionSourceNoteId;
  final String? transcriptionRunId;
  final String? transcriptionSourceRevisionId;
  final String? transcriptionSourceHash;
  final int? transcriptionSourceLocalRevision;

  /// Marks a server conflict copy that has no cloud identity and cannot use
  /// client-id recovery as a later sync target.
  final bool isConflictCopy;
}

/// A saved note: the last complete state in the store.
final class LocalNote {
  const LocalNote({
    required this.id,
    required this.schema,
    required this.document,
    required this.title,
    required this.revision,
    required this.createdAt,
    required this.updatedAt,
    required this.syncState,
    required this.accountId,
    this.serverNoteId,
    this.serverRevision,
    this.serverOriginalRevisionId,
    this.serverTypedRevisionId,
    this.preparedStudyId,
    this.transcriptionSourceNoteId,
    this.transcriptionRunId,
    this.transcriptionSourceRevisionId,
    this.transcriptionSourceHash,
    this.transcriptionSourceLocalRevision,
    this.isConflictCopy = false,
  });

  final String id;
  final DocumentSchema schema;
  final NoteDocument document;
  final String? title;

  /// Local save counter: 1 after the first save, plus one for each save. It
  /// is not the server note revision.
  final int revision;
  final DateTime createdAt, updatedAt;
  final LocalSyncState syncState;

  /// The account that the note is bound to. Null until the first sync or
  /// publication (D1.5).
  final String? accountId;

  /// Server-generated note identifier assigned on first cloud upload, or null
  /// when local-only or after cloud deletion.
  final String? serverNoteId;

  /// Authoritative server sync revision used for `If-Match`, separate from the
  /// local save counter [revision].
  final int? serverRevision;

  /// Authoritative server representation revision ids returned by `/me/notes`
  /// and used for `PUT /me/notes/{id}/publication`.
  final String? serverOriginalRevisionId;
  final String? serverTypedRevisionId;

  /// Server-owned prepared Certifications study. Stored locally with the
  /// account-bound note metadata; its setup remains on the Certifications API.
  final String? preparedStudyId;

  /// Local relation for an accepted Typed transcription. Sync resolves the
  /// Original's authoritative revision before attaching this version.
  final String? transcriptionSourceNoteId;
  final String? transcriptionRunId;
  final String? transcriptionSourceRevisionId;
  final String? transcriptionSourceHash;
  final int? transcriptionSourceLocalRevision;

  /// True when this is an owner-bound local copy of a server conflict.
  final bool isConflictCopy;
}

/// A managed copy of an attachment in the app support folder. The note uses
/// [id] as its `file_id`; the copy never depends on the original file (H1.2).
final class LocalAttachment {
  const LocalAttachment({
    required this.id,
    required this.name,
    required this.type,
    required this.size,
    required this.path,
  });

  final String id;

  /// The original file name and media type, for file cards.
  final String name, type;

  /// Bytes.
  final int size;

  /// The absolute path of the managed copy.
  final String path;
}

/// A store failure. It has a code and an id, never note content.
final class LocalStoreException implements Exception {
  const LocalStoreException(this.code, [this.id]);

  /// `missing_attachment`: the document references a file that the store
  /// does not hold; `missing_note`: no note has the id; `unreadable_file`:
  /// the source file of an import cannot be read or copied; `newer_store`: a
  /// newer app version wrote the store.
  final String code;
  final String? id;

  @override
  String toString() => id == null ? code : '$code: $id';
}
