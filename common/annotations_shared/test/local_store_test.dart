import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:annotations_shared/core/local_store_settings.dart';
import 'package:annotations_shared/dal/local/sqlite_note_store.dart';
import 'package:annotations_shared/domain/models/local_note.dart';
import 'package:annotations_shared/domain/models/note_document.dart';
import 'package:annotations_shared/domain/services/local_note_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

import 'local_store_writer.dart' as writer;
import 'note_capacity_test.dart' show handwriting;

final schema = DocumentSchema('note-original', 1);

LocalNoteDraft draft(
  String text, {
  String id = 'n1',
  List<String> files = const [],
}) => LocalNoteDraft(
  id: id,
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
      for (final (i, f) in files.indexed)
        {
          'id': 'i$i',
          'kind': 'image',
          'x': 0,
          'y': 100 + i * 200,
          'width': 100,
          'height': 100,
          'file_id': f,
        },
    ],
  }, schema: schema),
);

String textOf(LocalNote note) => (note.document as OriginalDocument).items.first
    .toJson()['spans']
    .toString();

Matcher storeError(String code) =>
    throwsA(isA<LocalStoreException>().having((e) => e.code, 'code', code));

/// The Dart executable of the Flutter SDK that runs this test.
String dartExecutable() {
  var dir = File(Platform.resolvedExecutable).parent;
  while (dir.parent.path != dir.path) {
    for (final candidate in [
      '${dir.path}/dart-sdk/bin/dart',
      '${dir.path}/cache/dart-sdk/bin/dart',
      '${dir.path}/bin/dart',
    ]) {
      if (File(candidate).existsSync()) return candidate;
    }
    dir = dir.parent;
  }
  return 'dart';
}

