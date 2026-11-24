import 'dart:convert';
import 'dart:async';
import 'dart:io';

import 'package:annotations_shared/app.dart';
import 'package:annotations_shared/core/platform_profile.dart';
import 'package:annotations_shared/core/strings.dart';
import 'package:annotations_shared/dal/local/sqlite_note_store.dart';
import 'package:annotations_shared/dal/remote/aes_cbc.dart';
import 'package:annotations_shared/dal/remote/fernet_token.dart';
import 'package:annotations_shared/domain/services/installed_account.dart';
import 'package:annotations_shared/domain/services/local_workspace.dart';
import 'package:annotations_shared/domain/services/native_auth_service.dart';
import 'package:annotations_shared/domain/services/note_sync_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pointycastle/export.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'design_goldens_test.dart' show loadAppFonts;
import 'fixtures.dart';

/// annotations#38 stage 3: the installed sign-in with the native handoff.

const key = 'AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=';
const gateway = 'https://gateway.test';

/// A fake gateway like api_for_apps: the exchange answers
/// HANDOFF_NOT_FINISHED until the browser step is done, then the session;
/// user info needs the session cookie; log-out needs the CSRF header.
class FakeGateway {
  bool browserDone = false, alive = false;
  bool offline = false;
  String userId = 'user-1';
  final calls = <String>[];
  final opened = <Uri>[];
  final storage = InMemorySecureSessionStorage();

  late final client = MockClient((r) async {
    calls.add('${r.method} ${r.url.path}');
    switch ((r.method, r.url.path)) {
      case ('POST', '/apps/api/v1/exchange'):
        if (!browserDone) {
          return json({
            'data': {'code': 'HANDOFF_NOT_FINISHED'},
          }, 409);
        }
        alive = true;
        return json({
          'data': {
            'session_id': 'sid-1',
            'csrf_token': 'csrf-1',
            'location': {'city': 'Bangkok', 'country': 'Thailand'},
          },
        });
      case ('GET', '/user/info/v1/'):
        if (offline) throw const SocketException('offline');
        final ok = alive && (r.headers['cookie'] ?? '').contains('sid=sid-1');
        return ok
            ? json({
                'data': {'id': userId, 'email': 'ana@example.com'},
              })
            : json({'detail': 'Missing Authentications Parameters...'}, 403);
      case ('POST', '/user/sync/v1/log-out'):
        if (r.headers['x-csrf-token'] != 'csrf-1') {
          return json({'detail': 'Missing Authentications Parameters...'}, 403);
        }
        alive = false;
        return json({'message': 'Logged out successfully.'});
    }
    return json({'detail': 'Not Found'}, 404);
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
    open: (uri) async => opened.add(uri),
    aes: aesCbcEncrypt,
    appContextKey: key,
    authBase: 'https://auth.test',
  );
}

class DelayedVerifiedStorage implements SecureSessionStorage {
  NativeSession? session;
  final enteredVerifiedWrite = Completer<void>();
  final releaseVerifiedWrite = Completer<void>();

  @override
  Future<NativeSession?> readSession() async => session;

  @override
  Future<void> writeSession(NativeSession value) async {
    if (value.sessionId == 'sid-a' && value.verifiedUserId != null) {
      enteredVerifiedWrite.complete();
      await releaseVerifiedWrite.future;
    }
    session = value;
  }

