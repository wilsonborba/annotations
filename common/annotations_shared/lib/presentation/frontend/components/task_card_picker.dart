import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../domain/services/task_card_service.dart';
import 'scope.dart';

/// Lets a note owner attach one of their existing tasks to the current note.
/// The caller loads tasks with its trusted session and owns persistence.
Future<TaskSummary?> showTaskCardPicker(
  BuildContext context, {
  required List<TaskSummary> tasks,
  bool Function()? isOwnerScopeCurrent,
  ValueListenable<int>? ownerScopeRevision,
  int? expectedOwnerScopeRevision,
}) async {
  if (isOwnerScopeCurrent?.call() == false) return null;
  return showDialog<TaskSummary>(
    context: context,
    builder: (dialogContext) => _TaskCardPickerDialog(
      tasks: tasks,
      isOwnerScopeCurrent: isOwnerScopeCurrent,
      ownerScopeRevision: ownerScopeRevision,
      expectedOwnerScopeRevision: expectedOwnerScopeRevision,
    ),
  );
}

class _TaskCardPickerDialog extends StatefulWidget {
  const _TaskCardPickerDialog({
    required this.tasks,
    required this.isOwnerScopeCurrent,
    required this.ownerScopeRevision,
    required this.expectedOwnerScopeRevision,
  });

  final List<TaskSummary> tasks;
  final bool Function()? isOwnerScopeCurrent;
  final ValueListenable<int>? ownerScopeRevision;
  final int? expectedOwnerScopeRevision;

  @override
  State<_TaskCardPickerDialog> createState() => _TaskCardPickerDialogState();
}

class _TaskCardPickerDialogState extends State<_TaskCardPickerDialog> {
  bool get _scopeIsCurrent => widget.isOwnerScopeCurrent?.call() ?? true;

  @override
  void initState() {
    super.initState();
    widget.ownerScopeRevision?.addListener(_scopeChanged);
  }

  void _scopeChanged() {
    if (widget.ownerScopeRevision?.value == widget.expectedOwnerScopeRevision &&
        _scopeIsCurrent) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.of(context).pop();
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  @override
  void dispose() {
    widget.ownerScopeRevision?.removeListener(_scopeChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(context.tr('taskAddToNote')),
    content: SizedBox(
      width: 420,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 480),
        child: widget.tasks.isEmpty
            ? Text(context.tr('taskPickerEmpty'))
            : ListView.builder(
                shrinkWrap: true,
                itemCount: widget.tasks.length,
                itemBuilder: (context, index) {
                  final task = widget.tasks[index];
                  return ListTile(
                    key: Key('task-choice-${task.taskId}'),
                    title: Text(task.title),
                    subtitle: Text(
                      context.tr(task.completed ? 'taskCompleted' : 'taskOpen'),
                    ),
                    onTap: _scopeIsCurrent
                        ? () => Navigator.of(context).pop(task)
                        : null,
                  );
                },
              ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: Text(context.tr('cancel')),
      ),
    ],
  );
}
