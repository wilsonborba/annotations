import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../dal/remote/api_adapter.dart';
import '../../../domain/services/task_card_service.dart';
import 'scope.dart';

typedef CreateOwnerTask =
    Future<TaskSummary> Function({
      required String title,
      String? description,
      String? dueDate,
      required bool completed,
    });

/// Lets a note owner attach one of their existing tasks to the current note.
/// The caller loads tasks with its trusted session and owns persistence.
Future<TaskSummary?> showTaskCardPicker(
  BuildContext context, {
  required List<TaskSummary> tasks,
  CreateOwnerTask? createTask,
  Future<List<TaskSummary>> Function()? reloadTasks,
  bool Function()? isOwnerScopeCurrent,
  ValueListenable<int>? ownerScopeRevision,
  int? expectedOwnerScopeRevision,
}) async {
  if (isOwnerScopeCurrent?.call() == false) return null;
  return showDialog<TaskSummary>(
    context: context,
    builder: (dialogContext) => _TaskCardPickerDialog(
      tasks: tasks,
      createTask: createTask,
      reloadTasks: reloadTasks,
      isOwnerScopeCurrent: isOwnerScopeCurrent,
      ownerScopeRevision: ownerScopeRevision,
      expectedOwnerScopeRevision: expectedOwnerScopeRevision,
    ),
  );
}

class _TaskCardPickerDialog extends StatefulWidget {
  const _TaskCardPickerDialog({
    required this.tasks,
    required this.createTask,
    required this.reloadTasks,
    required this.isOwnerScopeCurrent,
    required this.ownerScopeRevision,
    required this.expectedOwnerScopeRevision,
  });

  final List<TaskSummary> tasks;
  final CreateOwnerTask? createTask;
  final Future<List<TaskSummary>> Function()? reloadTasks;
  final bool Function()? isOwnerScopeCurrent;
  final ValueListenable<int>? ownerScopeRevision;
  final int? expectedOwnerScopeRevision;

  @override
  State<_TaskCardPickerDialog> createState() => _TaskCardPickerDialogState();
}

class _TaskCardPickerDialogState extends State<_TaskCardPickerDialog> {
  bool get _scopeIsCurrent => widget.isOwnerScopeCurrent?.call() ?? true;

  Future<void> _createTask() async {
    final create = widget.createTask;
    if (create == null || !_scopeIsCurrent) return;
    final task = await showDialog<TaskSummary>(
      context: context,
      builder: (context) => _TaskCreateDialog(
        createTask: create,
        reloadTasks: widget.reloadTasks,
        isOwnerScopeCurrent: widget.isOwnerScopeCurrent,
        ownerScopeRevision: widget.ownerScopeRevision,
        expectedOwnerScopeRevision: widget.expectedOwnerScopeRevision,
      ),
    );
    if (!mounted || !_scopeIsCurrent || task == null) return;
    Navigator.of(context).pop(task);
  }

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
      if (widget.createTask != null)
        FilledButton.tonalIcon(
          key: const Key('task-create-open'),
          onPressed: _scopeIsCurrent ? _createTask : null,
          icon: const Icon(Icons.add),
          label: Text(context.tr('taskCreateAction')),
        ),
    ],
  );
}

class _TaskCreateDialog extends StatefulWidget {
  const _TaskCreateDialog({
    required this.createTask,
    required this.reloadTasks,
    required this.isOwnerScopeCurrent,
    required this.ownerScopeRevision,
    required this.expectedOwnerScopeRevision,
  });

  final CreateOwnerTask createTask;
  final Future<List<TaskSummary>> Function()? reloadTasks;
  final bool Function()? isOwnerScopeCurrent;
  final ValueListenable<int>? ownerScopeRevision;
  final int? expectedOwnerScopeRevision;

  @override
  State<_TaskCreateDialog> createState() => _TaskCreateDialogState();
}

class _TaskCreateDialogState extends State<_TaskCreateDialog> {
  final _title = TextEditingController();
  final _description = TextEditingController();
  final _dueDate = TextEditingController();
  bool _completed = false;
  bool _saving = false;
  bool _uncertain = false;
  bool _checking = false;
  List<TaskSummary>? _checkedTasks;
  String? _error;

  bool get _scopeIsCurrent => widget.isOwnerScopeCurrent?.call() ?? true;
  bool get _fieldsEnabled => !_saving && !_uncertain;
  bool get _canCreate =>
      _fieldsEnabled &&
      _scopeIsCurrent &&
      _title.text.trim().isNotEmpty &&
      _validDate(_dueDate.text.trim());
  bool get _canRetryCreate =>
      _uncertain &&
      _checkedTasks != null &&
      !_saving &&
      _scopeIsCurrent &&
      _title.text.trim().isNotEmpty &&
      _validDate(_dueDate.text.trim());

