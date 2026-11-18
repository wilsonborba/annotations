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

abstract interface class LocalNoteStore {
  /// The last complete saved state of the note [id], or null.
  Future<LocalNote?> load(String id);

  /// All saved notes, the most recently changed first.
  Future<List<LocalNote>> notes();

  /// Saves the complete note in one commit and returns the saved state. A
  /// synced note becomes [LocalSyncState.changed]. Throws
  /// [LocalStoreException] `missing_attachment` when the document references
  /// a file that the store does not hold; the previous state stays.
  Future<LocalNote> save(LocalNoteDraft draft);

  /// Records the sync state and the bound account of a saved note. Only the
  /// sync and publication flows call it (annotations#37).
  Future<void> setSync(
    String id, {
    required LocalSyncState state,
    required String? accountId,
  });

  /// Copies the file at [sourcePath] into the store. The copy is complete and
  /// flushed before it gets its id; later changes to the original file do not
  /// reach it.
  Future<LocalAttachment> importFile(String sourcePath, {required String type});

  /// Keeps [bytes] as a new managed file, as [importFile] does.
  Future<LocalAttachment> importBytes(
    Uint8List bytes, {
    required String name,
    required String type,
  });

  /// The managed file [id], or null when the store does not hold it.
  Future<LocalAttachment?> attachment(String id);

  /// The bytes of the managed file [id], or null.
  Future<Uint8List?> readAttachment(String id);

  /// Removes the managed file [id] when no saved note references it, for an
  /// import whose edit was rejected. A referenced file stays.
  Future<void> discardAttachment(String id);

  /// Closes the store. Pending saves must finish first.
  Future<void> close();
}
