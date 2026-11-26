import 'dart:convert';

import 'package:annotations_shared/dal/remote/api_adapter.dart';
import 'package:annotations_shared/domain/services/quiz_card_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test(
    'reads the exact owner-summary route and preserves zero/null fields',
    () async {
      http.Request? seen;
      final api = ApiAdapter(
        base: 'https://certifications.asodya.com/v1',
        client: MockClient((request) async {
          seen = request;
          return http.Response(
            jsonEncode({
              'quiz_id': 'quiz/alpha',
              'active_version_id': 'version-1',
              'title': null,
              'question_count': 0,
              'subject': null,
            }),
            200,
          );
        }),
      );

      final summary = await QuizCardService(api).readOwnerSummary('quiz/alpha');

      expect(seen?.method, 'GET');
      expect(seen?.url.path, '/v1/me/quizzes/quiz%2Falpha/summary');
      expect(summary.quizId, 'quiz/alpha');
      expect(summary.activeVersionId, 'version-1');
      expect(summary.title, isNull);
      expect(summary.questionCount, 0);
      expect(summary.subject, isNull);
    },
  );

  test('rejects mismatched identity and malformed nullable fields', () async {
    final mismatch = QuizCardService(
      ApiAdapter(
        base: 'https://certifications.asodya.com/v1',
        client: MockClient(
          (_) async =>
              http.Response(jsonEncode({'quiz_id': 'other-quiz'}), 200),
        ),
      ),
    );
    await expectLater(
      mismatch.readOwnerSummary('quiz-1'),
      throwsA(isA<ApiError>()),
    );

    expect(
      () => QuizSummary.fromJson({'quiz_id': 'quiz-1', 'question_count': '0'}),
      throwsFormatException,
    );
  });
}
