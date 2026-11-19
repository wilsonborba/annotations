import 'dart:convert';
import 'dart:typed_data';

import 'package:annotations_shared/dal/remote/api_adapter.dart';
import 'package:annotations_shared/domain/models/local_note.dart';
import 'package:annotations_shared/domain/models/note_document.dart';
import 'package:annotations_shared/domain/services/local_note_store.dart';
import 'package:annotations_shared/domain/services/note_backup_service.dart';
import 'package:annotations_shared/domain/services/note_sync_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

final class _FakeStore implements LocalNoteStore {
  final Map<String, LocalNote> _notes = {};
  final Map<String, LocalAttachment> _files = {};
  final Map<String, Uint8List> _bytes = {};
  int _fileSeq = 0;

  @override
  Future<LocalNote?> load(String id) async => _notes[id];

  @override
  Future<List<LocalNote>> notes() async => _notes.values.toList();

  @override
  Future<LocalNote> save(LocalNoteDraft draft) async {
    final prev = _notes[draft.id];
    final now = DateTime.now();
    final saved = LocalNote(
      id: draft.id,
      schema: draft.schema,
      document: draft.document,
      title: draft.title,
      revision: (prev?.revision ?? 0) + 1,
      createdAt: prev?.createdAt ?? now,
      updatedAt: now,
      syncState: prev == null ? LocalSyncState.local : LocalSyncState.changed,
      accountId: prev?.accountId,
    );
    _notes[draft.id] = saved;
    return saved;
  }

  @override
  Future<void> setSync(String id, {required LocalSyncState state, required String? accountId}) async {
    final prev = _notes[id];
    if (prev == null) return;
    _notes[id] = LocalNote(
      id: prev.id,
      schema: prev.schema,
      document: prev.document,
      title: prev.title,
      revision: prev.revision,
      createdAt: prev.createdAt,
      updatedAt: prev.updatedAt,
      syncState: state,
      accountId: accountId,
    );
  }

  @override
  Future<LocalAttachment> importBytes(Uint8List bytes, {required String name, required String type}) async {
    final id = 'file_${++_fileSeq}';
    final att = LocalAttachment(id: id, name: name, type: type, size: bytes.length, path: '/mem/$id');
    _files[id] = att;
    _bytes[id] = bytes;
    return att;
  }

  @override
  Future<LocalAttachment> importFile(String sourcePath, {required String type}) =>
      importBytes(Uint8List(0), name: sourcePath, type: type);

  @override
  Future<LocalAttachment?> attachment(String id) async => _files[id];

  @override
  Future<Uint8List?> readAttachment(String id) async => _bytes[id];

  @override
  Future<void> discardAttachment(String id) async {
    _files.remove(id);
    _bytes.remove(id);
  }

  @override
  Future<void> close() async {}
}

final _paperSchema = DocumentSchema(DocumentFamily.original.schemaName, 1);

PaperDocument _paperWithTextAndFile(String text, String fileId) => NoteDocument.fromJson(
      {
        'page': {'width': 1000, 'background': {'kind': 'blank'}},
        'items': [
          {
            'id': 'it_1',
            'kind': 'text',
            'x': 0,
            'y': 0,
            'width': 200,
            'height': 40,
            'spans': [
              {'text': text},
            ],
          },
          {
            'id': 'it_2',
            'kind': 'file',
            'x': 0,
            'y': 50,
            'width': 200,
            'height': 40,
            'file_id': fileId,
            'name': 'doc.pdf',
            'type': 'application/pdf',
            'size': 3,
          },
        ],
      },
      schema: _paperSchema,
    ) as PaperDocument;

void main() {
  test('first upload sends full note compressed, incremental sync uses syncOperation, 409 keeps both versions', () async {
    final store = _FakeStore();
    final att = await store.importBytes(Uint8List.fromList([1, 2, 3, 4]), name: 'clip.png', type: 'image/png');
    final baseDoc = _paperWithTextAndFile('v1', att.id);
    final saved = await store.save(LocalNoteDraft(id: 'n1', schema: _paperSchema, document: baseDoc, title: 'Note 1'));

    final requests = <(String, String, String?)>[];
    var failConflict = false;
    final mock = MockClient((req) async {
      requests.add((req.method, req.url.path, req.headers['content-encoding']));
      if (failConflict) {
        return http.Response(jsonEncode({'error': 'conflict'}), 409);
      }
      return http.Response(jsonEncode({'revision': 2, 'note_id': 'n1'}), 200);
    });

    final service = NoteSyncService(
      store: store,
      api: ApiAdapter(client: mock, base: 'https://api.asodya.com/apps/annotations/v1'),
    );

    // First upload binds to acc_1.
    final first = await service.syncNote(saved, accountId: 'acc_1');
    expect(first.isConflict, isFalse);
    expect(first.localNote.accountId, 'acc_1');
    expect(first.localNote.syncState, LocalSyncState.synced);
    expect(requests.last, ('POST', '/apps/annotations/v1/me/notes', 'gzip'));

    // Another account cannot take over a bound note.
    await expectLater(
      service.syncNote(first.localNote, accountId: 'acc_2'),
      throwsA(isA<AccountOwnershipException>()),
    );

    // Incremental sync sends PATCH with syncOperation + gzip.
    final updated = await store.save(
      LocalNoteDraft(
        id: 'n1',
        schema: _paperSchema,
        document: _paperWithTextAndFile('v2', att.id),
        title: 'Note 1',
      ),
    );
    final second = await service.syncNote(updated, accountId: 'acc_1', baseDocument: baseDoc, baseRevision: 2);
    expect(second.isConflict, isFalse);
    expect(requests.last, ('PATCH', '/apps/annotations/v1/me/notes/n1', 'gzip'));

    // 409 conflict keeps both versions.
    failConflict = true;
    final conflict = await service.syncNote(updated, accountId: 'acc_1', baseDocument: baseDoc, baseRevision: 2);
    expect(conflict.isConflict, isTrue);
    expect(conflict.conflictCopy, isNotNull);
    expect((await store.notes()).length, 2);
  });

  test('account switch shows no leak and backup restore round trip keeps items and files', () async {
    final store = _FakeStore();
    final att = await store.importBytes(Uint8List.fromList([9, 8, 7]), name: 'doc.pdf', type: 'application/pdf');
    final n1 = await store.save(
      LocalNoteDraft(
        id: 'n_acc1',
        schema: _paperSchema,
        document: _paperWithTextAndFile('secret', att.id),
        title: 'Acc1 Note',
      ),
    );
    await store.setSync(n1.id, state: LocalSyncState.synced, accountId: 'acc_1');

    final service = NoteSyncService(
      store: store,
      api: ApiAdapter(
        client: MockClient((_) async => http.Response('{}', 200)),
        base: 'https://api.asodya.com/apps/annotations/v1',
      ),
    );

    expect((await service.notesForAccount('acc_1')).map((n) => n.id), ['n_acc1']);
    expect(await service.notesForAccount('acc_2'), isEmpty);

    final backup = NoteBackupService();
    final pkg = await backup.exportPackage(store, 'n_acc1');
    final restored = await backup.restorePackage(store, pkg, newNoteId: 'n_restored');
    expect(restored.id, 'n_restored');
    expect(restored.accountId, isNull);
    expect(restored.syncState, LocalSyncState.local);
    final restoredFiles = referencedFiles(restored.document);
    expect(restoredFiles.length, 1);
    expect(await store.readAttachment(restoredFiles.first), Uint8List.fromList([9, 8, 7]));
  });
}
