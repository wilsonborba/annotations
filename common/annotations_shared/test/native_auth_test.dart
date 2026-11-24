import 'dart:convert';

import 'package:annotations_shared/core/logs.dart';
import 'package:annotations_shared/core/tracking.dart';
import 'package:annotations_shared/dal/remote/api_adapter.dart';
import 'package:annotations_shared/domain/services/native_auth_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'match code test vector (secret 0..31 -> challenge Yw3N... -> MMG4)',
    () {
      final storage = InMemorySecureSessionStorage();
      final auth = NativeAuthService(storage: storage);
      final secret = Uint8List.fromList(List<int>.generate(32, (i) => i));
      final handoff = auth.prepareHandoff(secretOverride: secret);

      expect(
        handoff.challengeBase64Url,
        'Yw3NKWbEM2aRElRIu7JbT_QSpJxzLbLIq8G4WBvXEN0',
      );
      expect(handoff.matchCode, 'MMG4');
    },
  );

  test(
    'maps every api_for_apps data.code shape and preserves pendingHandoff on HANDOFF_NOT_FINISHED',
    () async {
      final storage = InMemorySecureSessionStorage();
      var mode = 'HANDOFF_NOT_FINISHED';

      final mock = MockClient((req) async {
        if (req.url.path == '/apps/api/v1/exchange') {
          switch (mode) {
            case 'HANDOFF_NOT_FINISHED':
              return http.Response(
                jsonEncode({
                  'message':
                      'The login is not finished. Finish it in the browser, then click Finish.',
                  'data': {'code': 'HANDOFF_NOT_FINISHED'},
                }),
                409,
              );
            case 'HANDOFF_EXPIRED':
              return http.Response(
                jsonEncode({
                  'message': 'This login expired. Start again.',
                  'data': {'code': 'HANDOFF_EXPIRED'},
                }),
                410,
              );
            case 'HANDOFF_USED':
              return http.Response(
                jsonEncode({
                  'message': 'Start again.',
                  'data': {'code': 'HANDOFF_USED'},
                }),
                409,
              );
            case 'HANDOFF_CANCELLED':
              return http.Response(
                jsonEncode({
                  'message': 'Login cancelled. Start again.',
                  'data': {'code': 'HANDOFF_CANCELLED'},
                }),
                409,
              );
            case 'LOGIN_REFUSED_NETWORK':
              return http.Response(
                jsonEncode({
                  'message':
                      'Login refused. The login came from a different location.',
                  'data': {'code': 'LOGIN_REFUSED_NETWORK'},
                }),
                403,
              );
            case 'INVALID_HANDOFF':
              return http.Response(
                jsonEncode({
                  'message': 'Invalid installed-app login fields.',
                  'data': {'code': 'INVALID_HANDOFF'},
                }),
                400,
              );
            case 'NATIVE_HANDOFF_DISABLED':
              return http.Response(
                jsonEncode({
                  'message': 'Installed-app login is disabled.',
                  'data': {'code': 'NATIVE_HANDOFF_DISABLED'},
                }),
                403,
              );
            case 'OK':
              return http.Response(
                jsonEncode({
                  'message': 'Logged in from Bangkok, Thailand',
                  'data': {
                    'session_id': 'sid_1',
                    'csrf_token': 'csrf_1',
                    'location': {'city': 'Bangkok', 'country': 'Thailand'},
                  },
                }),
                200,
              );
          }
        }
        if (req.url.path == '/user/sync/v1/log-out') {
          throw Exception('offline');
        }
        return http.Response('{}', 404);
      });

      final auth = NativeAuthService(client: mock, storage: storage);

      // HANDOFF_NOT_FINISHED keeps pendingHandoff so user can finish on the next click.
      final h1 = auth.prepareHandoff();
      final notFinished = await auth.finishLogin();
      expect(notFinished.status, FinishLoginStatus.notFinished);
      expect(
        notFinished.message,
        'The login is not finished. Finish it in the browser, then click Finish.',
      );
      expect(auth.pendingHandoff?.handoffId, h1.handoffId);

      // Same handoff succeeds on retry once browser step completes.
      mode = 'OK';
      final ok = await auth.finishLogin();
      expect(ok.status, FinishLoginStatus.success);
      expect(ok.message, 'Logged in from Bangkok, Thailand');
      expect(auth.pendingHandoff, isNull);

      // All terminal gateway codes clear pendingHandoff and map exact section 5 texts.
      final cases = <(String, FinishLoginStatus, String)>[
        (
          'HANDOFF_EXPIRED',
          FinishLoginStatus.expired,
          'This login expired. Start again.',
        ),
        ('HANDOFF_USED', FinishLoginStatus.used, 'Start again.'),
        (
          'HANDOFF_CANCELLED',
          FinishLoginStatus.cancelled,
          'Login cancelled. Start again.',
        ),
        (
          'LOGIN_REFUSED_NETWORK',
          FinishLoginStatus.refused,
          'Login refused. The login came from a different location.',
        ),
        (
          'INVALID_HANDOFF',
          FinishLoginStatus.invalid,
          'Invalid installed-app login fields.',
        ),
        (
          'NATIVE_HANDOFF_DISABLED',
          FinishLoginStatus.disabled,
          'Installed-app login is disabled.',
        ),
      ];
      for (final (code, expectedStatus, expectedMsg) in cases) {
        auth.prepareHandoff();
        mode = code;
        final res = await auth.finishLogin();
        expect(res.status, expectedStatus);
        expect(res.message, expectedMsg);
        expect(auth.pendingHandoff, isNull);
      }

      // Stored in secure storage with cookie + CSRF headers.
      final stored = await storage.readSession();
      expect(stored!.authHeaders(isMutation: true), {
        'cookie': 'sid=sid_1; csrf=csrf_1',
        'x-csrf-token': 'csrf_1',
      });

      // Offline sign-out works immediately with server revocation pending.
      await auth.signOut();
      expect(await storage.readSession(), isNull);
      expect(auth.pendingServerRevocation, isTrue);

      // Session expiry pauses account ops, never local writing.
      auth.markSessionExpired();
      expect(auth.sessionPaused, isTrue);
      expect(auth.canWriteLocal, isTrue);
    },
  );

  test(
    'OsSecureSessionStorage refuses fallback when unavailable and round-trips via channel',
    () async {
      const channel = MethodChannel('com.asodya.annotations/secure_storage');
      final storage = OsSecureSessionStorage();

      // Missing plugin raises SecureStorageUnavailableException (never plain preferences).
      await expectLater(
        storage.writeSession(
          const NativeSession(sessionId: 's1', csrfToken: 'c1'),
        ),
        throwsA(isA<SecureStorageUnavailableException>()),
      );

      final store = <String, dynamic>{};
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            switch (call.method) {
              case 'write':
                final args = Map<String, dynamic>.from(call.arguments as Map);
                store.clear();
                store['session_id'] = '${args['session_id']}';
                store['csrf_token'] = '${args['csrf_token']}';
                if (args['verified_user_id'] != null) {
                  store['verified_user_id'] = args['verified_user_id'];
                }
                return null;
              case 'read':
                return store.isEmpty ? null : Map<String, dynamic>.from(store);
              case 'delete':
                store.clear();
                return null;
            }
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );

      await storage.writeSession(
        const NativeSession(
          sessionId: 'sid_os',
          csrfToken: 'csrf_os',
          verifiedUserId: 'owner_os',
        ),
      );
      final read = await storage.readSession();
      expect(read?.sessionId, 'sid_os');
      expect(read?.csrfToken, 'csrf_os');
      expect(read?.verifiedUserId, 'owner_os');
      store.remove('verified_user_id');
      expect((await storage.readSession())?.verifiedUserId, isNull);
      await storage.deleteSession();
      expect(await storage.readSession(), isNull);
    },
  );

  test(
    'failed ApiAdapter request carrying cookies/tokens is redacted in both logs and telemetry',
    () async {
      final printed = <String>[];
      final prevDebugPrint = debugPrint;
      debugPrint = (String? message, {int? wrapWidth}) {
        if (message != null) printed.add(message);
      };
      addTearDown(() => debugPrint = prevDebugPrint);

      final telemetryBodies = <String>[];
      final tracker = createTracker(
        transport: createTrailTransport(
          client: MockClient((req) async {
            telemetryBodies.add(req.body);
            return http.Response('{}', 200);
          }),
        ),
        autoFlush: false,
      );
      final errors = ClientErrors(tracker, platform: 'linux');

      final failingApi = ApiAdapter(
        client: MockClient(
          (_) async => http.Response(jsonEncode({'error': 'denied'}), 403),
        ),
        base: 'https://api.asodya.com/apps/annotations/v1',
      );
      failingApi.onError = (err, stack, op) {
        errors.report(
          err,
          stack,
          operation: op,
          httpStatus: err is ApiError ? err.status : null,
          sensitive: const ['sid_secret_99', 'csrf_secret_88', 'hid_full_77'],
        );
        logError(
          'auth',
          'Cookie: sid=sid_secret_99; csrf=csrf_secret_88 handoff_id=hid_full_77',
        );
      };

      await expectLater(
        failingApi.request(
          '/me/notes?sid=sid_secret_99&handoff_id=hid_full_77',
          method: 'POST',
        ),
        throwsA(isA<ApiError>()),
      );
      await tracker.flush();

      final allLogs = printed.join('\n');
      expect(allLogs, contains('[REDACTED]'));
      expect(allLogs, isNot(contains('sid_secret_99')));
      expect(allLogs, isNot(contains('csrf_secret_88')));
      expect(allLogs, isNot(contains('hid_full_77')));

      final allTelemetry = telemetryBodies.join('\n');
      expect(allTelemetry, isNot(contains('sid_secret_99')));
      expect(allTelemetry, isNot(contains('csrf_secret_88')));
      expect(allTelemetry, isNot(contains('hid_full_77')));
    },
  );
}
