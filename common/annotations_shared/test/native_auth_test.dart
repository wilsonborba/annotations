import 'dart:convert';
import 'dart:typed_data';

import 'package:annotations_shared/domain/services/native_auth_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('match code test vector (secret 0..31 -> challenge Yw3N... -> MMG4)', () {
    final storage = InMemorySecureSessionStorage();
    final auth = NativeAuthService(storage: storage);
    final secret = Uint8List.fromList(List<int>.generate(32, (i) => i));
    final handoff = auth.prepareHandoff(secretOverride: secret);

    expect(handoff.challengeBase64Url, 'Yw3NKWbEM2aRElRIu7JbT_QSpJxzLbLIq8G4WBvXEN0');
    expect(handoff.matchCode, 'MMG4');
  });

  test('wrong network, expired, finish location formatting, offline sign-out, and log redaction', () async {
    final storage = InMemorySecureSessionStorage();
    var mode = 'wrong_network';
    final mock = MockClient((req) async {
      if (req.url.path == '/apps/api/v1/exchange') {
        if (mode == 'wrong_network') {
          return http.Response(jsonEncode({'status': 'refused'}), 403);
        }
        if (mode == 'expired') {
          return http.Response(jsonEncode({'status': 'expired'}), 410);
        }
        if (mode == 'ok_country_only') {
          return http.Response(
            jsonEncode({
              'message': 'Success',
              'data': {'session_id': 'sid_1', 'csrf_token': 'csrf_1', 'country': 'Thailand'},
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

    auth.prepareHandoff();
    final refused = await auth.finishLogin();
    expect(refused.status, FinishLoginStatus.refused);
    expect(refused.message, 'Login refused. The login came from a different location.');

    auth.prepareHandoff();
    mode = 'expired';
    final exp = await auth.finishLogin();
    expect(exp.status, FinishLoginStatus.expired);
    expect(exp.message, 'This login expired. Start again.');

    auth.prepareHandoff();
    mode = 'ok_country_only';
    final ok = await auth.finishLogin();
    expect(ok.status, FinishLoginStatus.success);
    expect(ok.message, 'Logged in from Thailand');
    expect(NativeAuthService.formatLoggedInMessage(city: 'Bangkok', country: 'Thailand'), 'Logged in from Bangkok, Thailand');
    expect(NativeAuthService.formatLoggedInMessage(), 'Logged in');

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

    // Log redaction strips secrets and session IDs.
    expect(
      NativeAuthService.sanitizeForLog('sid=sid_1 secret=abc handoff_id=xyz'),
      'sid=[REDACTED] secret=[REDACTED] handoff_id=[REDACTED]',
    );
  });
}