  bool _validDate(String value) {
    if (value.isEmpty) return true;
    if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value)) return false;
    final month = int.tryParse(value.substring(5, 7)) ?? 0;
    final day = int.tryParse(value.substring(8, 10)) ?? 0;
    return month >= 1 && month <= 12 && day >= 1 && day <= 31;
  }

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

  Future<void> _create() async {
    if (!_canCreate && !_canRetryCreate) return;
    final title = _title.text.trim();
    final description = _description.text.trim();
    final dueDate = _dueDate.text.trim();
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final created = await widget.createTask(
        title: title,
        description: description.isEmpty ? null : description,
        dueDate: dueDate.isEmpty ? null : dueDate,
        completed: _completed,
      );
      if (!mounted || !_scopeIsCurrent) return;
      if (created.taskId.trim().isEmpty) {
        throw const FormatException('Task service returned no task ID.');
      }
      Navigator.of(context).pop(created);
    } on ApiError catch (error) {
      if (!mounted || !_scopeIsCurrent) return;
      final rejected = error.status == 400 || error.status == 422;
      setState(() {
        _error = rejected ? context.tr('taskCreateFailed') : null;
        // Task API validation errors happen before Plane creation. Transport,
        // service and other failures may have happened after the POST.
        _uncertain = !rejected;
        _checkedTasks = null;
      });
    } on Object {
      if (!mounted || !_scopeIsCurrent) return;
      setState(() {
        _error = null;
        _uncertain = true;
        _checkedTasks = null;
      });
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _checkTasks() async {
    final reload = widget.reloadTasks;
    if (reload == null || !_scopeIsCurrent) return;
    setState(() {
      _checking = true;
      _error = null;
    });
    try {
      final tasks = await reload();
      if (!mounted || !_scopeIsCurrent) return;
      setState(() => _checkedTasks = tasks);
    } on Object {
      if (!mounted || !_scopeIsCurrent) return;
      setState(() => _error = context.tr('taskCreateCheckFailed'));
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  @override
  void dispose() {
    widget.ownerScopeRevision?.removeListener(_scopeChanged);
    _title.dispose();
    _description.dispose();
    _dueDate.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(context.tr('taskCreateTitle')),
    content: SizedBox(
      width: 440,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              key: const Key('task-create-title'),
              controller: _title,
              enabled: _fieldsEnabled,
              maxLength: 255,
              decoration: InputDecoration(labelText: context.tr('title')),
              onChanged: (_) => setState(() {}),
            ),
            TextField(
              key: const Key('task-create-description'),
              controller: _description,
              enabled: _fieldsEnabled,
              maxLength: 10000,
              maxLines: 3,
              decoration: InputDecoration(
                labelText: context.tr('taskCreateDescription'),
              ),
            ),
            TextField(
              key: const Key('task-create-due-date'),
              controller: _dueDate,
              enabled: _fieldsEnabled,
              decoration: InputDecoration(
                labelText: context.tr('taskCreateDueDate'),
                hintText: 'YYYY-MM-DD',
                errorText: _validDate(_dueDate.text.trim())
                    ? null
                    : context.tr('taskCreateInvalidDueDate'),
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              key: const Key('task-create-status'),
              initialValue: _completed ? 'completed' : 'open',
              decoration: InputDecoration(
                labelText: context.tr('taskCreateStatus'),
              ),
              items: [
                DropdownMenuItem(
                  value: 'open',
                  child: Text(context.tr('taskOpen')),
                ),
                DropdownMenuItem(
                  value: 'completed',
                  child: Text(context.tr('taskCompleted')),
                ),
              ],
              onChanged: !_fieldsEnabled
                  ? null
                  : (value) =>
                        setState(() => _completed = value == 'completed'),
            ),
            if (_uncertain) ...[
              const SizedBox(height: 12),
              Text(
                context.tr('taskCreateOutcomeUnknown'),
                key: const Key('task-create-uncertain'),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
              if (_checkedTasks case final tasks?) ...[
                const SizedBox(height: 12),
                if (tasks.isEmpty)
                  Text(context.tr('taskPickerEmpty'))
                else
                  SizedBox(
                    height: 220,
                    child: ListView.builder(
                      itemCount: tasks.length,
                      itemBuilder: (context, index) {
                        final task = tasks[index];
                        return ListTile(
                          key: Key('task-create-found-${task.taskId}'),
                          title: Text(task.title),
                          subtitle: Text(
                            task.dueDate == null || task.dueDate!.isEmpty
                                ? context.tr(
                                    task.completed
                                        ? 'taskCompleted'
                                        : 'taskOpen',
                                  )
                                : '${context.tr('taskDue')}: ${task.dueDate}',
                          ),
                          onTap: _scopeIsCurrent
                              ? () => Navigator.of(context).pop(task)
                              : null,
                        );
                      },
                    ),
                  ),
              ],
            ],
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                _error!,
                key: const Key('task-create-error'),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: _saving ? null : () => Navigator.of(context).pop(),
        child: Text(context.tr('cancel')),
      ),
      if (_uncertain && _checkedTasks == null && widget.reloadTasks != null)
        OutlinedButton(
          key: const Key('task-create-check-existing'),
          onPressed: _checking ? null : _checkTasks,
          child: Text(
            _checking
                ? context.tr('taskCreateChecking')
                : context.tr('taskCreateCheckExisting'),
          ),
        ),
      if (_uncertain && _checkedTasks != null)
        OutlinedButton(
          key: const Key('task-create-check-again'),
          onPressed: _checking ? null : _checkTasks,
          child: Text(context.tr('taskCreateCheckExisting')),
        ),
      if (_uncertain && _checkedTasks != null)
        FilledButton(
          key: const Key('task-create-confirm-retry'),
          onPressed: _canRetryCreate ? _create : null,
          child: Text(context.tr('taskCreateAgain')),
        ),
      if (!_uncertain)
        FilledButton(
          key: const Key('task-create-submit'),
          onPressed: _canCreate ? _create : null,
          child: Text(
            _saving
                ? context.tr('taskCreateSaving')
                : context.tr('taskCreateActionSubmit'),
          ),
        ),
    ],
  );
}