  @override
  Future<void> deleteSession() async {
    session = null;
  }
}

/// Opens a Fernet token with the real cipher (the inverse of the app).
Map<String, dynamic> openToken(String token) {
  final raw = base64Url.decode(token);
  final k = base64Url.decode(key);
  final cipher =
      PaddedBlockCipherImpl(PKCS7Padding(), CBCBlockCipher(AESEngine()))..init(
        false,
        PaddedBlockCipherParameters<CipherParameters, CipherParameters>(
          ParametersWithIV<KeyParameter>(
            KeyParameter(Uint8List.fromList(k.sublist(16))),
            Uint8List.fromList(raw.sublist(9, 25)),
          ),
          null,
        ),
      );
  final plain = cipher.process(
    Uint8List.fromList(raw.sublist(25, raw.length - 32)),
  );
  return jsonDecode(utf8.decode(plain)) as Map<String, dynamic>;
}

late Directory root;
late SqliteNoteStore store;

Future<void> openApp(
  WidgetTester tester,
  FakeGateway g, {
  String? at,
  String locale = 'en',
}) async {
  tester.platformDispatcher.accessibilityFeaturesTestValue =
      const FakeAccessibilityFeatures(disableAnimations: true);
  addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
  SharedPreferences.setMockInitialValues({'annotations.locale': locale});
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
        profile: PlatformProfile.fullWriter,
      ),
      installed: g.account,
      initialLocation: at,
    ),
  );
  await settle(tester);
}

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
  }
}

String t(String k) => translate(k, 'en');

