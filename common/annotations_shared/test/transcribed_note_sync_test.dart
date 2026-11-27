import 'dart:convert';
import 'dart:io';

import 'package:annotations_shared/dal/local/sqlite_note_store.dart';
import 'package:annotations_shared/dal/remote/api_adapter.dart';
import 'package:annotations_shared/domain/models/local_note.dart';
import 'package:annotations_shared/domain/models/note_document.dart';
import 'package:annotations_shared/domain/services/local_note_store.dart';
import 'package:annotations_shared/domain/services/note_sync_service.dart';
import 'package:annotations_shared/domain/services/transcription_draft_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'support/annotations_api_contract.dart';

void main() {
  late Directory directory;
  late SqliteNoteStore store;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('transcribed-note-sync-');
    store = await SqliteNoteStore.open(directory.path);
  });

  tearDown(() async {
    await store.close();
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  test('syncs accepted Typed beside its existing server Original', () async {
    final original = await _saveOriginal(store, 'source-note');
    final typed = await _saveTyped(
      store: store,
      source: original,
      id: 'source-note__typed',
      runId: 'run-1',
      accountId: 'owner-a',
    );
    final requests =
        <
          ({
            String method,
            String path,
            String? ifMatch,
            Map<String, dynamic> body,
          })
        >[];
    final client = AnnotationsApiContract(
      onValid: (request, body) async {
        requests.add((
          method: request.method,
          path: request.url.path,
          ifMatch: request.headers['if-match'],
          body: body ?? const {},
        ));
        if (request.method == 'POST' &&
            request.url.path == '/apps/annotations/v1/me/notes') {
          expect(body?['representations']?.keys, contains('original'));
          expect(body?['representations']?.containsKey('typed'), isFalse);
          return http.Response(
            jsonEncode({
              'note_id': 'server-source',
              'revision': 1,
              'revisions': [
                {'representation': 'original', 'revision_id': 'orig-rev-1'},
              ],
            }),
            201,
          );
        }
        if (request.method == 'PUT' &&
            request.url.path == '/apps/annotations/v1/me/notes/server-source') {
          return http.Response(
            jsonEncode({
              'note_id': 'server-source',
              'revision': 2,
              'revisions': [
                {'representation': 'original', 'revision_id': 'orig-rev-1'},
                {'representation': 'typed', 'revision_id': 'typed-rev-1'},
              ],
            }),
            200,
          );
        }
        return http.Response('unexpected route', 404);
      },
    ).toMockClient();
    final service = NoteSyncService(
      store: store,
      api: ApiAdapter(
        client: client,
        base: 'https://api.asodya.com/apps/annotations/v1',
      ),
    );

    final result = await service.syncNote(typed, accountId: 'owner-a');

    expect(requests.map((request) => request.method), ['POST', 'PUT']);
    expect(requests.last.ifMatch, '"1"');
    expect(requests.last.body, {
      'representation': 'typed',
      'schema_version': 1,
      'document': typed.document.toJson(),
      'source_revision_id': 'orig-rev-1',
    });
    expect(
      requests.any((request) => request.path.endsWith('/publication')),
      isFalse,
    );
    expect(result.localNote.accountId, 'owner-a');
    expect(result.localNote.serverNoteId, 'server-source');
    expect(result.localNote.serverTypedRevisionId, 'typed-rev-1');
    expect(result.localNote.syncState, LocalSyncState.synced);
    final savedOriginal = (await store.load(original.id))!;
    expect(savedOriginal.document.toJson(), original.document.toJson());
    client.close();
  });

  test('stale source and foreign Typed id are never overwritten', () async {
    final original = await _saveOriginal(store, 'source-note');
    final foreign = await _saveTyped(
      store: store,
      source: original,
      id: 'source-note__typed',
      runId: 'other-run',
      accountId: 'owner-b',
      sourceNoteId: 'other-source',
    );
    final apiCalls = <String>[];
    final client = AnnotationsApiContract(
      onValid: (request, _) async {
        apiCalls.add('${request.method} ${request.url.path}');
        return http.Response('{}', 200);
      },
    ).toMockClient();
    final drafts = TranscriptionDraftService();
    drafts.saveDraft(
      noteId: original.id,
      sourceRevision: original.revision,
      passages: const [
        TranscriptionPassage(
          partId: 'text-1',
          sourceHash: 'part-hash',
          y: 1,
          x: 1,
          kind: TranscriptionPassageKind.text,
          text: 'accepted text',
        ),
      ],
    );

    await expectLater(
      drafts.acceptToTypedNote(
        original.id,
        store: store,
        accountId: 'owner-a',
        typedNoteId: foreign.id,
      ),
      throwsStateError,
    );
    expect(
      (await store.load(foreign.id))!.transcriptionSourceNoteId,
      'other-source',
    );

    final typed = await _saveTyped(
      store: store,
      source: original,
      id: 'source-note__typed-valid',
      runId: 'run-1',
      accountId: null,
    );
    await store.save(
      LocalNoteDraft(
        id: original.id,
        schema: original.schema,
        document: _originalDocument('changed'),
        title: original.title,
      ),
    );
    final service = NoteSyncService(
      store: store,
      api: ApiAdapter(
        client: client,
        base: 'https://api.asodya.com/apps/annotations/v1',
      ),
    );
    final typedBefore = (await store.load(typed.id))!;
    await expectLater(
      service.syncNote(typedBefore, accountId: 'owner-a'),
      throwsA(isA<CloudIdentityException>()),
    );
    expect(apiCalls, isEmpty);
    expect(
      (await store.load(typed.id))!.document.toJson(),
      typed.document.toJson(),
    );
    client.close();
  });
}

Future<LocalNote> _saveOriginal(LocalNoteStore store, String id) => store.save(
  LocalNoteDraft(
    id: id,
    schema: _originalSchema,
    document: _originalDocument('source'),
    title: 'Source',
  ),
);

Future<LocalNote> _saveTyped({
  required LocalNoteStore store,
  required LocalNote source,
  required String id,
  required String runId,
  required String? accountId,
  String? sourceNoteId,
}) => store.save(
  LocalNoteDraft(
    id: id,
    schema: _typedSchema,
    document: _typedDocument(),
    title: 'Typed',
    accountId: accountId,
    transcriptionSourceNoteId: sourceNoteId ?? source.id,
    transcriptionRunId: runId,
    transcriptionSourceHash: 'a' * 64,
    transcriptionSourceLocalRevision: source.revision,
  ),
);

final _originalSchema = DocumentSchema(DocumentFamily.original.schemaName, 1);
final _typedSchema = DocumentSchema(DocumentFamily.typed.schemaName, 1);

OriginalDocument _originalDocument(String text) =>
    NoteDocument.fromJson({
          'page': {
            'width': 500,
            'background': {'kind': 'blank'},
          },
          'items': [
            {
              'id': 'text-1',
              'kind': 'text',
              'x': 0,
              'y': 0,
              'width': 100,
              'height': 30,
              'spans': [
                {'text': text},
              ],
            },
          ],
        }, schema: _originalSchema)
        as OriginalDocument;

TypedDocument _typedDocument() =>
    NoteDocument.fromJson({
          'blocks': [
            {
              'id': 'paragraph-1',
              'kind': 'paragraph',
              'spans': [
                {'text': 'typed text'},
              ],
            },
          ],
        }, schema: _typedSchema)
        as TypedDocument;
