import 'dart:convert';
import 'dart:io';

import 'package:annotations_shared/app.dart';
import 'package:annotations_shared/core/platform_profile.dart';
import 'package:annotations_shared/core/strings.dart';
import 'package:annotations_shared/dal/local/sqlite_note_store.dart';
import 'package:annotations_shared/dal/remote/aes_cbc.dart';
import 'package:annotations_shared/domain/models/local_note.dart';
import 'package:annotations_shared/domain/models/note_document.dart';
import 'package:annotations_shared/domain/services/installed_account.dart';
import 'package:annotations_shared/domain/services/local_workspace.dart';
import 'package:annotations_shared/domain/services/native_auth_service.dart';
import 'package:annotations_shared/domain/services/note_sync_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'design_goldens_test.dart' show loadAppFonts;
import 'fixtures.dart';

/// annotations#38 stage 4: sync, publish, unpublish and delete everywhere
/// from the writer workspace, with a fake that answers like the gateway and
/// annotations_api: the session cookie on every call, CSRF on writes, and
/// a server note id made by the server on the first upload.

const gateway = 'https://api.test';

class FakeCloud {
  final calls = <String>[];
  final storage = InMemorySecureSessionStorage();
  final serverIds = <String, String>{};
  final serverTypedRevisionIds = <String, String>{};
  int createResponsesToFail = 0;

  Map<String, dynamic> requestBody(http.Request request) {
    final bytes = request.headers['content-encoding'] == 'gzip'
        ? gzip.decode(request.bodyBytes)
        : request.bodyBytes;
    return jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
  }

  late final client = MockClient((r) async {
    calls.add('${r.method} ${r.url.path}');
    final session = (r.headers['cookie'] ?? '').contains('sid=sid-1');
    if (r.url.path == '/user/info/v1/') {
      return session
          ? json({
              'data': {'id': 'user-1', 'email': 'ana@example.com'},
            })
          : json({'detail': 'x'}, 403);
    }
    if (!r.url.path.startsWith('/apps/annotations/v1/me/')) {
      return json({'detail': 'Not Found'}, 404);
    }
    if (!session) return json({'detail': 'Authentication required'}, 401);
    if (r.method != 'GET' && r.headers['x-csrf-token'] != 'csrf-1') {
      return json({'detail': 'Missing Authentications Parameters...'}, 403);
    }
    final path = r.url.path.substring('/apps/annotations/v1'.length);
    if (r.method == 'POST' && path == '/me/notes') {
      final body = requestBody(r);
      final clientId = '${body['client_note_id']}';
      if (body['main_representation'] != 'typed' ||
          body['representations'] is! Map ||
          (body['representations'] as Map)['typed'] is! Map) {
        return json({'error': 'invalid_create_contract'}, 422);
      }
      final wasCreated = serverIds.containsKey(clientId);
      final id = serverIds.putIfAbsent(
        clientId,
        () => 'srv-${serverIds.length + 1}',
      );
      final typedRevisionId = serverTypedRevisionIds.putIfAbsent(
        id,
        () => 'typed-rev-${serverIds.length}',
      );
      if (createResponsesToFail > 0) {
        createResponsesToFail--;
        // The server has accepted the idempotent create, but the client loses
        // its response. A retry gets the real existing-note response below.
        return json({'error': 'temporary_unavailable'}, 503);
      }
      if (wasCreated) {
        return json({
          'note_id': id,
          'client_note_id': clientId,
          'revision': 1,
          'created': false,
        });
      }
      return json({
        'note_id': id,
        'client_note_id': clientId,
        'revision': 1,
        'revisions': [
          {
            'representation': 'typed',
            'revision_id': typedRevisionId,
            'schema_version': 1,
          },
        ],
        'created': true,
      }, 201);
    }
    // Later cloud operations must use the server's id, like annotations_api.
    String? serverId;
    for (final id in serverIds.values) {
      if (path.contains('/$id')) {
        serverId = id;
        break;
      }
    }
    if (serverId == null) return json({'error': 'not_found'}, 404);
    final clientId = serverIds.entries
        .where((entry) => entry.value == serverId)
        .first
        .key;
    final typedRevisionId = serverTypedRevisionIds[serverId]!;
    if (r.method == 'GET' && path == '/me/notes/$serverId') {
      return json({
        'note_id': serverId,
        'client_note_id': clientId,
        'revision': 1,
        'representations': [
          {
            'representation': 'typed',
            'revision_id': typedRevisionId,
            'schema_version': 1,
          },
        ],
      });
    }
    if (r.method == 'PUT' && path == '/me/notes/$serverId/publication') {
      final body = requestBody(r);
      if (r.headers['if-match'] != '"0"' ||
          body['language'] != 'en' ||
          (body['representations'] as Map?)?['typed'] != typedRevisionId) {
        return json({'error': 'invalid_publication_contract'}, 422);
      }
      return json({
        'note_id': serverId,
        'published': true,
        'revision': 1,
        'language': 'en',
        'representations': [
          {
            'representation': 'typed',
            'revision_id': typedRevisionId,
            'schema_version': 1,
          },
        ],
      });
    }
    return json({'error': 'not_found'}, 404);
  });

