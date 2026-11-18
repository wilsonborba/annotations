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
  });

  final String id;
  final DocumentSchema schema;
  final NoteDocument document;

  /// Null until the user names the note (D1.1: the page shows Untitled note).
  final String? title;
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
