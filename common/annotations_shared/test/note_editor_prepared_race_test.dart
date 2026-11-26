import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:annotations_shared/core/platform_profile.dart';
import 'package:annotations_shared/dal/local/sqlite_note_store.dart';
import 'package:annotations_shared/dal/remote/aes_cbc.dart';
import 'package:annotations_shared/dal/remote/api_adapter.dart';
import 'package:annotations_shared/domain/models/local_note.dart';
import 'package:annotations_shared/domain/models/note_document.dart';
import 'package:annotations_shared/domain/services/annotations_service.dart';
import 'package:annotations_shared/domain/services/installed_account.dart';
import 'package:annotations_shared/domain/services/local_workspace.dart';
import 'package:annotations_shared/domain/services/native_auth_service.dart';
import 'package:annotations_shared/domain/services/note_sync_service.dart';
import 'package:annotations_shared/domain/services/preferences.dart';
import 'package:annotations_shared/presentation/frontend/components/scope.dart';
import 'package:annotations_shared/presentation/frontend/widgets/workspace/note_editor_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'design_goldens_test.dart' show loadAppFonts;

Future<void> pumpEditorFrames(WidgetTester tester) async {
  for (var frame = 0; frame < 12; frame++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

class SwitchableInstalledAccount extends InstalledAccount {
  SwitchableInstalledAccount(NativeSession session, http.Client client)
    : _session = session,
      super(
        auth: NativeAuthService(
          client: client,
          storage: InMemorySecureSessionStorage(),
        ),
        client: client,
        platform: 'linux',
        open: (_) async {},
        aes: aesCbcEncrypt,
        appContextKey: 'test-only-key',
      );

  NativeSession? _session;

  @override
  NativeSession? get activeSession => _session;

  @override
  bool get signedIn => _session != null;

  @override
  String? get localOwnerId => _session?.verifiedUserId;

  void switchTo(NativeSession? session) {
    _session = session;
    notifyListeners();
  }
}

class _TestHttpOverrides extends HttpOverrides {
  _TestHttpOverrides(this.onRequest);

  final Future<_StubHttpResponse> Function(
    String method,
    Uri uri,
    List<int> body,
  )
  onRequest;
  var clientCreations = 0;
  final requestedUrls = <Uri>[];

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    clientCreations++;
    return _StubHttpClient((method, uri, body) async {
      requestedUrls.add(uri);
      return onRequest(method, uri, body);
    });
  }
}

class _StubHttpClient implements HttpClient {
  _StubHttpClient(this.onRequest);

  final Future<_StubHttpResponse> Function(
    String method,
    Uri uri,
    List<int> body,
  )
  onRequest;

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async =>
      _StubHttpRequest(method, url, onRequest);

  @override
  void close({bool force = false}) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _StubHttpRequest implements HttpClientRequest {
  _StubHttpRequest(this.method, this.uri, this.onRequest);

  @override
  final String method;
  @override
  final Uri uri;
  final Future<_StubHttpResponse> Function(
    String method,
    Uri uri,
    List<int> body,
  )
  onRequest;
  final _body = BytesBuilder(copy: false);
  final _headers = _StubHttpHeaders();
  @override
  bool followRedirects = true;
  @override
  int maxRedirects = 5;
  @override
  int contentLength = -1;
  @override
  bool persistentConnection = true;

  @override
  HttpHeaders get headers => _headers;

  @override
  void add(List<int> data) => _body.add(data);

  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    await for (final data in stream) {
      add(data);
    }
  }

  @override
  Future<HttpClientResponse> close() async =>
      onRequest(method, uri, _body.takeBytes());

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _StubHttpHeaders implements HttpHeaders {
  final _values = <String, List<String>>{};

  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {
    _values[name.toLowerCase()] = ['$value'];
  }

  @override
  void add(String name, Object value, {bool preserveHeaderCase = false}) {
    _values.putIfAbsent(name.toLowerCase(), () => []).add('$value');
  }

  @override
  void forEach(void Function(String name, List<String> values) action) {
    _values.forEach(action);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _StubHttpResponse extends Stream<List<int>>
    implements HttpClientResponse {
  _StubHttpResponse(this.body, {this.statusCode = 200});

  final List<int> body;
  @override
  final int statusCode;
  @override
  int get contentLength => body.length;
  @override
  String get reasonPhrase => 'OK';
  @override
  HttpHeaders get headers {
    final result = _StubHttpHeaders();
    result.set('content-type', 'application/json');
    return result;
  }

  @override
  bool get isRedirect => false;
  @override
  bool get persistentConnection => false;
  @override
  List<RedirectInfo> get redirects => const [];

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => Stream<List<int>>.value(body).listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  setUpAll(loadAppFonts);

  testWidgets(
    'account switch during source catalog read stops the prepared quiz flow',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      late Directory root;
      late SqliteNoteStore store;
      await tester.runAsync(() async {
        root = await Directory.systemTemp.createTemp('prepared_race_');
        store = await SqliteNoteStore.open(root.path);
      });
      addTearDown(() async {
        await store.close();
        await root.delete(recursive: true);
      });

      final schema = DocumentSchema('note-original', 1);
      await tester.runAsync(
        () => store.save(
          LocalNoteDraft(
            id: 'note-race',
            schema: schema,
            document: NoteDocument.fromJson({
              'page': {
                'width': 1000,
                'background': {'kind': 'blank'},
              },
              'items': [
                {
                  'id': 'text-1',
                  'kind': 'text',
                  'x': 0,
                  'y': 0,
                  'width': 300,
                  'height': 40,
                  'spans': [
                    {'text': 'Local note text'},
                  ],
                },
              ],
            }, schema: schema),
            title: 'Local note',
            accountId: 'account-a',
          ),
        ),
      );
      await tester.runAsync(
        () => store.setSync(
          'note-race',
          state: LocalSyncState.synced,
          accountId: 'account-a',
          serverNoteId: 'server-note-a',
          serverRevision: 1,
          serverOriginalRevisionId: 'original-revision-1',
        ),
      );
      final accountClient = MockClient((_) async => http.Response('{}', 200));
      addTearDown(accountClient.close);
      final account = SwitchableInstalledAccount(
        const NativeSession(
          sessionId: 'session-a',
          csrfToken: 'csrf-a',
          verifiedUserId: 'account-a',
        ),
        accountClient,
      );
      expect(account.signedIn, isTrue);

      final catalogStarted = Completer<void>();
      final releaseCatalog = Completer<http.Response>();
      final apiCalls = <String>[];
      final apiClient = MockClient((request) {
        apiCalls.add('${request.method} ${request.url.path}');
        if (request.method == 'GET' &&
            request.url.path == '/apps/annotations/v1/me/notes/server-note-a') {
          if (!catalogStarted.isCompleted) catalogStarted.complete();
          return releaseCatalog.future;
        }
        return Future.value(http.Response('{}', 404));
      });
      addTearDown(apiClient.close);
      final workspace = LocalWorkspace(
        store: store,
        catalog: ProjectTagCatalog(),
        profile: PlatformProfile.fullWriter,
      );
      final preferences = Preferences();
      addTearDown(preferences.dispose);

      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1200, 900);
      addTearDown(tester.view.reset);
      await tester
          .pumpWidget(
            MaterialApp(
              home: AppScope(
                preferences: preferences,
                service: AnnotationsService(
                  api: ApiAdapter(
                    base: 'https://api.test/apps/annotations/v1',
                    client: apiClient,
                  ),
                ),
                workspace: workspace,
                installed: account,
                child: const NoteEditorPage(noteId: 'note-race'),
              ),
            ),
          )
          .timeout(const Duration(seconds: 5));

      await pumpEditorFrames(tester).timeout(const Duration(seconds: 5));

      expect(find.byKey(const Key('editor-prepare-quiz')), findsOneWidget);

      final prepareButton = find.byKey(const Key('editor-prepare-quiz'));
      final gesture = await tester.startGesture(
        tester.getCenter(prepareButton),
      );
      await gesture.up();
      await tester.pump();

      for (var frame = 0; frame < 12 && !catalogStarted.isCompleted; frame++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(
        catalogStarted.isCompleted,
        isTrue,
        reason: 'API calls: $apiCalls',
      );

      account.switchTo(
        const NativeSession(
          sessionId: 'session-b',
          csrfToken: 'csrf-b',
          verifiedUserId: 'account-b',
        ),
      );

      expect(account.activeSession?.verifiedUserId, 'account-b');
      releaseCatalog.complete(
        http.Response(
          jsonEncode({
            'note_id': 'server-note-a',
            'revision': 1,
            'title': 'Server note',
            'representations': [
              {
                'representation': 'original',
                'revision_id': 'original-revision-1',
                'document': {
                  'page': {
                    'width': 1000,
                    'background': {'kind': 'blank'},
                  },
                  'items': [
                    {
                      'kind': 'text',
                      'spans': [
                        {'text': 'Server note text'},
                      ],
                    },
                  ],
                },
              },
            ],
          }),
          200,
        ),
      );
      await pumpEditorFrames(tester).timeout(const Duration(seconds: 5));

      expect(find.byKey(const Key('quiz-source-note_original')), findsNothing);
      expect(apiCalls, ['GET /apps/annotations/v1/me/notes/server-note-a']);
      expect(account.activeSession?.verifiedUserId, 'account-b');
    },
  );

  testWidgets(
    'account switch after handoff creation cancels it without browser launch',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      late Directory root;
      late SqliteNoteStore store;
      await tester.runAsync(() async {
        root = await Directory.systemTemp.createTemp('prepared_handoff_race_');
        store = await SqliteNoteStore.open(root.path);
      });
      addTearDown(() async {
        await store.close();
        await root.delete(recursive: true);
      });

      final schema = DocumentSchema('note-original', 1);
      await tester.runAsync(
        () => store.save(
          LocalNoteDraft(
            id: 'note-handoff-race',
            schema: schema,
            document: NoteDocument.fromJson({
              'page': {
                'width': 1000,
                'background': {'kind': 'blank'},
              },
              'items': [
                {
                  'id': 'text-1',
                  'kind': 'text',
                  'x': 0,
                  'y': 0,
                  'width': 300,
                  'height': 40,
                  'spans': [
                    {'text': 'Local note text'},
                  ],
                },
              ],
            }, schema: schema),
            title: 'Local note',
            accountId: 'account-a',
          ),
        ),
      );
      await tester.runAsync(
        () => store.setSync(
          'note-handoff-race',
          state: LocalSyncState.synced,
          accountId: 'account-a',
          serverNoteId: 'server-note-a',
          serverRevision: 1,
          serverOriginalRevisionId: 'original-revision-1',
        ),
      );
      await tester.runAsync(
        () => store.savePreparedStudyReference(
          'note-handoff-race',
          accountId: 'account-a',
          serverNoteId: 'server-note-a',
          serverRevision: 1,
          studyId: 'study-existing',
        ),
      );

      final accountClient = MockClient((_) async => http.Response('{}', 200));
      addTearDown(accountClient.close);
      final account = SwitchableInstalledAccount(
        const NativeSession(
          sessionId: 'session-a',
          csrfToken: 'csrf-a',
          verifiedUserId: 'account-a',
        ),
        accountClient,
      );
      final apiCalls = <String>[];
      final apiClient = MockClient((request) async {
        apiCalls.add('${request.method} ${request.url.path}');
        if (request.method == 'GET' &&
            request.url.path == '/apps/annotations/v1/me/notes/server-note-a') {
          return http.Response(
            jsonEncode({
              'note_id': 'server-note-a',
              'revision': 1,
              'title': 'Server note',
              'representations': [
                {
                  'representation': 'original',
                  'revision_id': 'original-revision-1',
                  'document': {
                    'page': {
                      'width': 1000,
                      'background': {'kind': 'blank'},
                    },
                    'items': [
                      {
                        'id': 'text-1',
                        'kind': 'text',
                        'spans': [
                          {'text': 'Server note text'},
                        ],
                      },
                    ],
                  },
                },
              ],
            }),
            200,
          );
        }
        if (request.method == 'GET' &&
            request.url.path ==
                '/apps/certifications/v1/studies/study-existing') {
          return http.Response(
            jsonEncode({
              'study': {
                'id': 'study-existing',
                'title': 'Study',
                'status': 'draft',
              },
              'sources': [],
              'quota': {'used_bytes': 0, 'max_bytes': 100},
              'config': {'language': 'en', 'count': 10},
            }),
            200,
          );
        }
        return http.Response('{}', 404);
      });
      addTearDown(apiClient.close);

      final workspace = LocalWorkspace(
        store: store,
        catalog: ProjectTagCatalog(),
        profile: PlatformProfile.fullWriter,
      );
      final preferences = Preferences();
      addTearDown(preferences.dispose);
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1200, 900);
      addTearDown(tester.view.reset);

      final handoffActions = <String>[];
      late final _TestHttpOverrides overrides;
      overrides = _TestHttpOverrides((method, uri, body) async {
        expect(method, 'POST');
        expect(uri.path, '/apps/api/v1/exchange');
        final action =
            (jsonDecode(utf8.decode(body)) as Map<String, dynamic>)['action'];
        handoffActions.add(action as String);
        if (action == 'create_browser_handoff') {
          account.switchTo(
            const NativeSession(
              sessionId: 'session-b',
              csrfToken: 'csrf-b',
              verifiedUserId: 'account-b',
            ),
          );
          return _StubHttpResponse(
            utf8.encode(
              jsonEncode({
                'data': {
                  'launch_url':
                      'https://certifications.asodya.com/continue?handoff_id=handoff-token-123',
                  'expires_at': 1795082400,
                },
              }),
            ),
          );
        }
        expect(action, 'cancel_browser_handoff');
        return _StubHttpResponse(utf8.encode('{}'));
      });
      final launchMethods = <String>[];
      const launcherChannel = MethodChannel('plugins.flutter.io/url_launcher');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        launcherChannel,
        (call) async {
          launchMethods.add(call.method);
          return true;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          launcherChannel,
          null,
        ),
      );

      await HttpOverrides.runZoned(() async {
        await tester.pumpWidget(
          MaterialApp(
            home: AppScope(
              preferences: preferences,
              service: AnnotationsService(
                api: ApiAdapter(
                  base: 'https://api.asodya.com/apps/annotations/v1',
                  client: apiClient,
                ),
              ),
              workspace: workspace,
              installed: account,
              child: const NoteEditorPage(noteId: 'note-handoff-race'),
            ),
          ),
        );
        await pumpEditorFrames(tester).timeout(const Duration(seconds: 5));
        final prepareButton = find.byKey(const Key('editor-prepare-quiz'));
        expect(prepareButton, findsOneWidget);
        await tester.tap(prepareButton);
        await tester.pump();
        await pumpEditorFrames(tester).timeout(const Duration(seconds: 5));

        expect(
          handoffActions,
          ['create_browser_handoff', 'cancel_browser_handoff'],
          reason:
              'API calls: $apiCalls; HttpClient constructors: '
              '${overrides.clientCreations}; gateway URLs: '
              '${overrides.requestedUrls}',
        );
        expect(account.activeSession?.verifiedUserId, 'account-b');
        expect(launchMethods, isEmpty);
        expect(apiCalls, [
          'GET /apps/annotations/v1/me/notes/server-note-a',
          'GET /apps/certifications/v1/studies/study-existing',
        ]);
        expect(overrides.requestedUrls, [
          Uri.parse('https://api.asodya.com/apps/api/v1/exchange'),
          Uri.parse('https://api.asodya.com/apps/api/v1/exchange'),
        ]);
        expect(tester.takeException(), isNull);
      }, createHttpClient: overrides.createHttpClient);
    },
  );
}