void main() {
  setUpAll(loadAppFonts);
  setUp(() async {
    root = await Directory.systemTemp.createTemp('installed_');
    store = await SqliteNoteStore.open(root.path);
  });
  tearDown(() async {
    await store.close();
    await root.delete(recursive: true);
  });

  test('the Fernet token matches the reference library byte for byte', () async {
    // Made with Python cryptography: Fernet(key)._encrypt_from_parts(
    // b'{"a":1}', 1794996000, bytes(16)).
    const reference =
        'gAAAAABq_XcgAAAAAAAAAAAAAAAAAAAAABlIZJJcRJI4D9Om5EpJL3ekMyMxfIsvU4Tn6M1AeO1eWTtz4Ut4yXAWQ760JzHwdQ==';
    final token = await fernetEncrypt(
      key,
      '{"a":1}',
      aes: aesCbcEncrypt,
      now: DateTime.fromMillisecondsSinceEpoch(1794996000 * 1000),
      iv: Uint8List(16),
    );
    expect(token, reference);
  });

  test(
    'verified owner survives outage, but a replacement session has no owner',
    () async {
      final g = FakeGateway();
      g.alive = true;
      await g.storage.writeSession(
        const NativeSession(sessionId: 'sid-1', csrfToken: 'csrf-1'),
      );
      await g.account.check();
      expect(g.account.signedIn, isTrue);
      expect(g.account.localOwnerId, 'user-1');

      g.offline = true;
      final restarted = InstalledAccount(
        auth: NativeAuthService(
          client: g.client,
          storage: g.storage,
          gatewayBaseUrl: gateway,
        ),
        client: g.client,
        platform: 'linux',
        open: (_) async {},
        aes: aesCbcEncrypt,
        appContextKey: key,
      );
      await restarted.check();
      expect(restarted.signedIn, isFalse);
      expect(restarted.localOwnerId, 'user-1');
      expect(g.calls.where((path) => path.contains('/me/')), isEmpty);

      await restarted.logOut();
      expect(restarted.localOwnerId, isNull);
      expect(await g.storage.readSession(), isNull);

      await g.storage.writeSession(
        const NativeSession(sessionId: 'sid-2', csrfToken: 'csrf-2'),
      );
      final replacement = InstalledAccount(
        auth: NativeAuthService(
          client: g.client,
          storage: g.storage,
          gatewayBaseUrl: gateway,
        ),
        client: g.client,
        platform: 'linux',
        open: (_) async {},
        aes: aesCbcEncrypt,
        appContextKey: key,
      );
      await replacement.check();
      expect(replacement.localOwnerId, isNull);
    },
  );

  test(
    'late account A response cannot bind its owner to replacement B',
    () async {
      final storage = InMemorySecureSessionStorage();
      final responseA = Completer<http.Response>();
      final responseB = Completer<http.Response>();
      final client = MockClient((request) async {
        final cookie = request.headers['cookie'] ?? '';
        if (cookie.contains('sid-a')) return responseA.future;
        if (cookie.contains('sid-b')) return responseB.future;
        return http.Response('unauthorized', 401);
      });
      final auth = NativeAuthService(
        client: client,
        storage: storage,
        gatewayBaseUrl: gateway,
      );
      final account = InstalledAccount(
        auth: auth,
        client: client,
        platform: 'linux',
        open: (_) async {},
        aes: aesCbcEncrypt,
        appContextKey: key,
      );
      const a = NativeSession(sessionId: 'sid-a', csrfToken: 'csrf-a');
      const b = NativeSession(sessionId: 'sid-b', csrfToken: 'csrf-b');
      await auth.writeSession(a);
      final checkA = account.check();
      await Future<void>.delayed(Duration.zero);
      await auth.writeSession(b);
      final checkB = account.check();
      await Future<void>.delayed(Duration.zero);
      responseB.complete(
        http.Response('{"data":{"id":"owner-b","email":"b@test"}}', 200),
      );
      await checkB;
      responseA.complete(
        http.Response('{"data":{"id":"owner-a","email":"a@test"}}', 200),
      );
      await checkA;
      expect(account.localOwnerId, 'owner-b');
      expect(account.userId, 'owner-b');
      expect((await storage.readSession())?.sessionId, 'sid-b');
      expect((await storage.readSession())?.verifiedUserId, 'owner-b');
    },
  );

  test(
    'late unauthorized response and logout cannot clear replacement session',
    () async {
      final storage = InMemorySecureSessionStorage();
      final responseA = Completer<http.Response>();
      final responseB = Completer<http.Response>();
      final responseLogout = Completer<http.Response>();
      var bCalls = 0;
      final client = MockClient((request) async {
        if (request.method != 'GET') return http.Response('ok', 200);
        final cookie = request.headers['cookie'] ?? '';
        if (cookie.contains('sid-a')) return responseA.future;
        if (cookie.contains('sid-b')) {
          bCalls++;
          return bCalls == 1 ? responseB.future : responseLogout.future;
        }
        return http.Response('unauthorized', 401);
      });
      final auth = NativeAuthService(
        client: client,
        storage: storage,
        gatewayBaseUrl: gateway,
      );
      final account = InstalledAccount(
        auth: auth,
        client: client,
        platform: 'linux',
        open: (_) async {},
        aes: aesCbcEncrypt,
        appContextKey: key,
      );
      const a = NativeSession(sessionId: 'sid-a', csrfToken: 'csrf-a');
      const b = NativeSession(sessionId: 'sid-b', csrfToken: 'csrf-b');
      await auth.writeSession(a);
      final checkA = account.check();
      await Future<void>.delayed(Duration.zero);
      await auth.writeSession(b);
      final checkB = account.check();
      await Future<void>.delayed(Duration.zero);
      responseB.complete(
        http.Response('{"data":{"id":"owner-b","email":"b@test"}}', 200),
      );
      await checkB;
      responseA.complete(http.Response('unauthorized', 401));
      await checkA;
      expect(account.localOwnerId, 'owner-b');
      expect((await storage.readSession())?.sessionId, 'sid-b');

      final pending = account.check();
      await Future<void>.delayed(Duration.zero);
      await account.logOut();
      responseLogout.completeError(const SocketException('late response'));
      await pending;
      expect(account.localOwnerId, isNull);
      expect(await storage.readSession(), isNull);
    },
  );

  test(
    'secure-store write finishing late cannot replace a newer session',
    () async {
      final storage = DelayedVerifiedStorage();
      final responseA = Completer<http.Response>();
      final responseB = Completer<http.Response>();
      final client = MockClient((request) async {
        final cookie = request.headers['cookie'] ?? '';
        if (cookie.contains('sid-a')) return responseA.future;
        if (cookie.contains('sid-b')) return responseB.future;
        return http.Response('unauthorized', 401);
      });
      final auth = NativeAuthService(
        client: client,
        storage: storage,
        gatewayBaseUrl: gateway,
      );
      final account = InstalledAccount(
        auth: auth,
        client: client,
        platform: 'linux',
        open: (_) async {},
        aes: aesCbcEncrypt,
        appContextKey: key,
      );
      await auth.writeSession(
        const NativeSession(sessionId: 'sid-a', csrfToken: 'csrf-a'),
      );
      final checkA = account.check();
      await Future<void>.delayed(Duration.zero);
      responseA.complete(
        http.Response('{"data":{"id":"owner-a","email":"a@test"}}', 200),
      );
      await storage.enteredVerifiedWrite.future;

      final replace = auth.writeSession(
        const NativeSession(sessionId: 'sid-b', csrfToken: 'csrf-b'),
      );
      final checkB = account.check();
      storage.releaseVerifiedWrite.complete();
      await replace;
      await Future<void>.delayed(Duration.zero);
      responseB.complete(
        http.Response('{"data":{"id":"owner-b","email":"b@test"}}', 200),
      );
      await Future.wait([checkA, checkB]);
      expect(account.localOwnerId, 'owner-b');
      expect(storage.session?.sessionId, 'sid-b');
      expect(storage.session?.verifiedUserId, 'owner-b');
    },
  );

  testWidgets('signed out: Sign in in the bar, no call without a session', (
    tester,
  ) async {
    final g = FakeGateway();
    await openApp(tester, g);
    expect(find.byKey(const Key('bar-sign-in')), findsOneWidget);
    expect(g.calls, isEmpty);
  });

  testWidgets('the browser login carries the handoff; Finish signs in', (
    tester,
  ) async {
    final g = FakeGateway();
    await openApp(tester, g, at: '/v1/sign-in');
    await tester.tap(find.byKey(const Key('sign-in-start')));
    await settle(tester);
    expect(g.opened, hasLength(1));
    final uri = g.opened.single;
    expect(uri.origin, 'https://auth.test');
    expect(uri.path, '/login');
    final context = openToken(uri.queryParameters['app_context']!);
    final handoff = g.account.auth.pendingHandoff!;
    expect(context['handoff_id'], handoff.handoffId);
    expect(context['challenge'], handoff.challengeBase64Url);
    expect(context['platform'], 'linux');
    expect(context.containsKey('secret'), isFalse, reason: 'never sent');
    // The match code the browser shows too.
    expect(find.text(handoff.matchCode), findsOneWidget);

    // Finish before the browser step: the FINAL message, still waiting.
    await tester.tap(find.byKey(const Key('sign-in-finish')));
    await settle(tester);
    expect(find.byKey(const Key('sign-in-message')), findsOneWidget);
    expect(find.text(handoff.matchCode), findsOneWidget);

    g.browserDone = true;
    await tester.tap(find.byKey(const Key('sign-in-finish')));
    await settle(tester);
    expect(find.byKey(const Key('sign-in-done')), findsOneWidget);
    expect(find.text('ana@example.com'), findsOneWidget);
    expect(find.text('Logged in from Bangkok, Thailand'), findsOneWidget);
    expect(find.byKey(const Key('account-avatar')), findsOneWidget);
    expect(find.byKey(const Key('bar-sign-in')), findsNothing);
    // Finish is a click, never a poll.
    expect(g.calls.where((c) => c.contains('exchange')), hasLength(2));
  });

  testWidgets('a stored but dead session signs out once', (tester) async {
    final g = FakeGateway();
    await g.storage.writeSession(
      const NativeSession(
        sessionId: 'old',
        csrfToken: 'old',
        verifiedUserId: 'stale-owner',
      ),
    );
    await openApp(tester, g);
    expect(find.byKey(const Key('bar-sign-in')), findsOneWidget);
    expect(await g.storage.readSession(), isNull);
    expect(g.account.localOwnerId, isNull);
    expect(g.calls, ['GET /user/info/v1/']);
    expect(g.opened, isEmpty);
  });

  testWidgets('a live session shows the avatar; Log out keeps notes', (
    tester,
  ) async {
    final g = FakeGateway()..alive = true;
    await g.storage.writeSession(
      const NativeSession(sessionId: 'sid-1', csrfToken: 'csrf-1'),
    );
    final id = await LocalWorkspace(
      store: store,
      catalog: ProjectTagCatalog(),
      profile: PlatformProfile.fullWriter,
    ).createNote();
    await openApp(tester, g);
    expect(find.byKey(const Key('account-avatar')), findsOneWidget);
    await tester.tap(find.byKey(const Key('account-avatar')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('account-log-out')));
    await settle(tester);
    expect(g.alive, isFalse, reason: 'the gateway accepted the log-out');
    expect(find.byKey(const Key('bar-sign-in')), findsOneWidget);
    expect(await tester.runAsync(() => store.load(id)), isNotNull);
  });

  test('handoff platform names', () {
    expect(handoffPlatform(TargetPlatform.macOS, fullWriter: true), 'macos');
    expect(handoffPlatform(TargetPlatform.iOS, fullWriter: true), 'ipados');
    expect(handoffPlatform(TargetPlatform.iOS, fullWriter: false), 'ios');
    expect(
      handoffPlatform(TargetPlatform.android, fullWriter: false),
      'android',
    );
    expect(t('finishLogin'), 'Finish');
  });

  testWidgets('without a key the login says it cannot start', (tester) async {
    final g = FakeGateway();
    final account = InstalledAccount(
      auth: g.account.auth,
      client: g.client,
      platform: 'linux',
      open: (uri) async => g.opened.add(uri),
      aes: aesCbcEncrypt,
    );
    await tester.runAsync(account.startLogin);
    expect(account.notice?.kind, LoginNoticeKind.unavailable);
    expect(account.matchCode, isNull);
    expect(g.opened, isEmpty);
  });

  testWidgets('the login messages follow the interface language (TH)', (
    tester,
  ) async {
    String th(String key) => translate(key, 'th');
    final g = FakeGateway();
    await openApp(tester, g, at: '/v1/sign-in', locale: 'th');
    await tester.tap(find.byKey(const Key('sign-in-start')));
    await settle(tester);
    await tester.tap(find.byKey(const Key('sign-in-finish')));
    await settle(tester);
    expect(find.text(th('loginNotFinished')), findsOneWidget);
    expect(find.textContaining('The login is not finished'), findsNothing);
    g.browserDone = true;
    await tester.tap(find.byKey(const Key('sign-in-finish')));
    await settle(tester);
    // The place comes from the FINAL record as it is.
    expect(
      find.text('${th('loginSuccessFrom')} Bangkok, Thailand'),
      findsOneWidget,
    );
    expect(find.textContaining('Logged in'), findsNothing);
  });

  test('every login status has its own text in each language', () {
    for (final lang in ['en', 'pt-BR', 'th']) {
      final seen = <String>{};
      for (final key in [
        'loginUnavailable',
        'loginSuccess',
        'loginNotFinished',
        'loginExpired',
        'loginUsed',
        'loginCancelled',
        'loginRefused',
        'loginInvalid',
        'loginDisabled',
        'loginFailed',
      ]) {
        final text = translate(key, lang);
        expect(text, isNot(key), reason: '$lang $key missing');
        if (lang != 'en') {
          expect(text, isNot(translate(key, 'en')), reason: '$lang $key');
        }
        expect(seen.add(text), isTrue, reason: '$lang $key repeats');
      }
    }
    // Every FINAL status maps to a notice kind.
    for (final status in FinishLoginStatus.values) {
      expect(
        LoginNotice.fromResult(
          FinishLoginResult(status: status, message: ''),
        ).kind.name,
        isNotEmpty,
      );
    }
  });
}
