import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:annotations_shared/core/platform_profile.dart';
import 'package:annotations_shared/dal/local/sqlite_note_store.dart';
import 'package:annotations_shared/dal/remote/aes_cbc.dart';
import 'package:annotations_shared/dal/remote/api_adapter.dart';
import 'package:annotations_shared/domain/models/local_note.dart';
import 'package:annotations_shared/domain/models/note_document.dart';
import 'package:annotations_shared/domain/services/annotations_service.dart';
import 'package:annotations_shared/domain/services/installed_account.dart';
import 'package:annotations_shared/domain/services/local_note_store.dart';
import 'package:annotations_shared/domain/services/local_workspace.dart';
import 'package:annotations_shared/domain/services/native_auth_service.dart';
import 'package:annotations_shared/domain/services/note_sync_service.dart';
import 'package:annotations_shared/domain/services/preferences.dart';
import 'package:annotations_shared/presentation/frontend/components/scope.dart';
import 'package:annotations_shared/presentation/frontend/widgets/workspace/note_editor_page.dart';
import 'package:annotations_shared/presentation/frontend/widgets/paper/paper_screen.dart';
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

  @override
  String get userId => _session?.verifiedUserId ?? '';

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
  _StubHttpResponse(this.body);

  final List<int> body;
  @override
  int get statusCode => 200;
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

class _QuizReturnFixture {
  _QuizReturnFixture({
    required this.store,
    required this.root,
    required this.account,
    required this.apiClient,
    required this.accountClient,
    required this.accountRequestPaths,
    required this.workspace,
    required this.workspaceStore,
    required this.preferences,
    required this.studyReads,
    required this.releaseReturnStudy,
    required this.overrides,
    required this.launchCalls,
    this.exportTaskStarted,
    this.releaseExportTask,
    required this.exportLoadStarted,
    required this.releaseExportLoad,
  });

  final SqliteNoteStore store;
  final Directory root;
  final SwitchableInstalledAccount account;
  final MockClient apiClient;
  final MockClient accountClient;
  final List<String> accountRequestPaths;
  final LocalWorkspace workspace;
  final _ExportLoadGateStore workspaceStore;
  final Preferences preferences;
  final List<int> studyReads;
  final Completer<http.Response> releaseReturnStudy;
  final _TestHttpOverrides overrides;
  final List<String> launchCalls;
  final Completer<void>? exportTaskStarted;
  final Completer<http.Response>? releaseExportTask;
  final Completer<void> exportLoadStarted;
  final Completer<LocalNote?> releaseExportLoad;
}

final class _ExportLoadGateStore implements LocalNoteStore {
  _ExportLoadGateStore(this.delegate, this.started, this.release);

  final LocalNoteStore delegate;
  final Completer<void> started;
  final Completer<LocalNote?> release;
  bool _gateNextLoad = false;

  void gateNextLoad() => _gateNextLoad = true;

