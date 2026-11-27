import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:annotations_shared/core/platform_profile.dart';
import 'package:annotations_shared/dal/local/sqlite_note_store.dart';
import 'package:annotations_shared/dal/remote/aes_cbc.dart';
import 'package:annotations_shared/dal/remote/api_adapter.dart';
import 'package:annotations_shared/domain/models/local_note.dart';
import 'package:annotations_shared/domain/models/note_document.dart';
import 'package:annotations_shared/domain/services/installed_account.dart';
import 'package:annotations_shared/domain/services/local_workspace.dart';
import 'package:annotations_shared/domain/services/native_auth_service.dart';
import 'package:annotations_shared/domain/services/note_sync_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

LocalWorkspace workspace(SqliteNoteStore store, PlatformProfile profile) =>
    LocalWorkspace(
      store: store,
      catalog: ProjectTagCatalog(),
      profile: profile,
    );

Map<String, dynamic> requestBody(http.Request request) {
  final bytes = request.bodyBytes;
  final decoded = request.headers['content-encoding'] == 'gzip'
      ? gzip.decode(bytes)
      : bytes;
  return jsonDecode(utf8.decode(decoded)) as Map<String, dynamic>;
}

void main() {
  late Directory root;
  late SqliteNoteStore store;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('study_source_');
    store = await SqliteNoteStore.open(root.path);
  });

  tearDown(() async {
    await store.close();
    await root.delete(recursive: true);
  });

  const source = StudySourceReference(
    noteId: 'published-typed-1',
    title: 'Geometry notes',
    authorId: 'author-1',
    authorName: 'A Reader',
  );

  test(
    'creates and reopens a distinct blank Original with quiet source metadata',
    () async {
      final ws = workspace(store, PlatformProfile.fullWriter);
      final id = await ws.createHandwrittenStudy(source);
      expect(id, isNot(source.noteId));

      var note = (await store.load(id))!;
      expect(note.schema.name, 'note-original');
      expect(note.title, isNull);
      expect(note.document, isA<PaperDocument>());
      expect((note.document as PaperDocument).items, isEmpty);
      expect(note.studySource, source);
      expect(note.studySource!.relationAttached, isFalse);

      // Normal autosave drafts do not erase the immutable source metadata.
      note = await store.save(
        LocalNoteDraft(id: id, schema: note.schema, document: note.document),
      );
      expect(note.studySource, source);
      await store.close();
      store = await SqliteNoteStore.open(root.path);
      note = (await store.load(id))!;
      expect(note.studySource, source);
      expect((note.document as PaperDocument).items, isEmpty);
    },
  );

  test('phone workspace cannot create a handwritten source study', () async {
    final ws = workspace(store, PlatformProfile.phone);
    await expectLater(ws.createHandwrittenStudy(source), throwsStateError);
    expect(await store.notes(), isEmpty);
    final phoneNoteId = await ws.createNote();
    expect((await store.load(phoneNoteId))!.schema.name, 'note-typed');
  });

  test(
    'source-unavailable retries once without relation and preserves content',
    () async {
      final ws = workspace(store, PlatformProfile.fullWriter);
      final id = await ws.createHandwrittenStudy(source);
      final original = (await store.load(id))!;
      final bodies = <Map<String, dynamic>>[];
      final client = MockClient((request) async {
        expect(request.method, 'POST');
        expect(request.url.path, '/me/notes');
        bodies.add(requestBody(request));
        if (bodies.length == 1) {
          return http.Response(
            jsonEncode({
              'error': 'The study source must be a published typed post',
              'code': 'study_source_unavailable',
            }),
            400,
          );
        }
        return http.Response(
          jsonEncode({
            'note_id': 'server-study-1',
            'revision': 1,
            'study_source': null,
            'revisions': [],
          }),
          201,
        );
      });
      final result = await NoteSyncService(
        store: store,
        api: ApiAdapter(client: client, base: 'https://api.test'),
      ).syncNote(original, accountId: 'owner-1');

      expect(result.isConflict, isFalse);
      expect(bodies, hasLength(2));
      expect(bodies.first['study_source_note_id'], source.noteId);
      expect(bodies.last.containsKey('study_source_note_id'), isFalse);
      for (final key in [
        'client_note_id',
        'main_representation',
        'representations',
        'metadata',
      ]) {
        expect(bodies.last[key], bodies.first[key], reason: key);
      }
      final synced = (await store.load(id))!;
      expect(synced.id, original.id);
      expect(synced.document.toJson(), original.document.toJson());
      expect(synced.studySource, source);
      expect(synced.studySource!.relationAttached, isFalse);
      expect(synced.serverNoteId, 'server-study-1');
    },
  );

  test(
    'source-unavailable response cannot retry through a replacement account',
    () async {
      final ws = workspace(store, PlatformProfile.fullWriter);
      final id = await ws.createHandwrittenStudy(source);
      final original = (await store.load(id))!;
      final postEntered = Completer<void>();
      final releasePost = Completer<http.Response>();
      var postCount = 0;
      Map<String, dynamic>? firstBody;
      final transport = MockClient((request) async {
        if (request.url.path == '/user/info/v1/') {
          final cookie = request.headers['cookie'] ?? '';
          final user = cookie.contains('sid-a') ? 'owner-a' : 'owner-b';
          return http.Response(
            jsonEncode({
              'data': {'id': user, 'email': '$user@test'},
            }),
            200,
          );
        }
        if (request.url.path == '/me/notes' && request.method == 'POST') {
          postCount++;
          expect(request.headers['cookie'], 'sid=sid-a; csrf=csrf-a');
          firstBody = requestBody(request);
          postEntered.complete();
          return releasePost.future;
        }
        return http.Response('unexpected request', 404);
      });
      final storage = InMemorySecureSessionStorage();
      final auth = NativeAuthService(
        client: transport,
        storage: storage,
        gatewayBaseUrl: 'https://auth.test',
      );
      final account = InstalledAccount(
        auth: auth,
        client: transport,
        platform: 'linux',
        open: (_) async {},
        aes: aesCbcEncrypt,
        appContextKey: 'test',
      );
      await auth.writeSession(
        const NativeSession(sessionId: 'sid-a', csrfToken: 'csrf-a'),
      );
      await account.check();

      final sync = NoteSyncService(
        store: store,
        api: ApiAdapter(
          client: SessionClient(account, transport),
          base: 'https://api.test',
        ),
      ).syncNote(original, accountId: 'owner-a');
      await postEntered.future;

      await auth.writeSession(
        const NativeSession(sessionId: 'sid-b', csrfToken: 'csrf-b'),
      );
      await account.check();
      releasePost.complete(
        http.Response(
          jsonEncode({
            'error': 'The study source must be a published typed post',
            'code': 'study_source_unavailable',
          }),
          400,
        ),
      );

      await expectLater(sync, throwsA(isA<ApiError>()));
      expect(account.userId, 'owner-b');
      expect(postCount, 1, reason: 'fallback must not use replacement B');
      expect(firstBody?['client_note_id'], id);
      expect(firstBody?['study_source_note_id'], source.noteId);
      final unchanged = (await store.load(id))!;
      expect(unchanged.accountId, isNull);
      expect(unchanged.serverNoteId, isNull);
      expect(unchanged.studySource, source);
      expect(unchanged.document.toJson(), original.document.toJson());
    },
  );

  test(
    'only confirms remote source attribution from the API response',
    () async {
      final ws = workspace(store, PlatformProfile.fullWriter);
      final id = await ws.createHandwrittenStudy(source);
      final original = (await store.load(id))!;
      final client = MockClient((request) async {
        final body = requestBody(request);
        expect(body['study_source_note_id'], source.noteId);
        return http.Response(
          jsonEncode({
            'note_id': 'server-study-2',
            'revision': 1,
            'study_source': {'note_id': source.noteId},
            'revisions': [],
          }),
          201,
        );
      });
      await NoteSyncService(
        store: store,
        api: ApiAdapter(client: client, base: 'https://api.test'),
      ).syncNote(original, accountId: 'owner-1');
      expect((await store.load(id))!.studySource!.relationAttached, isTrue);
    },
  );

  test(
    'unrelated source validation errors do not retry or mutate the note',
    () async {
      final ws = workspace(store, PlatformProfile.fullWriter);
      final id = await ws.createHandwrittenStudy(source);
      final original = (await store.load(id))!;
      var calls = 0;
      final client = MockClient((request) async {
        calls++;
        return http.Response(
          jsonEncode({
            'error': 'other invalid field',
            'code': 'invalid_metadata',
          }),
          400,
        );
      });
      await expectLater(
        NoteSyncService(
          store: store,
          api: ApiAdapter(client: client, base: 'https://api.test'),
        ).syncNote(original, accountId: 'owner-1'),
        throwsA(isA<ApiError>()),
      );
      expect(calls, 1);
      final unchanged = (await store.load(id))!;
      expect(unchanged.accountId, isNull);
      expect(unchanged.serverNoteId, isNull);
      expect(unchanged.document.toJson(), original.document.toJson());
      expect(unchanged.studySource, source);
    },
  );
}
