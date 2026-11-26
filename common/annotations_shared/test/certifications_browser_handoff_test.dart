import 'dart:convert';

import 'package:annotations_shared/domain/services/certifications_browser_handoff.dart';
import 'package:annotations_shared/domain/services/native_auth_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:http/http.dart' as http;

void main() {
  const session = NativeSession(
    sessionId: 'sid-fixture',
    csrfToken: 'csrf-fixture',
  );

  test(
    'creates the accepted opaque Certifications browser continuation',
    () async {
      http.Request? seen;
      final service = CertificationsBrowserHandoffService(
        gatewayBaseUrl: 'https://gateway.test',
        client: MockClient((request) async {
          seen = request;
          return http.Response(
            jsonEncode({
              'message': 'Continuation created',
              'data': {
                'launch_url':
                    'https://auth.test/continue?handoff_id=Abc_012-xy',
                'expires_at': 1_800_000_000,
              },
            }),
            200,
          );
        }),
      );

      final continuation = await service.create(
        session: session,
        studyId: 'prepared-study-7',
      );

      expect(seen!.url.path, '/apps/api/v1/exchange');
      expect(seen!.method, 'POST');
      expect(seen!.headers['cookie'], 'sid=sid-fixture; csrf=csrf-fixture');
      expect(seen!.headers['x-csrf-token'], 'csrf-fixture');
      expect(jsonDecode(seen!.body), {
        'action': 'create_browser_handoff',
        'target_app': 'certifications',
        'study_id': 'prepared-study-7',
      });
      expect(
        continuation.launchUri.toString(),
        'https://auth.test/continue?handoff_id=Abc_012-xy',
      );
      expect(continuation.handoffId, 'Abc_012-xy');
      expect(
        continuation.expiresAt,
        DateTime.fromMillisecondsSinceEpoch(1_800_000_000_000, isUtc: true),
      );
    },
  );

  test(
    'cancels only the named opaque continuation using the session',
    () async {
      late Map<String, dynamic> body;
      final service = CertificationsBrowserHandoffService(
        gatewayBaseUrl: 'https://gateway.test',
        client: MockClient((request) async {
          body = jsonDecode(request.body) as Map<String, dynamic>;
          expect(request.headers['x-csrf-token'], 'csrf-fixture');
          return http.Response(
            jsonEncode({'message': 'Continuation cancelled', 'data': null}),
            200,
          );
        }),
      );

      await service.cancel(session: session, handoffId: 'Abc_012-xy');

      expect(body, {
        'action': 'cancel_browser_handoff',
        'handoff_id': 'Abc_012-xy',
      });
    },
  );

  test(
    'surfaces gateway machine error code without dropping the session',
    () async {
      final service = CertificationsBrowserHandoffService(
        gatewayBaseUrl: 'https://gateway.test',
        client: MockClient(
          (_) async => http.Response(
            jsonEncode({
              'message': 'A valid installed-app session is required.',
              'data': {'code': 'BROWSER_HANDOFF_AUTH_REQUIRED'},
            }),
            401,
          ),
        ),
      );

      await expectLater(
        service.create(session: session, studyId: 'prepared-study-7'),
        throwsA(
          isA<CertificationsHandoffException>()
              .having((error) => error.statusCode, 'status', 401)
              .having(
                (error) => error.code,
                'code',
                'BROWSER_HANDOFF_AUTH_REQUIRED',
              ),
        ),
      );
    },
  );

  test('rejects launch URLs with content or extra query parameters', () async {
    final service = CertificationsBrowserHandoffService(
      gatewayBaseUrl: 'https://gateway.test',
      client: MockClient(
        (_) async => http.Response(
          jsonEncode({
            'message': 'Continuation created',
            'data': {
              'launch_url':
                  'https://auth.test/continue?handoff_id=Abc&study_id=private',
              'expires_at': 1_800_000_000,
            },
          }),
          200,
        ),
      ),
    );

    await expectLater(
      service.create(session: session, studyId: 'prepared-study-7'),
      throwsA(isA<CertificationsHandoffException>()),
    );
  });
}