  @override
  Future<LocalNote?> load(String id) {
    if (!_gateNextLoad) return delegate.load(id);
    _gateNextLoad = false;
    if (!started.isCompleted) started.complete();
    return release.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<_QuizReturnFixture> _makeQuizReturnFixture(
  WidgetTester tester, {
  String? quizId = 'quiz-ready',
  bool gateReturnStudy = false,
  bool existingCard = false,
  bool failReturnStudy = false,
  bool launchAccepted = true,
  bool includeExportTask = false,
  bool gateExportTask = false,
}) async {
  SharedPreferences.setMockInitialValues({});
  late Directory root;
  late SqliteNoteStore store;
  await tester.runAsync(() async {
    root = await Directory.systemTemp.createTemp('prepared_return_');
    store = await SqliteNoteStore.open(root.path);
  });
  addTearDown(() async {
    await store.close();
    await root.delete(recursive: true);
  });

  final schema = DocumentSchema('note-original', 1);
  final items = <Map<String, Object?>>[
    {
      'id': 'text-existing',
      'kind': 'text',
      'x': 0,
      'y': 0,
      'width': 304,
      'height': 40,
      'spans': [
        {'text': 'Saved note text'},
      ],
    },
    if (existingCard)
      {
        'id': 'quiz-card-existing',
        'kind': 'quiz_card',
        'x': 16,
        'y': 80,
        'width': 320,
        'height': 120,
        'study_id': 'study-existing',
        'quiz_id': 'quiz-old',
      },
    if (includeExportTask)
      {
        'id': 'export-task-card',
        'kind': 'task_card',
        'task_id': 'task-export-pending',
        'x': 16,
        'y': 220,
        'width': 320,
        'height': 90,
      },
  ];
  final document = NoteDocument.fromJson({
    'page': {
      'width': 1000,
      'background': {'kind': 'blank'},
    },
    'items': items,
  }, schema: schema);
  await tester.runAsync(
    () => store.save(
      LocalNoteDraft(
        id: 'note-return',
        schema: schema,
        document: document,
        title: 'Local note',
        accountId: 'account-a',
      ),
    ),
  );
  await tester.runAsync(
    () => store.setSync(
      'note-return',
      state: LocalSyncState.synced,
      accountId: 'account-a',
      serverNoteId: 'server-note-a',
      serverRevision: 1,
      serverOriginalRevisionId: 'original-revision-1',
    ),
  );
  await tester.runAsync(
    () => store.savePreparedStudyReference(
      'note-return',
      accountId: 'account-a',
      serverNoteId: 'server-note-a',
      serverRevision: 1,
      studyId: 'study-existing',
    ),
  );

  final exportTaskStarted = Completer<void>();
  final releaseExportTask = Completer<http.Response>();
  final exportLoadStarted = Completer<void>();
  final releaseExportLoad = Completer<LocalNote?>();
  final accountRequestPaths = <String>[];
  final accountClient = MockClient((request) async {
    accountRequestPaths.add(request.url.path);
    if (gateExportTask &&
        request.method == 'GET' &&
        request.url.path.endsWith('/me/tasks/task-export-pending')) {
      if (!exportTaskStarted.isCompleted) exportTaskStarted.complete();
      return releaseExportTask.future;
    }
    return http.Response('{}', 200);
  });
  addTearDown(accountClient.close);
  final account = SwitchableInstalledAccount(
    const NativeSession(
      sessionId: 'session-a',
      csrfToken: 'csrf-a',
      verifiedUserId: 'account-a',
    ),
    accountClient,
  );
  final studyReads = <int>[];
  final releaseReturnStudy = Completer<http.Response>();
  final apiClient = MockClient((request) async {
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
              'document': document.toJson(),
            },
          ],
        }),
        200,
      );
    }
    if (request.method == 'GET' &&
        request.url.path == '/apps/certifications/v1/studies/study-existing') {
      studyReads.add(studyReads.length + 1);
      if (studyReads.length == 2 && failReturnStudy) {
        return http.Response('{}', 503);
      }
      final response = http.Response(
        jsonEncode({
          'study': {
            'id': 'study-existing',
            'title': 'Study',
            'status': 'ready',
            'quiz_id': quizId,
          },
          'sources': [],
          'quota': {'used_bytes': 0, 'max_bytes': 100},
          'config': {'language': 'en', 'count': 10},
        }),
        200,
      );
      if (studyReads.length == 2 && gateReturnStudy) {
        return releaseReturnStudy.future;
      }
      return response;
    }
    return http.Response('{}', 404);
  });
  addTearDown(apiClient.close);
  final workspaceStore = _ExportLoadGateStore(
    store,
    exportLoadStarted,
    releaseExportLoad,
  );
  final workspace = LocalWorkspace(
    store: workspaceStore,
    catalog: ProjectTagCatalog(),
    profile: PlatformProfile.fullWriter,
  );
  final preferences = Preferences();
  addTearDown(preferences.dispose);
  final overrides = _TestHttpOverrides((method, uri, body) async {
    expect(method, 'POST');
    expect(uri.path, '/apps/api/v1/exchange');
    final action =
        (jsonDecode(utf8.decode(body)) as Map<String, dynamic>)['action'];
    if (action == 'cancel_browser_handoff') {
      return _StubHttpResponse(utf8.encode('{}'));
    }
    expect(action, 'create_browser_handoff');
    return _StubHttpResponse(
      utf8.encode(
        jsonEncode({
          'data': {
            'launch_url':
                'https://certifications.asodya.com/continue?handoff_id=handoff-return-1',
            'expires_at': DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600,
          },
        }),
      ),
    );
  });
  final launchCalls = <String>[];
  const launcherChannel = MethodChannel('plugins.flutter.io/url_launcher');
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    launcherChannel,
    (call) async {
      launchCalls.add(call.method);
      return launchAccepted;
    },
  );
  addTearDown(
    () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      launcherChannel,
      null,
    ),
  );
  tester.platformDispatcher.accessibilityFeaturesTestValue =
      const FakeAccessibilityFeatures(disableAnimations: true);
  addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(1200, 900);
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    MaterialApp(
      home: const NoteEditorPage(noteId: 'note-return'),
      builder: (_, child) => AppScope(
        preferences: preferences,
        service: AnnotationsService(
          api: ApiAdapter(
            base: 'https://api.asodya.com/apps/annotations/v1',
            client: apiClient,
          ),
        ),
        workspace: workspace,
        installed: account,
        child: child!,
      ),
    ),
  );
  await pumpEditorFrames(tester);

  return _QuizReturnFixture(
    store: store,
    root: root,
    account: account,
    apiClient: apiClient,
    accountClient: accountClient,
    accountRequestPaths: accountRequestPaths,
    workspace: workspace,
    workspaceStore: workspaceStore,
    preferences: preferences,
    studyReads: studyReads,
    releaseReturnStudy: releaseReturnStudy,
    overrides: overrides,
    launchCalls: launchCalls,
    exportTaskStarted: gateExportTask ? exportTaskStarted : null,
    releaseExportTask: gateExportTask ? releaseExportTask : null,
    exportLoadStarted: exportLoadStarted,
    releaseExportLoad: releaseExportLoad,
  );
}

