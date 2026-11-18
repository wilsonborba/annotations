import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:annotations_shared/core/local_store_settings.dart';
import 'package:annotations_shared/dal/local/local_clipboard_files.dart';
import 'package:annotations_shared/dal/local/sqlite_note_store.dart';
import 'package:annotations_shared/domain/models/local_note.dart';
import 'package:annotations_shared/domain/models/note_document.dart';
import 'package:annotations_shared/domain/services/local_note_store.dart';
import 'package:annotations_shared/domain/services/note_autosave.dart';
import 'package:flutter_test/flutter_test.dart';

final schema = DocumentSchema('note-original', 1);

LocalNoteDraft draft(String text) => LocalNoteDraft(
  id: 'n1',
  schema: schema,
  document: NoteDocument.fromJson({
    'page': {
      'width': 1000,
      'background': {'kind': 'blank'},
    },
    'items': [
      {
        'id': 't1',
        'kind': 'text',
        'x': 0,
        'y': 0,
        'width': 300,
        'height': 40,
        'spans': [
          {'text': text},
        ],
      },
    ],
  }, schema: schema),
);

String textOf(NoteDocument document) =>
    ((document.toJson()['items'] as List).first as Map)['spans'].toString();

/// A store whose saves wait until the test commits or fails them.
final class SlowStore implements LocalNoteStore {
  final calls = <(LocalNoteDraft, Completer<void>)>[];

  void commit() => calls.removeAt(0).$2.complete();
  void fail() =>
      calls.removeAt(0).$2.completeError(const LocalStoreException('disk'));