  static http.Response json(Object body, [int status = 200]) =>
      http.Response(jsonEncode(body), status);

  late final account = InstalledAccount(
    auth: NativeAuthService(
      client: client,
      storage: storage,
      gatewayBaseUrl: gateway,
    ),
    client: client,
    platform: 'linux',
    open: (_) async {},
    aes: aesCbcEncrypt,
    appContextKey: 'AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=',
  );
}

late Directory root;
late SqliteNoteStore store;
final typed = DocumentSchema('note-typed', 1);

Future<void> note(String id, String title, {bool restricted = false}) =>
    store.save(
      LocalNoteDraft(
        id: id,
        schema: typed,
        document: NoteDocument.fromJson({
          'blocks': [
            if (restricted)
              {
                'id': 'r1',
                'kind': 'task_card',
                'task_id': 't1',
                'visibility': 'private',
              },
          ],
        }, schema: typed),
        title: title,
      ),
    );

Future<void> openApp(WidgetTester tester, FakeCloud cloud) async {
  tester.platformDispatcher.accessibilityFeaturesTestValue =
      const FakeAccessibilityFeatures(disableAnimations: true);
  addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
  SharedPreferences.setMockInitialValues({});
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(1300, 1000);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    AnnotationsApp(
      key: UniqueKey(),
      trackingEnabled: false,
      service: fixtureService(),
      workspace: LocalWorkspace(
        store: store,
        catalog: ProjectTagCatalog(),
        profile: PlatformProfile.phone,
      ),
      installed: cloud.account,
    ),
  );
  await settle(tester);
}

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
  }
}

