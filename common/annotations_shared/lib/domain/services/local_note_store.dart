/// The port of the local note store (D2, technical decision 12). The SQLite
/// adapter in `dal/local` implements it; tests pass a double.
///
/// Rules that every implementation keeps:
/// 1. [LocalNoteStore.save] returns only after the note and its file
///    references are committed. Saved shows only then (D2.3, H8.7).
/// 2. A save whose document references a file that the store does not hold
///    fails and keeps the previous saved state (D2.4).
/// 3. After a crash, [LocalNoteStore.load] gives the last complete saved
///    state, never a partial one.
/// 4. Attachments are managed copies. The store never reads the original file
///    again after the import (H1.2).
/// 5. Nothing in the store leaves the device: no implementation sends,
///    uploads or logs note content (D2.1, D2.5).
library;

import 'dart:typed_data';

import '../models/local_note.dart';
import 'editor_files.dart';
import '../models/note_document.dart';

/// Item fields that reference a stored file.
const noteFileFields = {'file_id', 'preview_file_id'};

/// Every file id that [document] references, nested items included.
Set<String> referencedFiles(NoteDocument document) {
  final ids = <String>{};
  void visit(Object? value) {
    if (value is Map) {
      for (final MapEntry(:key, :value) in value.entries) {
        if (noteFileFields.contains(key) && value is String) {
          ids.add(value);
        } else {
          visit(value);
        }
      }
    } else if (value is List) {
      value.forEach(visit);
    }
  }

  visit(document.toJson());
  return ids;
}

abstract interface class LocalNoteStore implements EditorFiles {
  /// The last complete saved state of the note [id], or null.
  Future<LocalNote?> load(String id);

  /// All saved notes, the most recently changed first.
  Future<List<LocalNote>> notes();

  /// Saves the complete note in one commit and returns the saved state. A
  /// synced note becomes [LocalSyncState.changed]. Throws
  /// [LocalStoreException] `missing_attachment` when the document references
  /// a file that the store does not hold; the previous state stays. A new
  /// draft may bind an owner-only copy to an account in the same commit.
  Future<LocalNote> save(LocalNoteDraft draft);

  /// Records the sync state, bound account, and optional server note identity
  /// and authoritative revisions of a saved note. Passing `accountId: null`
  /// clears all stored cloud identity and revision metadata.
  Future<void> setSync(
    String id, {
    required LocalSyncState state,
    required String? accountId,
    String? serverNoteId,
    int? serverRevision,
    String? serverOriginalRevisionId,
    String? serverTypedRevisionId,
  });

  /// Saves a prepared study reference only while this note still belongs to
  /// [accountId] and has the expected server note and revision.
  Future<void> savePreparedStudyReference(
    String id, {
    required String accountId,
    required String serverNoteId,
    required int serverRevision,
    required String studyId,
  });

  /// Clears only the matching prepared study for the same owner and note.
  Future<void> clearPreparedStudyReference(
    String id, {
    required String accountId,
    required String serverNoteId,
    required String studyId,
  });

  /// Copies the file at [sourcePath] into the store. The copy is complete and
  /// flushed before it gets its id; later changes to the original file do not
  /// reach it.
  @override
  Future<LocalAttachment> importFile(String sourcePath, {required String type});

  /// Keeps [bytes] as a new managed file, as [importFile] does.
  @override
  Future<LocalAttachment> importBytes(
    Uint8List bytes, {
    required String name,
    required String type,
  });

  /// The managed file [id], or null when the store does not hold it.
  @override
  Future<LocalAttachment?> attachment(String id);

  /// The bytes of the managed file [id], or null.
  @override
  Future<Uint8List?> readAttachment(String id);

  /// Removes the managed file [id] when no saved note references it, for an
  /// import whose edit was rejected. A referenced file stays.
  @override
  Future<void> discardAttachment(String id);

  /// Closes the store. Pending saves must finish first.
  Future<void> close();
}

/// A local store that can atomically verify Typed-pair ownership and persist
/// the accepted representation in the same transaction.
abstract interface class AtomicTypedNoteStore {
  Future<LocalNote> saveTypedForSource(
    LocalNoteDraft draft, {
    required String sourceNoteId,
    required String? targetOwnerId,
    required int expectedSourceRevision,
    required String? expectedServerSourceRevisionId,
  });
}

/// Optional metadata-only capability for stores that persist source-link
/// delivery separately from paper content and autosave revision numbers.
abstract interface class StudySourceMetadataStore {
  Future<void> setStudySourceRelationAttached(String id, bool attached);
}
