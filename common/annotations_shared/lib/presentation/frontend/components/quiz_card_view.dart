import 'package:flutter/material.dart';

import '../../../domain/services/quiz_card_service.dart';
import 'scope.dart';

/// Owner-only projection of a saved quiz reference. Public notes use a locked
/// projection and never provide a summary loader.
final class QuizCardView extends StatelessWidget {
  const QuizCardView({
    super.key,
    required this.quiz,
    this.loading = false,
    this.restricted = false,
    this.unavailable = false,
    this.onRetry,
    this.onOpen,
  });

  final QuizSummary? quiz;
  final bool loading;
  final bool restricted;
  final bool unavailable;
  final VoidCallback? onRetry;
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final content = loading && quiz == null
        ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
        : restricted || unavailable || quiz == null
        ? _placeholder(context)
        : _summary(context, quiz!);
    return Material(
      color: colors.surface,
      child: Container(
        constraints: const BoxConstraints(minHeight: 112),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          border: Border.all(color: Theme.of(context).dividerColor),
          borderRadius: BorderRadius.circular(8),
        ),
        child: content,
      ),
    );
  }

  Widget _summary(BuildContext context, QuizSummary quiz) {
    final text = Theme.of(context).textTheme;
    final title = quiz.title?.trim();
    final subject = quiz.subject?.trim();
    final count = quiz.questionCount;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              Icons.quiz_outlined,
              size: 18,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                title == null || title.isEmpty
                    ? context.tr('quizCardTitleUnavailable')
                    : title,
                softWrap: true,
                style: text.titleSmall?.copyWith(fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(
            subject == null || subject.isEmpty
                ? context.tr('quizCardSubjectUnavailable')
                : '${context.tr('quizCardSubject')}: $subject',
            softWrap: true,
            style: text.bodySmall,
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 3),
          child: Text(
            count == null
                ? context.tr('quizCardCountUnknown')
                : '$count ${context.tr('quizCardQuestions')}',
            softWrap: true,
            style: text.bodySmall,
          ),
        ),
        if (onOpen != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                key: const Key('quiz-card-open'),
                onPressed: onOpen,
                icon: const Icon(Icons.open_in_new, size: 18),
                label: Text(context.tr('quizCardOpen')),
              ),
            ),
          ),
      ],
    );
  }

  Widget _placeholder(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.quiz_outlined, size: 20, color: Theme.of(context).hintColor),
        const SizedBox(height: 6),
        Text(
          context.tr('quizCardUnavailable'),
          textAlign: TextAlign.center,
          softWrap: true,
          style: Theme.of(context).textTheme.bodySmall,
        ),
        if (restricted)
          Text(
            context.tr('quizCardRestricted'),
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall,
          )
        else if (onRetry != null)
          TextButton(
            key: const Key('quiz-card-retry'),
            onPressed: onRetry,
            child: Text(context.tr('quizCardRetry')),
          ),
      ],
    ),
  );
}
