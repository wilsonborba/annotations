import '../../dal/remote/api_adapter.dart';

/// The owner-safe fields returned by Certifications' quiz summary endpoint.
/// Null values stay null: zero questions is different from an unknown count.
final class QuizSummary {
  const QuizSummary({
    required this.quizId,
    this.activeVersionId,
    this.title,
    this.questionCount,
    this.subject,
  });

  final String quizId;
  final String? activeVersionId;
  final String? title;
  final int? questionCount;
  final String? subject;

  factory QuizSummary.fromJson(Map<String, dynamic> json) {
    final quizId = json['quiz_id'];
    final activeVersionId = json['active_version_id'];
    final title = json['title'];
    final questionCount = json['question_count'];
    final subject = json['subject'];
    if (quizId is! String || quizId.trim().isEmpty) {
      throw const FormatException('Invalid quiz summary identifier.');
    }
    if (activeVersionId != null && activeVersionId is! String) {
      throw const FormatException('Invalid quiz summary version.');
    }
    if (title != null && title is! String) {
      throw const FormatException('Invalid quiz summary title.');
    }
    if (questionCount != null && questionCount is! int) {
      throw const FormatException('Invalid quiz question count.');
    }
    if (subject != null && subject is! String) {
      throw const FormatException('Invalid quiz summary subject.');
    }
    return QuizSummary(
      quizId: quizId,
      activeVersionId: activeVersionId as String?,
      title: title as String?,
      questionCount: questionCount as int?,
      subject: subject as String?,
    );
  }
}

/// Reads the authenticated owner's existing quiz references. The backend
/// enforces owner/admin access; callers supply a session-bound [ApiAdapter].
final class QuizCardService {
  QuizCardService(this.api)
    : _certificationsApi = ApiAdapter(
        client: api.client,
        base: Uri.parse(api.base).origin,
      );

  final ApiAdapter api;
  final ApiAdapter _certificationsApi;

  Future<QuizSummary> readOwnerSummary(String quizId) async {
    final normalizedId = quizId.trim();
    if (normalizedId.isEmpty) {
      throw const FormatException('Invalid quiz reference.');
    }
    final response = await _certificationsApi.request(
      '/apps/certifications/v1/me/quizzes/${Uri.encodeComponent(normalizedId)}/summary',
      method: 'GET',
    );
    final summary = QuizSummary.fromJson(response);
    if (summary.quizId != normalizedId) {
      throw ApiError(502, 'The service returned a different quiz summary.');
    }
    return summary;
  }
}