Future<void> action(WidgetTester tester, String id, String key) async {
  await tester.tap(find.byKey(Key('actions-$id')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(Key('$key-$id')));
  await settle(tester);
}

Finder stateOf(String id, String key) => find.descendant(
  of: find.byKey(Key('state-$id')),
  matching: find.text(translate(key, 'en')),
);

Future<void> signIn(FakeCloud cloud) => cloud.storage.writeSession(
  const NativeSession(sessionId: 'sid-1', csrfToken: 'csrf-1'),
);

void main() {
  setUpAll(loadAppFonts);
  setUp(() async {
    root = await Directory.systemTemp.createTemp('cloud_');
    store = await SqliteNoteStore.open(root.path);
  });
  tearDown(() async {
    await store.close();
    await root.delete(recursive: true);
  });

  testWidgets('signed out, the note menu leads to Sign in only', (
    tester,
  ) async {
    final cloud = FakeCloud();
    await tester.runAsync(() => note('a', 'Biology'));
    await openApp(tester, cloud);
    await tester.tap(find.byKey(const Key('actions-a')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('sync-a')), findsNothing);
    expect(find.byKey(const Key('publish-a')), findsNothing);
    await tester.tap(find.byKey(const Key('sign-in-to-sync-a')));
    await settle(tester);
    expect(
      GoRouter.of(tester.element(find.byType(Navigator).last)).state.uri.path,
      '/v1/sign-in',
    );
  });

  testWidgets('Sync sends the session and marks the note Synced', (
    tester,
  ) async {
    final cloud = FakeCloud();
    await signIn(cloud);
    await tester.runAsync(() => note('a', 'Biology'));
    await openApp(tester, cloud);
    expect(stateOf('a', 'stateLocal'), findsOneWidget);
    await action(tester, 'a', 'sync');
    expect(cloud.calls, contains('POST /apps/annotations/v1/me/notes'));
    expect(stateOf('a', 'stateSynced'), findsOneWidget);
    final saved = await tester.runAsync(() => store.load('a'));
    expect(saved!.accountId, 'user-1');
  });

  testWidgets('Publish shows the account; locked cards need a choice', (
    tester,
  ) async {
    final cloud = FakeCloud();
    await signIn(cloud);
    await tester.runAsync(() => note('a', 'Plan', restricted: true));
    await openApp(tester, cloud);
    await action(tester, 'a', 'publish');
    expect(find.textContaining('ana@example.com'), findsOneWidget);
    // A phone note is typed only.
    expect(find.byKey(const Key('publish-original')), findsNothing);
    expect(find.byKey(const Key('publish-typed')), findsOneWidget);
    expect(find.byKey(const Key('publish-restricted')), findsOneWidget);
    // Publish stays off until the user accepts the locked cards.
    await tester.tap(find.byKey(const Key('publish-confirm')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('publish-account')), findsOneWidget);
    await tester.tap(find.byKey(const Key('publish-cancel')));
    await settle(tester);
    expect(cloud.calls.where((c) => c.contains('publication')), isEmpty);
  });

  testWidgets('a failed cloud call shows Failed with Retry', (tester) async {
    final cloud = FakeCloud()..createResponsesToFail = 1;
    await signIn(cloud);
    await tester.runAsync(() => note('a', 'Plan'));
    await openApp(tester, cloud);
    await action(tester, 'a', 'publish');
    await tester.tap(find.byKey(const Key('publish-confirm')));
    await settle(tester);
    // The server accepted the create but its response was lost.
    expect(stateOf('a', 'stateFailed'), findsOneWidget);
    expect(find.byKey(const Key('retry-a')), findsOneWidget);
    expect(
      cloud.calls.where((c) => c == 'POST /apps/annotations/v1/me/notes'),
      hasLength(1),
    );
    expect(cloud.calls.where((c) => c.contains('/publication')), isEmpty);
    await tester.tap(find.byKey(const Key('retry-a')));
    await settle(tester);
    expect(
      cloud.calls.where((c) => c == 'POST /apps/annotations/v1/me/notes'),
      hasLength(2),
    );
    expect(cloud.calls, contains('GET /apps/annotations/v1/me/notes/srv-1'));
    expect(
      cloud.calls,
      contains('PUT /apps/annotations/v1/me/notes/srv-1/publication'),
    );
    expect(stateOf('a', 'stateSynced'), findsOneWidget);
    expect(find.byKey(const Key('retry-a')), findsNothing);
    await tester.tap(find.byKey(const Key('actions-a')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('unpublish-a')), findsOneWidget);
  });

  testWidgets('Delete everywhere asks first and keeps the device copy', (
    tester,
  ) async {
    final cloud = FakeCloud();
    await signIn(cloud);
    await tester.runAsync(() async {
      await note('a', 'Plan');
      await store.setSync(
        'a',
        state: LocalSyncState.synced,
        accountId: 'user-1',
      );
    });
    await openApp(tester, cloud);
    await tester.tap(find.byKey(const Key('actions-a')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('delete-everywhere-a')));
    await tester.pumpAndSettle();
    expect(find.text(translate('deleteEverywhereText', 'en')), findsOneWidget);
    await tester.tap(find.byKey(const Key('delete-cancel')));
    await settle(tester);
    expect(cloud.calls.where((c) => c.startsWith('DELETE')), isEmpty);
    expect(find.text('Plan'), findsOneWidget);
  });

  testWidgets('a refused cloud call signs out once', (tester) async {
    final cloud = FakeCloud();
    await signIn(cloud);
    await tester.runAsync(() => note('a', 'Plan'));
    await openApp(tester, cloud);
    // The server ends the session while the app is open.
    await cloud.storage.writeSession(
      const NativeSession(sessionId: 'gone', csrfToken: 'csrf-1'),
    );
    await tester.runAsync(cloud.account.check);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('bar-sign-in')), findsOneWidget);
    expect(await cloud.storage.readSession(), isNull);
  });
}
