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

          if (req.method == 'GET' &&
              req.url.path == '/apps/annotations/v1/me/notes') {
            return http.Response(
              jsonEncode({
                'items': [
                  {'note_id': 'n1', 'client_note_id': 'n1'},
                ],
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
      final unrelated = await store.save(
        LocalNoteDraft(
          id: 'n1__conflict_9',
          schema: _paperSchema,
          document: _paperWithTextAndFile('unrelated local note', att.id),
          title: 'Unrelated local note',
        ),
      );
      failConflict = true;
      final conflict = await service.syncNote(
        updated,
        accountId: 'acc_1',
        baseDocument: baseDoc,
        baseRevision: 3,
      );
      expect(conflict.isConflict, isTrue);
      expect(conflict.conflictCopy?.id, 'n1__conflict_9_1');
      expect(
        recorded.any(
          (r) =>
              r.method == 'GET' && r.path == '/apps/annotations/v1/me/notes/n1',
        ),
        isTrue,
      );
      final localAfter = await store.load('n1');
      final serverAfter = await store.load(conflict.conflictCopy!.id);
      expect(localAfter, isNotNull);
      expect(serverAfter, isNotNull);
      expect(jsonEncode(localAfter!.document.toJson()), contains('local v2'));
      expect(jsonEncode(serverAfter!.document.toJson()), contains('server v9'));
      expect(
        jsonEncode((await store.load(unrelated.id))!.document.toJson()),
        contains('unrelated local note'),
      );
      final conflictCopy = conflict.conflictCopy!;
      expect(conflictCopy.accountId, 'acc_1');
      expect(conflictCopy.syncState, LocalSyncState.local);
      expect(conflictCopy.isConflictCopy, isTrue);
      expect(conflictCopy.serverNoteId, isNull);
      expect(conflictCopy.serverRevision, isNull);
      expect(conflictCopy.serverOriginalRevisionId, isNull);
      expect(conflictCopy.serverTypedRevisionId, isNull);
      expect(
        (await service.notesForAccount('acc_1')).map((n) => n.id),
        contains(conflictCopy.id),
      );
      expect(
        (await service.notesForAccount('acc_2')).map((n) => n.id),
        isNot(contains(conflictCopy.id)),
      );
      expect(
        (await service.notesForAccount(null)).map((n) => n.id),
        isNot(contains(conflictCopy.id)),
      );

      // Owner edits stay bound, while the conflict copy has no inherited cloud identity.
      final editedCopy = await store.save(
        LocalNoteDraft(
          id: conflictCopy.id,
          schema: conflictCopy.schema,
          document: _paperWithTextAndFile('owner edit', att.id),
          title: 'Owner edit',
        ),
      );
      expect(editedCopy.accountId, 'acc_1');
      expect(editedCopy.serverNoteId, isNull);
      final callsBeforeRetry = recorded.length;
      await expectLater(
        service.syncNote(editedCopy, accountId: 'acc_1'),
        throwsA(isA<CloudIdentityException>()),
      );
      expect(recorded, hasLength(callsBeforeRetry));

      await store.close();
      store = await SqliteNoteStore.open(tempDir.path);
      final persistedCopy = (await store.load(conflictCopy.id))!;
      final reloadedService = NoteSyncService(
        store: store,
        api: ApiAdapter(
          client: mock,
          base: 'https://api.asodya.com/apps/annotations/v1',
        ),
      );
      expect(persistedCopy.accountId, 'acc_1');
      expect(persistedCopy.syncState, LocalSyncState.local);
      expect(persistedCopy.isConflictCopy, isTrue);
      expect(persistedCopy.serverNoteId, isNull);
      expect(
        (await reloadedService.notesForAccount('acc_2')).map((n) => n.id),
        isNot(contains(conflictCopy.id)),
      );

      final backup = NoteBackupService();
      final package = await backup.exportPackage(store, conflictCopy.id);
      final restored = await backup.restorePackage(
        store,
        package,
        newNoteId: 'restored_conflict',
      );
      expect(restored.accountId, isNull);
      expect(restored.serverNoteId, isNull);
      expect(restored.isConflictCopy, isFalse);
      expect(restored.syncState, LocalSyncState.local);
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
        serverNoteId: 'srv_pub',
        serverRevision: 7,
        serverOriginalRevisionId: 'rev_orig_1',
        serverTypedRevisionId: 'rev_typed_1',
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
          if (!req.url.path.contains('/srv_pub')) {
            return http.Response(jsonEncode({'error': 'not_found'}), 404);
          }
          final reps = body?['representations'] as Map?;
          if (req.method == 'PUT' &&
              req.url.path.endsWith('/publication') &&
              (reps?['original'] != 'rev_orig_1' ||
                  reps?['typed'] != 'rev_typed_1' ||
                  reps?.length != 2)) {
            return http.Response(
              jsonEncode({'error': 'invalid_representation_revision'}),
              422,
            );
          }
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
        originalRevisionId: 'rev_orig_1',
        typedRevisionId: 'rev_typed_1',
      );
      expect(ok.published, isTrue);
      expect(calls.last.method, 'PUT');
      expect(
        calls.last.path,
        '/apps/annotations/v1/me/notes/srv_pub/publication',
      );
      expect(calls.last.ifMatch, '"4"');
      expect(calls.last.body['language'], 'en');
      expect(calls.last.body['representations'], {
        'original': 'rev_orig_1',
        'typed': 'rev_typed_1',
      });

      final missingRevision = await store.save(
        LocalNoteDraft(
          id: 'n_missing_rep',
          schema: _paperSchema,
          document: _paperWithTextAndFile('missing revision', att.id),
          title: 'Missing revision',
        ),
      );
      await store.setSync(
        missingRevision.id,
        state: LocalSyncState.synced,
        accountId: 'acc_1',
        serverNoteId: 'srv_pub',
        serverRevision: 8,
      );
      final callsBeforeMissingRevision = calls.length;
      await expectLater(
        service.publishNote(
          (await store.load(missingRevision.id))!,
          accountId: 'acc_1',
          representation: PublicationRepresentation.original,
          allowRestrictedEmbeds: true,
        ),
        throwsA(isA<CloudIdentityException>()),
      );
      expect(calls, hasLength(callsBeforeMissingRevision));
      await expectLater(
        service.publishNote(
          bound,
          accountId: 'acc_1',
          representation: PublicationRepresentation.original,
          originalRevisionId: 'wrong_revision_id',
          allowRestrictedEmbeds: true,
        ),
        throwsA(isA<ApiError>()),
      );

      await service.unpublishNote(
        'n_pub',
        accountId: 'acc_1',
        publicationRevision: 5,
      );
      expect(calls.last.method, 'DELETE');
      expect(
        calls.last.path,
        '/apps/annotations/v1/me/notes/srv_pub/publication',
      );
      expect(calls.last.ifMatch, '"5"');

      await service.deleteCloudNote(
        'n_pub',
        accountId: 'acc_1',
        expectedRevision: 7,
        deleteOwnedReports: true,
      );
      expect(calls.last.method, 'DELETE');
      expect(calls.last.path, '/apps/annotations/v1/me/notes/srv_pub');
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
      catalog1.assignNoteToProject('local_typed', 'proj_1');
      catalog1.addTag('local_typed', 'Exam');
      expect(
        () => catalog1.createLocalProject('proj_2', '  research  '),
        throwsStateError,
      );

      // Reload from disk in a fresh instance.
      final catalog2 = ProjectTagCatalog(persistenceFile: catalogFile);
      expect(catalog2.projectForNote('local_typed'), 'proj_1');
      expect(catalog2.tagsForNote('local_typed'), {'exam'});

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
              jsonEncode({
                'note_id': 'n_typed',
                'revision': 1,
                'revisions': [
                  {'representation': 'typed', 'revision_id': 'typed_rev_1'},
                ],
              }),
              201,
            );
          }
          if (req.url.path.endsWith('/n_typed/publication') &&
              body?['representations']?['typed'] != 'typed_rev_1') {
            return http.Response(
              jsonEncode({'error': 'invalid_representation_revision'}),
              422,
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

      final typedSchema = DocumentSchema(DocumentFamily.typed.schemaName, 1);
      final projectNote = await store.save(
        LocalNoteDraft(
          id: 'local_typed',
          schema: typedSchema,
          document: NoteDocument.fromJson({'blocks': []}, schema: typedSchema),
          title: 'Typed note',
        ),
      );
      await store.setSync(
        projectNote.id,
        state: LocalSyncState.synced,
        accountId: 'acc_1',
        serverNoteId: 'srv_typed',
        serverRevision: 3,
      );
      final projectBoundNote = (await store.load(projectNote.id))!;
      final beforeWrongAccountProjectSync = calls.length;
      await expectLater(
        catalog2.syncProjectAndTags(
          api,
          accountId: 'acc_2',
          note: projectBoundNote,
        ),
        throwsA(isA<CloudIdentityException>()),
      );
      expect(calls, hasLength(beforeWrongAccountProjectSync));
      await catalog2.syncProjectAndTags(
        api,
        accountId: 'acc_1',
        note: projectBoundNote,
      );
      expect(calls[2].method, 'POST');
      expect(calls[2].path, '/apps/annotations/v1/me/projects');
      expect(calls[3].method, 'PUT');
      expect(
        calls[3].path,
        '/apps/annotations/v1/me/projects/proj_1/notes/srv_typed',
      );
      expect(calls[4].method, 'PATCH');
      expect(calls[4].path, '/apps/annotations/v1/me/notes/srv_typed');
      expect(calls[4].ifMatch, '"3"');
      expect(calls[4].body['metadata'], {
        'tags': ['exam'],
      });

      final missingTypedRevisionCalls = <String>[];
      final noRevisionService = NoteSyncService(
        store: store,
        api: ApiAdapter(
          client: MockClient((req) async {
            missingTypedRevisionCalls.add(req.method);
            return http.Response(
              jsonEncode({
                'note_id': 'created_without_revision',
                'revision': 1,
              }),
              201,
            );
          }),
          base: 'https://api.asodya.com/apps/annotations/v1',
        ),
      );
      await expectLater(
        noRevisionService.createAndPublishTypedNote(
          title: 'No revision response',
          blocks: const [],
        ),
        throwsA(isA<CloudIdentityException>()),
      );
      expect(missingTypedRevisionCalls, ['POST']);
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

  test(
    'strict server-id double enforces distinct server note_id, persisted reload, server revision If-Match, conflict retrieval, publication/deletion, account isolation, backup/restore, and client_note_id recovery',
    () async {
      final att = await store.importBytes(
        Uint8List.fromList([3, 1, 4]),
        name: 'sketch.png',
        type: 'image/png',
      );
      var activeAccount = 'acc_1';
      var seq = 0;
      var revSeq = 0;
      final serverNotes = <String, _ServerNoteRecord>{};
      final calls = <({String method, String path, String? ifMatch})>[];
      var forceNextSyncConflict = false;

      final client = AnnotationsApiContract(
        onValid: (req, body) async {
          final path = req.url.path.substring('/apps/annotations/v1'.length);
          calls.add((
            method: req.method,
            path: path,
            ifMatch: req.headers['if-match'],
          ));

          if (req.method == 'GET' && path == '/me/notes') {
            final owned = serverNotes.values
                .where((n) => n.owner == activeAccount)
                .toList();
            final cursor = req.url.queryParameters['cursor'];
            final page = cursor == null
                ? owned.take(1).toList()
                : owned.skip(1).toList();
            final nextCursor = cursor == null && owned.length > 1 ? 'p2' : null;
            return http.Response(
              jsonEncode({
                'items': [
                  for (final n in page)
                    {
                      'note_id': n.noteId,
                      'client_note_id': n.clientNoteId,
                      'main_representation': 'original',
                      'revision': n.revision,
                      'representations': [
                        {
                          'representation': 'original',
                          'revision_id': n.originalRevisionId,
                          'schema_version': 1,
                        },
                      ],
                    },
                ],
                'next_cursor': nextCursor,
              }),
              200,
            );
          }

          if (req.method == 'POST' && path == '/me/notes') {
            final clientId = '${body!['client_note_id']}';
            final existing = serverNotes.values.where(
              (n) => n.owner == activeAccount && n.clientNoteId == clientId,
            );
            if (existing.isNotEmpty) {
              final hit = existing.first;
              return http.Response(
                jsonEncode({
                  'note_id': hit.noteId,
                  'client_note_id': hit.clientNoteId,
                  'revision': hit.revision,
                  'created': false,
                }),
                200,
              );
            }
            final sid = 'srv_note_${++seq}';
            final revId = 'rev_orig_${++revSeq}';
            // Server identifiers must never equal the local client id.
            expect(sid, isNot(clientId));
            final reps = body['representations'] as Map;
            final doc = Map<String, dynamic>.from(
              (reps['original'] as Map)['document'] as Map,
            );
            serverNotes[sid] = _ServerNoteRecord(
              noteId: sid,
              owner: activeAccount,
              clientNoteId: clientId,
              revision: 1,
              originalRevisionId: revId,
              document: doc,
            );
            return http.Response(
              jsonEncode({
                'note_id': sid,
                'revision': 1,
                'revisions': [
                  {'representation': 'original', 'revision_id': revId},
                ],
                'client_note_id': clientId,
                'created': true,
              }),
              201,
            );
          }

          final pubMatch = RegExp(
            r'^/me/notes/([^/]+)/publication$',
          ).firstMatch(path);
          if (pubMatch != null) {
            final nid = pubMatch.group(1)!;
            final rec = serverNotes[nid];
            if (rec == null || rec.owner != activeAccount) {
              return http.Response(jsonEncode({'error': 'not_found'}), 404);
            }
            if (req.method == 'PUT') {
              final sentOrig = (body!['representations'] as Map)['original'];
              if (sentOrig != rec.originalRevisionId) {
                return http.Response(
                  jsonEncode({'error': 'revision_not_found'}),
                  422,
                );
              }
              rec.pubRevision += 1;
              return http.Response(
                jsonEncode({'note_id': nid, 'revision': rec.pubRevision}),
                200,
              );
            }
            if (req.method == 'DELETE') {
              rec.pubRevision += 1;
              return http.Response('', 204);
            }
          }

          final noteMatch = RegExp(r'^/me/notes/([^/]+)$').firstMatch(path);
          if (noteMatch != null) {
            final nid = noteMatch.group(1)!;
            final rec = serverNotes[nid];
            // Strictly reject local/unknown ids with 404.
            if (rec == null || rec.owner != activeAccount) {
              return http.Response(jsonEncode({'error': 'not_found'}), 404);
            }
            if (req.method == 'GET') {
              return http.Response(
                jsonEncode({
                  'note_id': rec.noteId,
                  'client_note_id': rec.clientNoteId,
                  'main_representation': 'original',
                  'revision': rec.revision,
                  'title': 'Server Title',
                  'representations': [
                    {
                      'representation': 'original',
                      'revision_id': rec.originalRevisionId,
                      'schema_version': 1,
                      'document': rec.document,
                    },
                  ],
                }),
                200,
              );
            }
            final expected = req.headers['if-match']?.replaceAll('"', '');
            if (expected != '${rec.revision}') {
              return http.Response(
                jsonEncode({
                  'error': 'revision_conflict',
                  'current_revision': rec.revision,
                }),
                409,
              );
            }
            if (forceNextSyncConflict) {
              forceNextSyncConflict = false;
              rec.revision += 1;
              rec.originalRevisionId = 'rev_orig_${++revSeq}';
              rec.document = _paperWithTextAndFile(
                'server concurrent edit',
                att.id,
              ).toJson();
              return http.Response(
                jsonEncode({
                  'error': 'revision_conflict',
                  'current_revision': rec.revision,
                }),
                409,
              );
            }
            if (req.method == 'DELETE') {
              serverNotes.remove(nid);
              return http.Response('', 204);
            }
            rec.revision += 1;
            rec.originalRevisionId = 'rev_orig_${++revSeq}';
            return http.Response(
              jsonEncode({
                'note_id': rec.noteId,
                'revision': rec.revision,
                'revisions': [
                  {
                    'representation': 'original',
                    'revision_id': rec.originalRevisionId,
                  },
                ],
              }),
              200,
            );
          }

          return http.Response(jsonEncode({'error': 'not_found'}), 404);
        },
      ).toMockClient();

      NoteSyncService serviceFor(SqliteNoteStore s) => NoteSyncService(
        store: s,
        api: ApiAdapter(
          client: client,
          base: 'https://api.asodya.com/apps/annotations/v1',
        ),
      );

      final v1 = _paperWithTextAndFile('draft 1', att.id);
      await store.save(
        LocalNoteDraft(
          id: 'local_only_1',
          schema: _paperSchema,
          document: v1,
          title: 'Strict Flow',
        ),
      );

      // 1. First upload issues srv_note_1 != local_only_1 and persists both server id and revision.
      final service = serviceFor(store);
      final first = await service.syncNote(
        (await store.load('local_only_1'))!,
        accountId: 'acc_1',
      );
      expect(first.localNote.id, 'local_only_1');
      expect(first.localNote.serverNoteId, 'srv_note_1');
      expect(first.localNote.serverRevision, 1);
      expect(first.localNote.serverOriginalRevisionId, 'rev_orig_1');

      // 2. Reopen SQLite store to prove server id + revision survive restarts.
      await store.close();
      store = await SqliteNoteStore.open(tempDir.path);
      final persisted = (await store.load('local_only_1'))!;
      expect(persisted.serverNoteId, 'srv_note_1');
      expect(persisted.serverRevision, 1);

      // 3. Edit locally twice (local revision becomes 3, while serverRevision stays 1).
      await store.save(
        LocalNoteDraft(
          id: 'local_only_1',
          schema: _paperSchema,
          document: _paperWithTextAndFile('draft 2', att.id),
          title: 'Strict Flow',
        ),
      );
      final edited3 = await store.save(
        LocalNoteDraft(
          id: 'local_only_1',
          schema: _paperSchema,
          document: _paperWithTextAndFile('draft 3', att.id),
          title: 'Strict Flow',
        ),
      );
      expect(edited3.revision, 3);
      expect(edited3.serverRevision, 1);

      final second = await serviceFor(
        store,
      ).syncNote(edited3, accountId: 'acc_1', baseDocument: v1);
      expect(calls.last.method, 'PATCH');
      expect(calls.last.path, '/me/notes/srv_note_1');
      expect(calls.last.ifMatch, '"1"');
      expect(second.localNote.serverRevision, 2);
      expect(second.localNote.serverOriginalRevisionId, 'rev_orig_2');

      // 4. Subsequent PUT uses srv_note_1 + If-Match "2".
      final third = await serviceFor(
        store,
      ).syncNote(second.localNote, accountId: 'acc_1');
      expect(calls.last.method, 'PUT');
      expect(calls.last.path, '/me/notes/srv_note_1');
      expect(calls.last.ifMatch, '"2"');
      expect(third.localNote.serverRevision, 3);
      expect(third.localNote.serverOriginalRevisionId, 'rev_orig_3');

      // 5. Publish and unpublish hit /me/notes/srv_note_1/publication using server revision_id.
      final pub = await serviceFor(store).publishNote(
        third.localNote,
        accountId: 'acc_1',
        representation: PublicationRepresentation.original,
      );
      expect(pub.published, isTrue);
      expect(calls.last.path, '/me/notes/srv_note_1/publication');

      await serviceFor(store).unpublishNote(
        'local_only_1',
        accountId: 'acc_1',
        publicationRevision: 1,
      );
      expect(calls.last.method, 'DELETE');
      expect(calls.last.path, '/me/notes/srv_note_1/publication');

      // 6. Conflict 409 calls GET /me/notes/srv_note_1 and parses representations[].
      forceNextSyncConflict = true;
      final conflict = await serviceFor(
        store,
      ).syncNote(third.localNote, accountId: 'acc_1');
      expect(conflict.isConflict, isTrue);
      expect(calls.last.method, 'GET');
      expect(calls.last.path, '/me/notes/srv_note_1');
      expect(conflict.conflictCopy!.accountId, 'acc_1');
      expect(conflict.conflictCopy!.isConflictCopy, isTrue);
      expect(conflict.conflictCopy!.serverNoteId, isNull);
      expect(
        (await serviceFor(store).notesForAccount('acc_2')).map((n) => n.id),
        isNot(contains(conflict.conflictCopy!.id)),
      );
      expect(
        (await serviceFor(store).notesForAccount(null)).map((n) => n.id),
        isNot(contains(conflict.conflictCopy!.id)),
      );
      expect(
        jsonEncode(conflict.conflictCopy!.document.toJson()),
        contains('server concurrent edit'),
      );

      // Update stored serverRevision to server's new revision 4 before deleting, simulating sync/refresh:
      await store.setSync(
        'local_only_1',
        state: LocalSyncState.changed,
        accountId: 'acc_1',
        serverNoteId: 'srv_note_1',
        serverRevision: 4,
      );

      // 7. Switching account cannot reuse acc_1 mapping.
      await expectLater(
        serviceFor(store).deleteCloudNote('local_only_1', accountId: 'acc_2'),
        throwsA(isA<AccountOwnershipException>()),
      );

      // 8. Delete everywhere uses srv_note_1 and clears all cloud identity while keeping local copy.
      await serviceFor(
        store,
      ).deleteCloudNote('local_only_1', accountId: 'acc_1');
      expect(calls.last.method, 'DELETE');
      expect(calls.last.path, '/me/notes/srv_note_1');
      expect(calls.last.ifMatch, '"4"');
      final afterDelete = (await store.load('local_only_1'))!;
      expect(afterDelete.accountId, isNull);
      expect(afterDelete.serverNoteId, isNull);
      expect(afterDelete.serverRevision, isNull);

      // Re-uploading as acc_2 does a fresh POST, never reusing acc_1's server id.
      activeAccount = 'acc_2';
      final reuploaded = await serviceFor(
        store,
      ).syncNote(afterDelete, accountId: 'acc_2');
      expect(reuploaded.localNote.serverNoteId, 'srv_note_2');
      expect(reuploaded.localNote.serverNoteId, isNot('srv_note_1'));

      // 9. Restored backup copy has no cloud identity and creates srv_note_3 on first sync.
      final pkg = await NoteBackupService().exportPackage(
        store,
        'local_only_1',
      );
      final restored = await NoteBackupService().restorePackage(
        store,
        pkg,
        newNoteId: 'restored_copy_1',
      );
      expect(restored.accountId, isNull);
      expect(restored.serverNoteId, isNull);
      expect(restored.serverRevision, isNull);
      final restoredSync = await serviceFor(
        store,
      ).syncNote(restored, accountId: 'acc_2');
      expect(restoredSync.localNote.serverNoteId, 'srv_note_3');
      expect(calls.last.method, 'POST');

      // 10. Recovery via paginated GET /me/notes for a pre-#63 bound note missing serverNoteId (no duplicate POST).
      await store.save(
        LocalNoteDraft(
          id: 'restored_copy_1',
          schema: _paperSchema,
          document: _paperWithTextAndFile(
            'edited before mapping saved',
            att.id,
          ),
          title: 'Strict Flow Copy',
        ),
      );
      await store.setSync(
        'restored_copy_1',
        state: LocalSyncState.local,
        accountId: null,
      );
      // Bind without server_note_id directly in SQLite row, simulating upgraded legacy metadata.
      await store.setSync(
        'restored_copy_1',
        state: LocalSyncState.changed,
        accountId: 'acc_2',
      );
      final legacyBound = (await store.load('restored_copy_1'))!;
      expect(legacyBound.serverNoteId, isNull);

      final beforeCount = calls.length;
      final recovered = await serviceFor(
        store,
      ).syncNote(legacyBound, accountId: 'acc_2');
      final recoveryCalls = calls.skip(beforeCount).toList();
      expect(recoveryCalls.where((c) => c.method == 'POST'), isEmpty);
      expect(
        recoveryCalls.where((c) => c.method == 'GET' && c.path == '/me/notes'),
        hasLength(2),
      );
      expect(recovered.localNote.serverNoteId, 'srv_note_3');
      expect(recovered.localNote.serverRevision, 2);

      // Unknown bound note fails loudly without guessing local id or uploading duplicate.
      await store.save(
        LocalNoteDraft(
          id: 'orphan_bound',
          schema: _paperSchema,
          document: v1,
          title: 'Missing On Server',
        ),
      );
      await store.setSync(
        'orphan_bound',
        state: LocalSyncState.changed,
        accountId: 'acc_2',
      );
      final beforeOrphan = calls.length;
      await expectLater(
        serviceFor(
          store,
        ).syncNote((await store.load('orphan_bound'))!, accountId: 'acc_2'),
        throwsA(isA<CloudIdentityException>()),
      );
      expect(
        calls
            .skip(beforeOrphan)
            .where(
              (c) =>
                  c.method == 'POST' ||
                  c.method == 'PUT' ||
                  c.method == 'PATCH',
            ),
        isEmpty,
      );
    },
  );
}

final class _ServerNoteRecord {
  _ServerNoteRecord({
    required this.noteId,
    required this.owner,
    required this.clientNoteId,
    required this.revision,
    required this.originalRevisionId,
    required this.document,
  });

  final String noteId;
  final String owner;
  final String clientNoteId;
  int revision;
  String originalRevisionId;
  Map<String, dynamic> document;
  int pubRevision = 0;
}