void main() {
  setUpAll(loadAppFonts);

  testWidgets('one app return reads the saved quiz once and adds one card', (
    tester,
  ) async {
    final fixture = await _makeQuizReturnFixture(tester);
    await HttpOverrides.runZoned(() async {
      await tester.tap(find.byKey(const Key('editor-prepare-quiz')));
      await tester.pump();
      await pumpEditorFrames(tester);
      expect(fixture.launchCalls, isNotEmpty);
      expect(fixture.studyReads.length, 1);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      await pumpEditorFrames(tester);
      expect(fixture.studyReads.length, 2, reason: 'one return GET must run');
      final handler = tester
          .widget<PaperScreen>(find.byType(PaperScreen))
          .handler;
      final cards = handler.document.toJson()['items'] as List;
      final quizCards = cards.where(
        (item) => item is Map && item['kind'] == 'quiz_card',
      );
      expect(quizCards, hasLength(1));
      expect(fixture.studyReads.length, 2);
      await tester.runAsync(() => handler.autosave.flush());

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      await pumpEditorFrames(tester);
      expect(fixture.studyReads.length, 2);
      expect(
        (handler.document.toJson()['items'] as List).where(
          (item) => item is Map && item['kind'] == 'quiz_card',
        ),
        hasLength(1),
      );
    }, createHttpClient: fixture.overrides.createHttpClient);
  });

  testWidgets(
    'account change while export loads the saved note prevents dialog admission',
    (tester) async {
      final fixture = await _makeQuizReturnFixture(tester);
      await tester.runAsync(
        () => fixture.account.auth.writeSession(
          const NativeSession(
            sessionId: 'session-a',
            csrfToken: 'csrf-a',
            verifiedUserId: 'account-a',
          ),
        ),
      );

      await HttpOverrides.runZoned(() async {
        fixture.workspaceStore.gateNextLoad();
        await tester.tap(find.byKey(const Key('editor-export')));
        await tester.pump();
        await tester.runAsync(
          () => fixture.exportLoadStarted.future.timeout(
            const Duration(seconds: 5),
            onTimeout: () =>
                throw TimeoutException('export note load did not start'),
          ),
        );
        expect(find.byKey(const Key('export-dialog')), findsNothing);

        fixture.account.switchTo(
          const NativeSession(
            sessionId: 'session-b',
            csrfToken: 'csrf-b',
            verifiedUserId: 'account-b',
          ),
        );
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await pumpEditorFrames(tester);

        final oldAccountNote = await tester.runAsync(
          () => fixture.store.load('note-return'),
        );
        fixture.releaseExportLoad.complete(oldAccountNote);
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await pumpEditorFrames(tester);

        final dialogAdmitted = find
            .byKey(const Key('export-dialog'))
            .evaluate()
            .isNotEmpty;
        final ownerCardPaths = fixture.accountRequestPaths.where(
          (path) =>
              path.contains('/me/tasks/') || path.contains('/me/quizzes/'),
        );
        await tester.pumpWidget(const SizedBox.shrink());

        expect(dialogAdmitted, isFalse);
        expect(ownerCardPaths, isEmpty);
      }, createHttpClient: fixture.overrides.createHttpClient);
    },
  );

  testWidgets(
    'account change invalidates an open export with a task lookup pending',
    (tester) async {
      final fixture = await _makeQuizReturnFixture(
        tester,
        includeExportTask: true,
        gateExportTask: true,
      );
      const sessionA = NativeSession(
        sessionId: 'session-a',
        csrfToken: 'csrf-a',
        verifiedUserId: 'account-a',
      );
      await tester.runAsync(() => fixture.account.auth.writeSession(sessionA));

      await HttpOverrides.runZoned(() async {
        await tester.tap(find.byKey(const Key('editor-export')));
        await tester.pump();
        await tester.runAsync(
          () => fixture.exportTaskStarted!.future.timeout(
            const Duration(seconds: 5),
            onTimeout: () =>
                throw TimeoutException('export task lookup did not start'),
          ),
        );
        expect(find.byKey(const Key('export-preview')), findsNothing);

        fixture.account.switchTo(
          const NativeSession(
            sessionId: 'session-b',
            csrfToken: 'csrf-b',
            verifiedUserId: 'account-b',
          ),
        );
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await pumpEditorFrames(tester);
        expect(find.byKey(const Key('export-save')), findsNothing);

        fixture.releaseExportTask!.complete(
          http.Response(
            jsonEncode({
              'task_id': 'task-export-pending',
              'title': 'OLD_ACCOUNT_TASK_SENTINEL',
              'status': 'open',
            }),
            200,
          ),
        );
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await pumpEditorFrames(tester);
        expect(find.text('OLD_ACCOUNT_TASK_SENTINEL'), findsNothing);
        expect(find.byKey(const Key('export-save')), findsNothing);
        await tester.pumpWidget(const SizedBox.shrink());
      }, createHttpClient: fixture.overrides.createHttpClient);
    },
  );

  testWidgets('no quiz card is added until the study has a saved quiz id', (
    tester,
  ) async {
    final fixture = await _makeQuizReturnFixture(tester, quizId: null);
    await HttpOverrides.runZoned(() async {
      await tester.tap(find.byKey(const Key('editor-prepare-quiz')));
      await tester.pump();
      await pumpEditorFrames(tester);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      await pumpEditorFrames(tester);

      final handler = tester
          .widget<PaperScreen>(find.byType(PaperScreen))
          .handler;
      expect(
        (handler.document.toJson()['items'] as List).where(
          (item) => item is Map && item['kind'] == 'quiz_card',
        ),
        isEmpty,
      );
      expect(fixture.studyReads.length, 2);
    }, createHttpClient: fixture.overrides.createHttpClient);
  });

  testWidgets('a failed return status read leaves the note unchanged', (
    tester,
  ) async {
    final fixture = await _makeQuizReturnFixture(tester, failReturnStudy: true);
    await HttpOverrides.runZoned(() async {
      await tester.tap(find.byKey(const Key('editor-prepare-quiz')));
      await tester.pump();
      await pumpEditorFrames(tester);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      await pumpEditorFrames(tester);

      final handler = tester
          .widget<PaperScreen>(find.byType(PaperScreen))
          .handler;
      expect(
        (handler.document.toJson()['items'] as List).where(
          (item) => item is Map && item['kind'] == 'quiz_card',
        ),
        isEmpty,
      );
      expect(fixture.studyReads.length, 2);
    }, createHttpClient: fixture.overrides.createHttpClient);
  });

  testWidgets('a refused browser launch does not arm a return read', (
    tester,
  ) async {
    final fixture = await _makeQuizReturnFixture(tester, launchAccepted: false);
    await HttpOverrides.runZoned(() async {
      await tester.tap(find.byKey(const Key('editor-prepare-quiz')));
      await tester.pump();
      await pumpEditorFrames(tester);
      expect(fixture.launchCalls, isNotEmpty);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      await pumpEditorFrames(tester);
      expect(fixture.studyReads.length, 1);
    }, createHttpClient: fixture.overrides.createHttpClient);
  });

  testWidgets('return updates the matching quiz card without moving it', (
    tester,
  ) async {
    final fixture = await _makeQuizReturnFixture(tester, existingCard: true);
    await HttpOverrides.runZoned(() async {
      await tester.tap(find.byKey(const Key('editor-prepare-quiz')));
      await tester.pump();
      await pumpEditorFrames(tester);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      await pumpEditorFrames(tester);

      final handler = tester
          .widget<PaperScreen>(find.byType(PaperScreen))
          .handler;
      expect(fixture.studyReads.length, 2, reason: 'one return GET must run');
      final cards = (handler.document.toJson()['items'] as List)
          .whereType<Map>()
          .where((item) => item['kind'] == 'quiz_card')
          .toList();
      expect(cards, hasLength(1));
      expect(cards.single['id'], 'quiz-card-existing');
      expect(cards.single['x'], 16);
      expect(cards.single['y'], 80);
      expect(cards.single['study_id'], 'study-existing');
      expect(cards.single['quiz_id'], 'quiz-ready');
    }, createHttpClient: fixture.overrides.createHttpClient);
  });

  testWidgets('late return status cannot edit after the account changes', (
    tester,
  ) async {
    final fixture = await _makeQuizReturnFixture(tester, gateReturnStudy: true);
    await HttpOverrides.runZoned(() async {
      await tester.tap(find.byKey(const Key('editor-prepare-quiz')));
      await tester.pump();
      await pumpEditorFrames(tester);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      for (
        var frame = 0;
        frame < 12 && fixture.studyReads.length < 2;
        frame++
      ) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(fixture.studyReads.length, 2);

      fixture.account.switchTo(
        const NativeSession(
          sessionId: 'session-b',
          csrfToken: 'csrf-b',
          verifiedUserId: 'account-b',
        ),
      );
      await pumpEditorFrames(tester);
      fixture.releaseReturnStudy.complete(
        http.Response(
          jsonEncode({
            'study': {
              'id': 'study-existing',
              'title': 'Study',
              'status': 'ready',
              'quiz_id': 'quiz-ready',
            },
            'sources': [],
            'quota': {'used_bytes': 0, 'max_bytes': 100},
            'config': {'language': 'en', 'count': 10},
          }),
          200,
        ),
      );
      await pumpEditorFrames(tester);
      final saved = await tester.runAsync(
        () => fixture.store.load('note-return'),
      );
      expect(saved!.document.toJson()['items'], hasLength(1));
      expect(fixture.account.localOwnerId, 'account-b');
    }, createHttpClient: fixture.overrides.createHttpClient);
  });

  testWidgets(
    'late return status is discarded after the note revision changes',
    (tester) async {
      final fixture = await _makeQuizReturnFixture(
        tester,
        gateReturnStudy: true,
      );
      await HttpOverrides.runZoned(() async {
        await tester.tap(find.byKey(const Key('editor-prepare-quiz')));
        await tester.pump();
        await pumpEditorFrames(tester);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pump();
        for (
          var frame = 0;
          frame < 12 && fixture.studyReads.length < 2;
          frame++
        ) {
          await tester.pump(const Duration(milliseconds: 50));
        }
        expect(fixture.studyReads.length, 2);

        final before = await tester.runAsync(
          () => fixture.store.load('note-return'),
        );
        await tester.runAsync(
          () => fixture.store.save(
            LocalNoteDraft(
              id: before!.id,
              schema: before.schema,
              document: before.document,
              title: 'Changed while away',
              accountId: before.accountId,
            ),
          ),
        );
        fixture.releaseReturnStudy.complete(
          http.Response(
            jsonEncode({
              'study': {
                'id': 'study-existing',
                'title': 'Study',
                'status': 'ready',
                'quiz_id': 'quiz-ready',
              },
              'sources': [],
              'quota': {'used_bytes': 0, 'max_bytes': 100},
              'config': {'language': 'en', 'count': 10},
            }),
            200,
          ),
        );
        await pumpEditorFrames(tester);
        final saved = await tester.runAsync(
          () => fixture.store.load('note-return'),
        );
        expect(saved!.title, 'Changed while away');
        expect(saved.document.toJson()['items'], hasLength(1));
      }, createHttpClient: fixture.overrides.createHttpClient);
    },
  );

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
