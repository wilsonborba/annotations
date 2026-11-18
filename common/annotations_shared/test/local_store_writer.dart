/// A separate process for the kill test of local_store_test.dart. It saves
/// version 1, 2, 3 ... of one note in the store folder of the first argument,
/// each version with a new attachment, until the test kills it. It prints
/// `begin <n>` before and `done <n>` after each save.
///
/// It imports no Flutter code, so `dart run` can start it.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:annotations_shared/dal/local/sqlite_note_store.dart';
import 'package:annotations_shared/domain/models/local_note.dart';
import 'package:annotations_shared/domain/models/note_document.dart';

const noteId = 'kill-note';
final schema = DocumentSchema('note-original', 1);

/// Text items per version and characters per item: about 2.5 MB per save, so
/// a kill often lands inside the commit.
const itemCount = 250;
const textLength = 10000;

/// The attachment bytes of version [n].
Uint8List attachmentBytes(int n) =>
    Uint8List.fromList(List.generate(256 * 1024, (i) => (i * 7 + n) % 256));

/// Version [n] of the note: every text item and the image name [n].
LocalNoteDraft version(int n, String fileId) => LocalNoteDraft(
  id: noteId,
  schema: schema,
  title: 'Version $n',
  document: NoteDocument.fromJson({
    'page': {
      'width': 1000,
      'background': {'kind': 'blank'},
    },
    'items': [
      for (var i = 0; i < itemCount; i++)
        {
          'id': 't$i',
          'kind': 'text',
          'x': 0,
          'y': i * 40,
          'width': 900,
          'height': 40,
          'spans': [
            {'text': 'v$n;'.padRight(textLength, 'x')},
          ],
        },
      {
        'id': 'image',
        'kind': 'image',
        'x': 0,
        'y': itemCount * 40,
        'width': 100,
        'height': 100,
        'file_id': fileId,
      },
    ],
  }, schema: schema),
);

Future<void> main(List<String> args) async {
  final store = await SqliteNoteStore.open(args.first);
  for (var n = 1; ; n++) {
    final file = await store.importBytes(
      attachmentBytes(n),
      name: 'v$n.bin',
      type: 'application/octet-stream',
    );
    stdout.writeln('begin $n');
    await stdout.flush();
    await store.save(version(n, file.id));
    stdout.writeln('done $n');
    await stdout.flush();
  }
}
