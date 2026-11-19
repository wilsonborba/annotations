import 'dart:convert';
import 'dart:typed_data';

import '../models/local_note.dart';
import '../models/note_document.dart';
import 'local_note_store.dart';

/// Complete editable backup export and restore (annotations#37 scope 7).
/// A PDF is not a backup; this package includes the full document and every
/// referenced attachment.
class NoteBackupService {
  static const int formatVersion = 1;

  /// Exports [noteId] and every referenced attachment from [store] as a JSON
  /// backup package.
  Future<String> exportPackage(LocalNoteStore store, String noteId) async {
    final note = await store.load(noteId);
    if (note == null) {
      throw StateError('Cannot export missing note: $noteId');
    }
    final fileIds = referencedFiles(note.document);
    final files = <Map<String, Object?>>[];
    for (final fid in fileIds) {
      final meta = await store.attachment(fid);
      final bytes = await store.readAttachment(fid);
      if (meta == null || bytes == null) {
        throw StateError('Missing attachment $fid referenced by note $noteId');
      }
      files.add({
        'id': meta.id,
        'name': meta.name,
        'type': meta.type,
        'bytes_base64': base64Encode(bytes),
      });
    }

    return jsonEncode({
      'format_version': formatVersion,
      'note': {
        'id': note.id,
        'title': note.title,
        'schema_name': note.schema.name,
        'schema_version': note.schema.version,
        'document': note.document.toJson(),
      },
      'files': files,
    });
  }

  /// Restores a backup package into [store] as a separate local note by default
  /// (unbound to any cloud account).
  Future<LocalNote> restorePackage(
    LocalNoteStore store,
    String packageJson, {
    String? newNoteId,
  }) async {
    final decoded = jsonDecode(packageJson) as Map<String, dynamic>;
    final noteMap = Map<String, dynamic>.from(decoded['note'] as Map);
    final rawFiles = (decoded['files'] as List?) ?? const [];

    final idMap = <String, String>{};
    for (final item in rawFiles) {
      final f = Map<String, dynamic>.from(item as Map);
      final oldId = '${f['id']}';
      final bytes = Uint8List.fromList(base64Decode('${f['bytes_base64']}'));
      final imported = await store.importBytes(
        bytes,
        name: '${f['name']}',
        type: '${f['type']}',
      );
      idMap[oldId] = imported.id;
    }

    var docJsonStr = jsonEncode(noteMap['document']);
    for (final entry in idMap.entries) {
      docJsonStr = docJsonStr.replaceAll(jsonEncode(entry.key), jsonEncode(entry.value));
    }
    final schema = DocumentSchema(
      '${noteMap['schema_name'] ?? DocumentFamily.original.schemaName}',
      (noteMap['schema_version'] as num?)?.toInt() ?? 1,
    );
    final remappedDoc = NoteDocument.fromJson(
      jsonDecode(docJsonStr) as Map<String, dynamic>,
      schema: schema,
    );

    final restoredId =
        newNoteId ?? '${noteMap['id']}_restored_${DateTime.now().millisecondsSinceEpoch}';
    return store.save(
      LocalNoteDraft(
        id: restoredId,
        schema: schema,
        document: remappedDoc,
        title: noteMap['title'] as String?,
      ),
    );
  }
}