  @override
  Future<LocalNote> save(LocalNoteDraft draft) async {
    final done = Completer<void>();
    calls.add((draft, done));
    await done.future;
    return LocalNote(
      id: draft.id,
      schema: draft.schema,
      document: draft.document,
      title: draft.title,
      revision: 1,
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
      syncState: LocalSyncState.local,
      accountId: null,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Lets timers and pending futures run.
Future<void> pause([int ms = 40]) =>
    Future<void>.delayed(Duration(milliseconds: ms));

void main() {
  const settings = LocalStoreSettings(
    autosaveDelay: Duration(milliseconds: 20),
  );
  late SlowStore store;
  late NoteAutosave autosave;
  setUp(() {
    store = SlowStore();
    autosave = NoteAutosave(store, settings: settings);
  });
  tearDown(() => autosave.dispose());

  test('edits in the pause join one save; Saved only after commit', () async {
    final states = <SaveState>[];
    autosave.state.addListener(() => states.add(autosave.state.value));
    autosave.edited(draft('a'));
    autosave.edited(draft('ab'));
    autosave.edited(draft('abc'));
    expect(autosave.state.value, SaveState.saving);
    await pause();
    expect(store.calls, hasLength(1));
    expect(textOf(store.calls.single.$1.document), contains('abc'));
    // The store has not committed yet.
    expect(autosave.state.value, SaveState.saving);
    await pause();
    expect(autosave.state.value, SaveState.saving);
    store.commit();
    await pause(1);
    expect(autosave.state.value, SaveState.saved);
    expect(autosave.pending, isNull);
    expect(textOf(autosave.saved!.document), contains('abc'));
    expect(states.last, SaveState.saved);
    expect(states.where((s) => s == SaveState.saved), hasLength(1));
  });

  test('an edit during a save is saved after it', () async {
    autosave.edited(draft('a'));
    await pause();
    autosave.edited(draft('ab'));
    store.commit();
    await pause(1);
    // The newer edit is not committed: still Saving.
    expect(autosave.state.value, SaveState.saving);
    await pause();
    expect(store.calls, hasLength(1));
    expect(textOf(store.calls.single.$1.document), contains('ab'));
    store.commit();
    await pause(1);
    expect(autosave.state.value, SaveState.saved);
  });

  test('a failure keeps the pending note and Retry saves it', () async {
    autosave.edited(draft('keep me'));
    await pause();
    store.fail();
    await pause(1);
    expect(autosave.state.value, SaveState.failed);
    expect(textOf(autosave.pending!.document), contains('keep me'));
    // No automatic save after a failure: the user chooses Retry.
    await pause();
    expect(store.calls, isEmpty);

    final retry = autosave.retry();
    await pause(1);
    expect(autosave.state.value, SaveState.saving);
    expect(textOf(store.calls.single.$1.document), contains('keep me'));
    store.commit();
    await retry;
    expect(autosave.state.value, SaveState.saved);
    expect(autosave.pending, isNull);
  });

  test('a new edit after a failure saves the newest note', () async {
    autosave.edited(draft('first'));
    await pause();
    autosave.edited(draft('second'));
    store.fail();
    await pause(1);
    expect(autosave.state.value, SaveState.failed);
    expect(textOf(autosave.pending!.document), contains('second'));
    autosave.edited(draft('third'));
    expect(autosave.state.value, SaveState.saving);
    await pause();
    expect(textOf(store.calls.single.$1.document), contains('third'));
    store.commit();
    await pause(1);
    expect(autosave.state.value, SaveState.saved);
  });

  test('flush saves at once and waits for the commit', () async {
    autosave.edited(draft('close'));
    final flushed = autosave.flush();
    await pause(1);
    expect(store.calls, hasLength(1));
    var finished = false;
    unawaited(flushed.then((_) => finished = true));
    await pause(1);
    expect(finished, isFalse);
    store.commit();
    await flushed;
    expect(autosave.state.value, SaveState.saved);
  });

  group('with the SQLite store', () {
    late Directory root;
    late SqliteNoteStore sqlite;
    setUp(() async {
      root = await Directory.systemTemp.createTemp('autosave_');
      sqlite = await SqliteNoteStore.open(root.path);
    });
    tearDown(() async {
      await sqlite.close();
      await root.delete(recursive: true);
    });

    test(
      'a missing attachment fails the save and Retry can finish it later',
      () async {
        final saver = NoteAutosave(sqlite, settings: settings);
        addTearDown(saver.dispose);
        final file = await sqlite.importBytes(
          Uint8List(1),
          name: 'a.png',
          type: 'image/png',
        );
        final json = draft('x').document.toJson();
        (json['items'] as List).add({
          'id': 'i1',
          'kind': 'image',
          'x': 0,
          'y': 100,
          'width': 10,
          'height': 10,
          'file_id': 'not-yet',
        });
        final note = LocalNoteDraft(
          id: 'n1',
          schema: schema,
          document: NoteDocument.fromJson(json, schema: schema),
        );
        saver.edited(note);
        await saver.flush();
        expect(saver.state.value, SaveState.failed);
        expect(await sqlite.load('n1'), isNull);

        final fixed = jsonDecode(
          jsonEncode(json).replaceAll('not-yet', file.id),
        );
        saver.edited(
          LocalNoteDraft(
            id: 'n1',
            schema: schema,
            document: NoteDocument.fromJson(fixed, schema: schema),
          ),
        );
        await saver.flush();
        expect(saver.state.value, SaveState.saved);
        expect(referencedFiles((await sqlite.load('n1'))!.document), {file.id});
      },
    );

    test('local clipboard files use the managed copies', () async {
      final files = LocalClipboardFiles(sqlite);
      final document = draft('x').document;
      final png = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAMAAAACCAIAAAASFvFNAAAAEElEQVR4nGP4z8AAQQ'
        'xwFgBB0gX7h/C5SAAAAABJRU5ErkJggg==',
      );
      final picture = (await files.storePicture(document, png))!;
      expect((picture.width, picture.height), (3, 2));
      expect(await files.canUse(document, picture.fileId), isTrue);
      expect(await files.pictureBytes(picture.fileId), png);
      final kept = (await sqlite.attachment(picture.fileId))!;
      expect(kept.type, 'image/png');
      expect(kept.path, endsWith('.png'));

      // Not a picture: nothing is kept.
      expect(
        await files.storePicture(document, Uint8List.fromList([1, 2, 3])),
        isNull,
      );
      // A broken picture with a valid signature: nothing is kept.
      expect(
        await files.storePicture(document, Uint8List.sublistView(png, 0, 20)),
        isNull,
      );
      expect(
        Directory(
          '${root.path}/attachments',
        ).listSync().whereType<File>().length,
        1,
      );

      // A file that is not on this device cannot be pasted.
      expect(await files.canUse(document, 'server-file'), isFalse);
      // A file that is not a picture gives no picture bytes.
      final pdf = await sqlite.importBytes(
        Uint8List(1),
        name: 'a.pdf',
        type: 'application/pdf',
      );
      expect(await files.pictureBytes(pdf.id), isNull);

      await files.discardPicture(picture.fileId);
      expect(await files.canUse(document, picture.fileId), isFalse);
    });
  });

  test('picture formats come from the file signature', () {
    Uint8List b(List<int> v) => Uint8List.fromList(v);
    expect(pictureFormat(b([0xFF, 0xD8, 0xFF, 0xE0]))?.type, 'image/jpeg');
    expect(pictureFormat(b('GIF89a'.codeUnits))?.type, 'image/gif');
    expect(pictureFormat(b('RIFF0000WEBP'.codeUnits))?.type, 'image/webp');
    expect(pictureFormat(b('RIFF0000WAVE'.codeUnits)), isNull);
    expect(pictureFormat(b('BM'.codeUnits))?.type, 'image/bmp');
    expect(pictureFormat(b('%PDF'.codeUnits)), isNull);
    expect(pictureFormat(b([])), isNull);
  });
}
