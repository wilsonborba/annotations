import 'package:flutter/material.dart';

import '../../../domain/services/task_card_service.dart';
import 'scope.dart';

/// Shows authorized live or saved task details without copying them into the note.
/// Text wraps at the card width, so a narrow card grows downward.
class TaskCardView extends StatelessWidget {
  const TaskCardView({
    super.key,
    required this.task,
    this.loading = false,
    this.restricted = false,
    this.unavailable = false,
    this.onRetry,
  });

  final TaskSummary? task;
  final bool loading;
  final bool restricted;
  final bool unavailable;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final content = restricted || unavailable
        ? _placeholder(context)
        : loading && task == null
        ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
        : task == null
        ? _placeholder(context)
        : _task(context, task!);
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

  Widget _task(BuildContext context, TaskSummary task) {
    final colors = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 8,
          runSpacing: 4,
          children: [
            Icon(Icons.checklist, size: 18, color: colors.primary),
            Text(
              task.title,
              softWrap: true,
              style: Theme.of(
                context,
              ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
            ),
          ],
        ),
        if (task.dueDate != null && task.dueDate!.trim().isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              '${context.tr('taskDue')}: ${task.dueDate}',
              softWrap: true,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        if (task.description != null && task.description!.trim().isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              task.description!,
              softWrap: true,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Chip(
              visualDensity: VisualDensity.compact,
              label: Text(
                context.tr(task.completed ? 'taskCompleted' : 'taskOpen'),
              ),
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
        Icon(
          restricted ? Icons.lock_outline : Icons.checklist,
          size: 20,
          color: Theme.of(context).hintColor,
        ),
        const SizedBox(height: 6),
        Text(
          context.tr(
            restricted
                ? 'taskRestricted'
                : unavailable
                ? 'taskUnavailable'
                : 'taskLoading',
          ),
          textAlign: TextAlign.center,
          softWrap: true,
          style: Theme.of(context).textTheme.bodySmall,
        ),
        if (onRetry != null && !restricted)
          TextButton(
            key: const Key('task-retry'),
            onPressed: onRetry,
            child: Text(context.tr('taskRetry')),
          ),
      ],
    ),
  );
}
