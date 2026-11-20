import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:annotations_shared/dal/local/sqlite_note_store.dart';
import 'package:annotations_shared/dal/remote/api_adapter.dart';
import 'package:annotations_shared/domain/models/local_note.dart';
import 'package:annotations_shared/domain/models/note_document.dart';
import 'package:annotations_shared/domain/services/local_note_store.dart';
import 'package:annotations_shared/domain/services/note_backup_service.dart';
import 'package:annotations_shared/domain/services/note_sync_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support/annotations_api_contract.dart';

final _paperSchema = DocumentSchema(DocumentFamily.original.schemaName, 1);

PaperDocument _paperWithTextAndFile(
  String text,
  String fileId, {
  bool restrictedEmbed = false,
}) =>
    NoteDocument.fromJson({
          'page': {
            'width': 1000,
            'background': {'kind': 'blank'},
          },
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
            if (restrictedEmbed)
              {
                'id': 'it_3',
                'kind': 'reports_embed',
                'x': 0,
                'y': 100,
                'width': 300,
                'height': 120,
                'report_id': 'rep_1',
                'mode': 'live',
                'source': 'owned',
                'restricted': true,
              },
          ],
        }, schema: _paperSchema)
        as PaperDocument;

void main() {
  late Directory tempDir;
  late SqliteNoteStore store;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('annotations_37_test_');
    store = await SqliteNoteStore.open(tempDir.path);
  });

  tearDown(() async {
    await store.close();
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  test(
    'first upload POSTs /me/notes, bound note uses PATCH or PUT with If-Match (never duplicate POST), and 409 fetches server doc without overwriting local',
    () async {
      final att = await store.importBytes(
        Uint8List.fromList([1, 2, 3, 4]),
        name: 'clip.png',
        type: 'image/png',
      );
      final baseDoc = _paperWithTextAndFile('local v1', att.id);
      final saved = await store.save(
        LocalNoteDraft(
          id: 'n1',
          schema: _paperSchema,
          document: baseDoc,
          title: 'Note 1',
        ),
      );

      final recorded =
          <
            ({
              String method,
              String path,
              String? encoding,
              String? ifMatch,
              Map<String, dynamic> body,
            })
          >[];
      var failConflict = false;
      final serverDocJson = _paperWithTextAndFile('server v9', att.id).toJson();

      final mock = AnnotationsApiContract(
        onValid: (req, body) async {
          recorded.add((
            method: req.method,
            path: req.url.path,
            encoding: req.headers['content-encoding'],
            ifMatch: req.headers['if-match'],
            body: body ?? const {},
          ));

          if (req.method == 'GET' &&
              req.url.path == '/apps/annotations/v1/me/notes/n1') {
            return http.Response(
              jsonEncode({
                'note_id': 'n1',
                'title': 'Note 1',
                'revision': 9,
                'schema': {
                  'name': _paperSchema.name,
                  'version': _paperSchema.version,
                },
                'document': serverDocJson,
              }),
              200,
            );
          }

          if (failConflict) {
            return http.Response(
              jsonEncode({'error': 'revision_mismatch'}),
              409,
            );
          }
          return http.Response(
            jsonEncode({'revision': 2, 'note_id': 'n1'}),
            200,
          );
        },
      ).toMockClient();

      final service = NoteSyncService(
        store: store,
        api: ApiAdapter(
          client: mock,
          base: 'https://api.asodya.com/apps/annotations/v1',
        ),
      );

      // 1. First upload (unbound) -> POST /me/notes with gzip.
      final first = await service.syncNote(saved, accountId: 'acc_1');
      expect(first.isConflict, isFalse);
      expect(first.localNote.accountId, 'acc_1');
      expect(first.localNote.syncState, LocalSyncState.synced);
      expect(recorded.last.method, 'POST');
      expect(recorded.last.path, '/apps/annotations/v1/me/notes');
      expect(recorded.last.encoding, 'gzip');

      // 2. Another account cannot take over a bound note.
      await expectLater(
        service.syncNote(first.localNote, accountId: 'acc_2'),
        throwsA(isA<AccountOwnershipException>()),
      );

      // 3. Bound note with baseDocument -> PATCH /me/notes/n1 with If-Match (no base_revision in body).
      final updated = await store.save(
        LocalNoteDraft(
          id: 'n1',
          schema: _paperSchema,
          document: _paperWithTextAndFile('local v2', att.id),
          title: 'Note 1',
        ),
      );
      final patchResult = await service.syncNote(
        updated,
        accountId: 'acc_1',
        baseDocument: baseDoc,
        baseRevision: 2,
      );
      expect(patchResult.isConflict, isFalse);
      expect(recorded.last.method, 'PATCH');
      expect(recorded.last.path, '/apps/annotations/v1/me/notes/n1');
      expect(recorded.last.encoding, 'gzip');
      expect(recorded.last.ifMatch, '"2"');
      expect(recorded.last.body.containsKey('base_revision'), isFalse);

      // 4. Bound note without baseDocument -> PUT /me/notes/n1 with If-Match (never duplicate POST).
      final putResult = await service.syncNote(
        updated,
        accountId: 'acc_1',
        baseRevision: 3,
      );
      expect(putResult.isConflict, isFalse);
      expect(recorded.last.method, 'PUT');
      expect(recorded.last.path, '/apps/annotations/v1/me/notes/n1');
      expect(recorded.last.ifMatch, '"3"');

      // 5. 409 Conflict fetches server doc via GET, keeps local note unchanged, saves server copy.
      failConflict = true;
      final conflict = await service.syncNote(
        updated,
        accountId: 'acc_1',
        baseDocument: baseDoc,
        baseRevision: 3,
      );
      expect(conflict.isConflict, isTrue);
      expect(conflict.conflictCopy?.id, 'n1__conflict_9');
      expect(
        recorded.any(
          (r) =>
              r.method == 'GET' && r.path == '/apps/annotations/v1/me/notes/n1',
        ),
        isTrue,
      );
      final localAfter = await store.load('n1');
      final serverAfter = await store.load('n1__conflict_9');
      expect(localAfter, isNotNull);
      expect(serverAfter, isNotNull);
      expect(jsonEncode(localAfter!.document.toJson()), contains('local v2'));
      expect(jsonEncode(serverAfter!.document.toJson()), contains('server v9'));
    },
  );

  test(
    'publishNote warns on restricted embeds, calls PUT/DELETE /me/notes/{id}/publication and DELETE with delete_owned_reports, and deleteLocalCopy removes from SqliteNoteStore',
    () async {
      final att = await store.importBytes(
        Uint8List.fromList([5, 6, 7]),
        name: 'doc.pdf',
        type: 'application/pdf',
      );
      final note = await store.save(
        LocalNoteDraft(
          id: 'n_pub',
          schema: _paperSchema,
          document: _paperWithTextAndFile('pub', att.id, restrictedEmbed: true),
          title: 'Pub Note',
        ),
      );
      await store.setSync(
        note.id,
        state: LocalSyncState.synced,
        accountId: 'acc_1',
      );
      final bound = (await store.load(note.id))!;

      final calls =
          <
            ({
              String method,
              String path,
              String query,
              String? ifMatch,
              Map<String, dynamic> body,
            })
          >[];
      final mock = AnnotationsApiContract(
        onValid: (req, body) async {
          calls.add((
            method: req.method,
            path: req.url.path,
            query: req.url.query,
            ifMatch: req.headers['if-match'],
            body: body ?? const {},
          ));
          return http.Response(jsonEncode({'ok': true}), 200);
        },
      ).toMockClient();

      final service = NoteSyncService(
        store: store,
        api: ApiAdapter(
          client: mock,
          base: 'https://api.asodya.com/apps/annotations/v1',
        ),
      );

      final warn = await service.publishNote(
        bound,
        accountId: 'acc_1',
        representation: PublicationRepresentation.original,
      );
      expect(warn.published, isFalse);
      expect(warn.restrictedEmbedCount, 1);
      expect(calls, isEmpty);

      final ok = await service.publishNote(
        bound,
        accountId: 'acc_1',
        representation: PublicationRepresentation.both,
        publicationRevision: 4,
        allowRestrictedEmbeds: true,
      );
      expect(ok.published, isTrue);
      expect(calls.last.method, 'PUT');
      expect(
        calls.last.path,
        '/apps/annotations/v1/me/notes/n_pub/publication',
      );
      expect(calls.last.ifMatch, '"4"');
      expect(calls.last.body['language'], 'en');
      expect(calls.last.body['representations'], {
        'original': '1',
        'typed': '1',
      });

      await service.unpublishNote(
        'n_pub',
        accountId: 'acc_1',
        publicationRevision: 5,
      );
      expect(calls.last.method, 'DELETE');
      expect(
        calls.last.path,
        '/apps/annotations/v1/me/notes/n_pub/publication',
      );
      expect(calls.last.ifMatch, '"5"');

      await service.deleteCloudNote(
        'n_pub',
        accountId: 'acc_1',
        expectedRevision: 7,
        deleteOwnedReports: true,
      );
      expect(calls.last.method, 'DELETE');
      expect(calls.last.path, '/apps/annotations/v1/me/notes/n_pub');
      expect(calls.last.query, 'delete_owned_reports=true');
      expect(calls.last.ifMatch, '"7"');

      await service.deleteLocalCopy('n_pub');
      expect(await store.load('n_pub'), isNull);
    },
  );

  test(
    'ProjectTagCatalog persists to disk across reloads, syncs via /me/projects and PATCH /me/notes/{id}, and createAndPublishTypedNote omits account_id',
    () async {
      final catalogFile = File('${tempDir.path}/catalog.json');
      final catalog1 = ProjectTagCatalog(persistenceFile: catalogFile);
      catalog1.createLocalProject('proj_1', 'Research');
      catalog1.assignNoteToProject('n_typed', 'proj_1');
      catalog1.addTag('n_typed', 'Exam');
      expect(
        () => catalog1.createLocalProject('proj_2', '  research  '),
        throwsStateError,
      );

      // Reload from disk in a fresh instance.
      final catalog2 = ProjectTagCatalog(persistenceFile: catalogFile);
      expect(catalog2.projectForNote('n_typed'), 'proj_1');
      expect(catalog2.tagsForNote('n_typed'), {'exam'});

      final calls =
          <
            ({
              String method,
              String path,
              String? ifMatch,
              Map<String, dynamic> body,
            })
          >[];
      final mock = AnnotationsApiContract(
        onValid: (req, body) async {
          calls.add((
            method: req.method,
            path: req.url.path,
            ifMatch: req.headers['if-match'],
            body: body ?? const {},
          ));
          if (req.method == 'POST' &&
              req.url.path == '/apps/annotations/v1/me/notes') {
            return http.Response(
              jsonEncode({'note_id': 'n_typed', 'revision': 1}),
              201,
            );
          }
          return http.Response(jsonEncode({'ok': true}), 200);
        },
      ).toMockClient();

      final api = ApiAdapter(
        client: mock,
        base: 'https://api.asodya.com/apps/annotations/v1',
      );
      final service = NoteSyncService(store: store, api: api);

      await service.createAndPublishTypedNote(
        title: 'Typed Study Note',
        blocks: [
          {'id': 'b1', 'kind': 'heading', 'text': 'Summary'},
        ],
      );
      expect(calls[0].method, 'POST');
      expect(calls[0].path, '/apps/annotations/v1/me/notes');
      expect(calls[0].body.containsKey('account_id'), isFalse);
      expect(calls[1].method, 'PUT');
      expect(
        calls[1].path,
        '/apps/annotations/v1/me/notes/n_typed/publication',
      );
      expect(calls[1].ifMatch, '"0"');

      await catalog2.syncProjectAndTags(
        api,
        noteId: 'n_typed',
        noteRevision: 1,
      );
      expect(calls[2].method, 'POST');
      expect(calls[2].path, '/apps/annotations/v1/me/projects');
      expect(calls[3].method, 'PUT');
      expect(
        calls[3].path,
        '/apps/annotations/v1/me/projects/proj_1/notes/n_typed',
      );
      expect(calls[4].method, 'PATCH');
      expect(calls[4].path, '/apps/annotations/v1/me/notes/n_typed');
      expect(calls[4].ifMatch, '"1"');
      expect(calls[4].body['metadata'], {
        'tags': ['exam'],
      });
    },
  );

  test(
    'account switch shows no leak and backup restore round trip keeps items and files',
    () async {
      final att = await store.importBytes(
        Uint8List.fromList([9, 8, 7]),
        name: 'doc.pdf',
        type: 'application/pdf',
      );
      final n1 = await store.save(
        LocalNoteDraft(
          id: 'n_acc1',
          schema: _paperSchema,
          document: _paperWithTextAndFile('secret', att.id),
          title: 'Acc1 Note',
        ),
      );
      await store.setSync(
        n1.id,
        state: LocalSyncState.synced,
        accountId: 'acc_1',
      );

      final service = NoteSyncService(
        store: store,
        api: ApiAdapter(
          client: MockClient((_) async => http.Response('{}', 200)),
          base: 'https://api.asodya.com/apps/annotations/v1',
        ),
      );

      expect((await service.notesForAccount('acc_1')).map((n) => n.id), [
        'n_acc1',
      ]);
      expect(await service.notesForAccount('acc_2'), isEmpty);

      final backup = NoteBackupService();
      final pkg = await backup.exportPackage(store, 'n_acc1');
      final restored = await backup.restorePackage(
        store,
        pkg,
        newNoteId: 'n_restored',
      );
      expect(restored.id, 'n_restored');
      expect(restored.accountId, isNull);
      expect(restored.syncState, LocalSyncState.local);
      final restoredFiles = referencedFiles(restored.document);
      expect(restoredFiles.length, 1);
      expect(
        await store.readAttachment(restoredFiles.first),
        Uint8List.fromList([9, 8, 7]),
      );
    },
  );

  test(
    'AnnotationsApiContract rejects legacy/unknown fields and missing If-Match',
    () async {
      final contract = AnnotationsApiContract(
        onValid: (_, _) async => http.Response('{}', 200),
      ).toMockClient();

      final badNote = await contract.post(
        Uri.parse('https://api.asodya.com/apps/annotations/v1/me/notes'),
        headers: {'content-type': 'application/json'},
        body: jsonEncode({'note_id': 'n1', 'title': 'Old'}),
      );
      expect(badNote.statusCode, 422);
      expect(badNote.body, contains('unknown_field'));

      final badFile = await contract.post(
        Uri.parse('https://api.asodya.com/apps/annotations/v1/me/files'),
        headers: {'content-type': 'application/json'},
        body: jsonEncode({
          'purpose': 'content_job',
          'filename': 'a.pdf',
          'content_type': 'application/pdf',
          'size_bytes': 12,
        }),
      );
      expect(badFile.statusCode, 422);
      expect(badFile.body, contains('unknown_field'));

      final badInstantFile = await contract.post(
        Uri.parse(
          'https://api.asodya.com/apps/annotations/v1/instant/ROOM1/files',
        ),
        headers: {'content-type': 'application/json'},
        body: jsonEncode({
          'filename': 'a.pdf',
          'content_type': 'application/pdf',
          'size_bytes': 12,
        }),
      );
      expect(badInstantFile.statusCode, 422);
      expect(badInstantFile.body, contains('unknown_field'));

      final missingIfMatch = await contract.put(
        Uri.parse(
          'https://api.asodya.com/apps/annotations/v1/me/notes/n1/publication',
        ),
        headers: {'content-type': 'application/json'},
        body: jsonEncode({
          'language': 'en',
          'representations': {'original': '1'},
        }),
      );
      expect(missingIfMatch.statusCode, 428);
      expect(missingIfMatch.body, contains('if_match_required'));
    },
  );
}
