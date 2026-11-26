/// The files that an open paper editor reads and adds (annotations#44): the
/// managed copies of a local note ([LocalNoteStore]) or the files of an
/// Instant room. The editor, its cards and its clipboard use only this port.
library;

import 'dart:typed_data';

import '../models/local_note.dart';

abstract interface class EditorFiles {
  /// Keeps a copy of the file at [sourcePath] and returns it with its id.
  Future<LocalAttachment> importFile(String sourcePath, {required String type});

  /// Keeps [bytes] as a new file, as [importFile] does.
  Future<LocalAttachment> importBytes(
    Uint8List bytes, {
    required String name,
    required String type,
  });

  /// The file [id], or null when it is not available.
  Future<LocalAttachment?> attachment(String id);

  /// The bytes of the file [id], or null.
  Future<Uint8List?> readAttachment(String id);

  /// Drops the file [id] of an import whose edit was rejected. A referenced
  /// file stays.
  Future<void> discardAttachment(String id);
}