void main() {
  late Directory root;
  late SqliteNoteStore store;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('local_store_');
    store = await SqliteNoteStore.open(root.path);
  });

  tearDown(() async {
    await store.close();
    await root.delete(recursive: true);
  });

  Future<SqliteNoteStore> reopen() async {
    await store.close();
    return store = await SqliteNoteStore.open(root.path);
  }

  test('a saved note opens again with its document and metadata', () async {
    final file = await store.importBytes(
      Uint8List.fromList([1, 2, 3]),
      name: 'photo.png',
      type: 'image/png',
    );
    final first = await store.save(draft('hello', files: [file.id]));
    expect(first.revision, 1);
    expect(first.title, isNull);
    expect(first.syncState, LocalSyncState.local);
    expect(first.accountId, isNull);
    final second = await store.save(draft('hello again', files: [file.id]));
    expect(second.revision, 2);
    expect(second.createdAt, first.createdAt);

    await reopen();
    final loaded = (await store.load('n1'))!;
    expect(
      jsonEncode(loaded.document.toJson()),
      jsonEncode(draft('hello again', files: [file.id]).document.toJson()),
    );
    expect(loaded.schema.name, 'note-original');
    expect(loaded.revision, 2);
    expect(await store.readAttachment(file.id), [1, 2, 3]);
    expect([for (final n in await store.notes()) n.id], ['n1']);
    expect(await store.load('other'), isNull);
  });

  test(
    'every valid document fixture keeps its content through the store',
    () async {
      final fixtures = Directory(
        'test/fixtures/document_schema/valid',
      ).listSync().whereType<File>().toList();
      for (final (i, f) in fixtures.indexed) {
        final value = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
        final fixtureSchema = DocumentSchema(
          value['family'] as String,
          value['schema_version'] as int,
        );
        final ids = <String, String>{};
        for (final id in (value['files'] as List?) ?? const []) {
          ids[id as String] = (await store.importBytes(
            Uint8List(1),
            name: '$id.bin',
            type: 'application/octet-stream',
          )).id;
        }
        // The fixture file ids become the ids of managed copies.
        var json = jsonEncode(value['document']);
        ids.forEach((from, to) => json = json.replaceAll('"$from"', '"$to"'));
        final document = NoteDocument.fromJson(
          jsonDecode(json),
          schema: fixtureSchema,
        );
        // Every file reference is found, nested ones included.
        expect(referencedFiles(document), {
          for (final id in ids.values)
            if (json.contains('"$id"')) id,
        }, reason: f.path);
        await store.save(
          LocalNoteDraft(id: 'f$i', schema: fixtureSchema, document: document),
        );
        await reopen();
        final loaded = (await store.load('f$i'))!;
        expect(jsonEncode(loaded.document.toJson()), json, reason: f.path);
        expect(loaded.schema.name, fixtureSchema.name);
      }
    },
  );

  group('attachments', () {
    test('moving or deleting the original file keeps the attachment', () async {
      final outside = await Directory.systemTemp.createTemp('originals_');
      addTearDown(() => outside.delete(recursive: true));
      final bytes = Uint8List.fromList(List.generate(300000, (i) => i % 251));
      final moved = File('${outside.path}/report.pdf')..writeAsBytesSync(bytes);
      final deleted = File('${outside.path}/photo.jpg')
        ..writeAsBytesSync(bytes.reversed.toList());
      final changed = File('${outside.path}/data.csv')
        ..writeAsStringSync('a,b');

      final a = await store.importFile(moved.path, type: 'application/pdf');
      final b = await store.importFile(deleted.path, type: 'image/jpeg');
      final c = await store.importFile(changed.path, type: 'text/csv');
      expect(a.name, 'report.pdf');
      expect(a.size, bytes.length);
      expect(a.path, isNot(moved.path));
      await store.save(draft('files', files: [a.id, b.id, c.id]));

      moved.renameSync('${outside.path}/elsewhere.pdf');
      deleted.deleteSync();
      changed.writeAsStringSync('changed later');

      await reopen();
      expect(await store.readAttachment(a.id), bytes);
      expect(await store.readAttachment(b.id), bytes.reversed.toList());
      expect(utf8.decode((await store.readAttachment(c.id))!), 'a,b');
      final kept = (await store.attachment(a.id))!;
      expect(kept.path, startsWith(root.path));
      expect(kept.path, endsWith('.pdf'));
      expect(kept.type, 'application/pdf');
    });

    test('a missing source file fails the import and keeps nothing', () async {
      await expectLater(
        store.importFile('${root.path}/absent.png', type: 'image/png'),
        storeError('unreadable_file'),
      );
      expect(
        Directory('${root.path}/attachments/.partial').listSync(),
        isEmpty,
      );
    });

    test('a document never points to a missing attachment', () async {
      final kept = await store.importBytes(
        Uint8List(4),
        name: 'a.png',
        type: 'image/png',
      );
      await store.save(draft('before', files: [kept.id]));

      // An id that the store never held.
      await expectLater(
        store.save(draft('after', files: [kept.id, 'unknown'])),
        storeError('missing_attachment'),
      );
      // A recorded copy whose file is gone.
      final lost = await store.importBytes(
        Uint8List(4),
        name: 'b.png',
        type: 'image/png',
      );
      File(lost.path).deleteSync();
      expect(await store.attachment(lost.id), isNull);
      await expectLater(
        store.save(draft('after', files: [lost.id])),
        storeError('missing_attachment'),
      );
      // A new note with a missing file is not created.
      await expectLater(
        store.save(draft('new', id: 'n2', files: ['unknown'])),
        storeError('missing_attachment'),
      );

      final loaded = (await store.load('n1'))!;
      expect(textOf(loaded), contains('before'));
      expect(loaded.revision, 1);
      expect(await store.load('n2'), isNull);
    });

    test('discard removes only a file that no saved note references', () async {
      final used = await store.importBytes(
        Uint8List(1),
        name: 'used.png',
        type: 'image/png',
      );
      final unused = await store.importBytes(
        Uint8List(1),
        name: 'unused.png',
        type: 'image/png',
      );
      await store.save(draft('x', files: [used.id]));
      await store.discardAttachment(used.id);
      await store.discardAttachment(unused.id);
      expect(await store.attachment(used.id), isNotNull);
      expect(await store.attachment(unused.id), isNull);
      expect(File(unused.path).existsSync(), isFalse);
    });

    test('open removes what an interrupted run left behind', () async {
      final used = await store.importBytes(
        Uint8List(1),
        name: 'used.png',
        type: 'image/png',
      );
      final unsaved = await store.importBytes(
        Uint8List(1),
        name: 'unsaved.png',
        type: 'image/png',
      );
      await store.save(draft('x', files: [used.id]));
      // A copy that a later save no longer references.
      final replaced = await store.importBytes(
        Uint8List(1),
        name: 'old.png',
        type: 'image/png',
      );
      await store.save(draft('y', files: [used.id, replaced.id]));
      await store.save(draft('z', files: [used.id]));
      final partial = File('${root.path}/attachments/.partial/half.png')
        ..writeAsBytesSync([1]);
      final unrecorded = File('${root.path}/attachments/stray.png')
        ..writeAsBytesSync([1]);

      await reopen();
      expect(partial.existsSync(), isFalse);
      expect(unrecorded.existsSync(), isFalse);
      expect(await store.attachment(unsaved.id), isNull);
      expect(File(unsaved.path).existsSync(), isFalse);
      expect(await store.attachment(replaced.id), isNull);
      expect(await store.attachment(used.id), isNotNull);
    });
  });

  test('a 30-page note saves; a later change writes only that item', () async {
    final items = [for (var i = 0; i < 30 * 800; i++) handwriting(i)];
    NoteDocument doc(List<Object?> list) => NoteDocument.fromJson({
      'page': {
        'width': 1000,
        'background': {'kind': 'blank'},
      },
      'items': list,
    }, schema: schema);
    LocalNoteDraft of(List<Object?> list) =>
        LocalNoteDraft(id: 'big', schema: schema, document: doc(list));
    final watch = Stopwatch()..start();
    await store.save(of(items));
    final first = watch.elapsedMilliseconds;
    expect(store.lastSavedItems, items.length);
    final reopened = await reopen();
    final loaded = (await reopened.load('big'))!;
    expect(
      jsonEncode(loaded.document.toJson()),
      jsonEncode(doc(items).toJson()),
    );
    // One new stroke: one row.
    watch.reset();
    await store.save(of([...items, handwriting(999999)]));
    final one = watch.elapsedMilliseconds;
    expect(store.lastSavedItems, 1);
    // One stroke removed: one row.
    await store.save(of(items));
    expect(store.lastSavedItems, 1);
    // One stroke changed in the middle: one row.
    final changed = [...items];
    changed[12000] = {...(items[12000] as Map), 'color': '#3D5AFEFF'};
    await store.save(of(changed));
    expect(store.lastSavedItems, 1);
    expect(
      jsonEncode((await store.load('big'))!.document.toJson()),
      jsonEncode(doc(changed).toJson()),
    );
    final db = File('${root.path}/${const LocalStoreSettings().databaseFile}');
    final size = db.existsSync() ? db.lengthSync() : -1;
    // ignore: avoid_print
    print(
      '30 pages: first save $first ms, one-stroke save $one ms, store $size bytes',
    );
  });

  test('a local note keeps its sync state and bound account', () async {
    await store.save(draft('a'));
    await expectLater(
      store.setSync('absent', state: LocalSyncState.synced, accountId: 'u1'),
      storeError('missing_note'),
    );
    await store.setSync(
      'n1',
      state: LocalSyncState.synced,
      accountId: 'u1',
      serverNoteId: 'srv_n1',
      serverRevision: 4,
      serverOriginalRevisionId: 'rev_orig_4',
      serverTypedRevisionId: 'rev_typed_4',
    );
    final loadedSynced = (await store.load('n1'))!;
    expect(loadedSynced.syncState, LocalSyncState.synced);
    expect(loadedSynced.serverNoteId, 'srv_n1');
    expect(loadedSynced.serverRevision, 4);
    expect(loadedSynced.serverOriginalRevisionId, 'rev_orig_4');
    expect(loadedSynced.serverTypedRevisionId, 'rev_typed_4');

    await store.save(draft('b'));
    await reopen();
    final changed = (await store.load('n1'))!;
    expect(changed.syncState, LocalSyncState.changed);
    expect(changed.accountId, 'u1');
    expect(changed.revision, 2);
    expect(changed.serverNoteId, 'srv_n1');
    expect(changed.serverRevision, 4);
    expect(changed.serverOriginalRevisionId, 'rev_orig_4');
    expect(changed.serverTypedRevisionId, 'rev_typed_4');

    await store.setSync('n1', state: LocalSyncState.local, accountId: null);
    await reopen();
    final unbound = (await store.load('n1'))!;
    expect(unbound.syncState, LocalSyncState.local);
    expect(unbound.accountId, isNull);
    expect(unbound.serverNoteId, isNull);
    expect(unbound.serverRevision, isNull);
    expect(unbound.serverOriginalRevisionId, isNull);
    expect(unbound.serverTypedRevisionId, isNull);

    // A note that never synced stays local after edits.
    await store.save(draft('c', id: 'n2'));
    await store.save(draft('d', id: 'n2'));
    final local = (await store.load('n2'))!;
    expect(local.syncState, LocalSyncState.local);
    expect(local.accountId, isNull);
    expect(local.serverNoteId, isNull);
    expect(local.serverRevision, isNull);
  });

  test(
    'prepared study reference resumes by owner and clears on revision/account change',
    () async {
      await store.save(draft('a'));
      await store.setSync(
        'n1',
        state: LocalSyncState.synced,
        accountId: 'account-a',
        serverNoteId: 'server-note-a',
        serverRevision: 4,
      );
      await store.savePreparedStudyReference(
        'n1',
        accountId: 'account-a',
        serverNoteId: 'server-note-a',
        serverRevision: 4,
        studyId: 'study-4',
      );
      await reopen();
      expect((await store.load('n1'))!.preparedStudyId, 'study-4');
      await expectLater(
        store.savePreparedStudyReference(
          'n1',
          accountId: 'account-b',
          serverNoteId: 'server-note-a',
          serverRevision: 4,
          studyId: 'study-stolen',
        ),
        storeError('study_reference_conflict'),
      );

      await store.setSync(
        'n1',
        state: LocalSyncState.synced,
        accountId: 'account-a',
        serverNoteId: 'server-note-a',
        serverRevision: 5,
      );
      expect((await store.load('n1'))!.preparedStudyId, isNull);

      await store.savePreparedStudyReference(
        'n1',
        accountId: 'account-a',
        serverNoteId: 'server-note-a',
        serverRevision: 5,
        studyId: 'study-5',
      );
      await store.setSync(
        'n1',
        state: LocalSyncState.synced,
        accountId: 'account-b',
        serverNoteId: 'server-note-b',
        serverRevision: 1,
      );
      expect((await store.load('n1'))!.preparedStudyId, isNull);
    },
  );

  test('schema steps run once and a newer store is not opened', () async {
    await store.close();
    final db = sqlite3.open('${root.path}/notes.sqlite3');
    expect(db.userVersion, 5);
    expect(db.select('PRAGMA journal_mode').first.values.first, 'wal');
    db.userVersion = 99;
    db.close();
    await expectLater(
      SqliteNoteStore.open(root.path),
      storeError('newer_store'),
    );
    final again = sqlite3.open('${root.path}/notes.sqlite3')
      ..userVersion = 5
      ..close();
    expect(again, isNotNull);
    store = await SqliteNoteStore.open(root.path);
  });

  test(
    'a kill during save reopens the previous or the new complete state',
    () async {
      final random = Random(25);
      final dart = dartExecutable();
      var killedInsideSave = 0;
      for (var round = 0; round < 5; round++) {
        await store.close();
        final child = await Process.start(dart, [
          'run',
          'test/local_store_writer.dart',
          root.path,
        ]);
        addTearDown(() => child.kill(ProcessSignal.sigkill));
        final killAt = 2 + random.nextInt(4);
        final out = <String>[];
        final reached = Completer<void>();
        final closed = Completer<void>();
        child.stdout
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .listen((line) {
              out.add(line);
              if (line == 'begin $killAt' && !reached.isCompleted) {
                reached.complete();
              }
            }, onDone: closed.complete);
        final errors = StringBuffer();
        child.stderr.transform(utf8.decoder).listen(errors.write);
        await reached.future.timeout(const Duration(minutes: 1));
        // Inside the save: the commit of about 2.5 MB is running.
        await Future<void>.delayed(
          Duration(microseconds: random.nextInt(30000)),
        );
        child.kill(ProcessSignal.sigkill);
        expect(await child.exitCode, isNot(0), reason: errors.toString());
        await closed.future;
        final done = out.contains('done $killAt') ? killAt : killAt - 1;
        if (done < killAt) killedInsideSave++;

        store = await SqliteNoteStore.open(root.path);
        final note = (await store.load(writer.noteId))!;
        final version = int.parse(note.title!.split(' ').last);
        expect(version, anyOf(done, killAt), reason: 'round $round');
        final document = note.document as OriginalDocument;
        expect(document.items, hasLength(writer.itemCount + 1));
        for (final item in document.items.take(writer.itemCount)) {
          expect((item.toJson()['spans'] as List).single, {
            'text': 'v$version;'.padRight(writer.textLength, 'x'),
          });
        }
        final fileId = document.items.last.toJson()['file_id'] as String;
        expect(
          await store.readAttachment(fileId),
          writer.attachmentBytes(version),
        );
        // The store keeps no unfinished or unreferenced copy.
        final files = Directory(
          '${root.path}/attachments',
        ).listSync().whereType<File>();
        expect(files, hasLength(1));
      }
      // The test must have hit at least one save before its commit ended.
      expect(killedInsideSave, greaterThan(0));
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test('the store has no network code', () {
    for (final path in [
      'lib/dal/local/sqlite_note_store.dart',
      'lib/dal/local/device_note_store.dart',
      'lib/dal/local/local_clipboard_files.dart',
      'lib/domain/services/local_note_store.dart',
      'lib/domain/services/note_autosave.dart',
    ]) {
      final source = File(path).readAsStringSync();
      for (final word in [
        'package:http',
        'HttpClient',
        'Socket',
        'WebSocket',
        'remote/',
        'tracking',
        'logs.dart',
      ]) {
        expect(source, isNot(contains(word)), reason: '$path: $word');
      }
    }
  });
}
