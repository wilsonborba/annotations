import '../../dal/remote/api_adapter.dart';

final class TaskSummary {
  final String taskId;
  final String title;
  final String? description;
  final String? dueDate;
  final bool completed;

  const TaskSummary({
    required this.taskId,
    required this.title,
    this.description,
    this.dueDate,
    required this.completed,
  });

  factory TaskSummary.fromJson(Map<String, dynamic> j) => TaskSummary(
        taskId: '${j['task_id'] ?? j['id'] ?? ''}',
        title: '${j['title'] ?? ''}',
        description: j['description'] as String?,
        dueDate: j['due_date'] as String?,
        completed: (j['completed'] as bool?) ?? ('${j['status'] ?? 'open'}' == 'completed'),
      );
}

final class TaskCardRef {
  final String cardId;
  final String taskId;
  final TaskSummary? cached;
  final bool unavailable;
  final Map<String, Object?>? pendingUpdate;

  const TaskCardRef({
    required this.cardId,
    required this.taskId,
    this.cached,
    this.unavailable = false,
    this.pendingUpdate,
  });

  TaskCardRef copyWith({
    TaskSummary? cached,
    bool? unavailable,
    Map<String, Object?>? pendingUpdate,
    bool clearPending = false,
  }) =>
      TaskCardRef(
        cardId: cardId,
        taskId: taskId,
        cached: cached ?? this.cached,
        unavailable: unavailable ?? this.unavailable,
        pendingUpdate: clearPending ? null : (pendingUpdate ?? this.pendingUpdate),
      );
}

/// Adapter and card state manager for owner tasks (`/me/tasks`, annotations#50).
/// Notes only (no tasks in Instant). Cards store only the task reference.
class TaskCardService {
  final ApiAdapter api;
  final Map<String, TaskCardRef> _cards = {};

  TaskCardService(this.api);

  void attachCard(String cardId, String taskId, {required bool isInstant, TaskSummary? cached}) {
    if (isInstant) {
      throw StateError('Tasks are allowed in notes only, never in Instant rooms.');
    }
    _cards[cardId] = TaskCardRef(cardId: cardId, taskId: taskId, cached: cached);
  }

  /// Removing a card removes only the card reference; the task remains on the server.
  void removeCardOnly(String cardId) {
    _cards.remove(cardId);
  }

  TaskCardRef? card(String cardId) => _cards[cardId];

  Future<TaskSummary> createTask({
    required String title,
    String? description,
    String? dueDate,
    bool completed = false,
    required bool isInstant,
  }) async {
    if (isInstant) {
      throw StateError('Tasks are allowed in notes only, never in Instant rooms.');
    }
    final resp = await api.request(
      '/me/tasks',
      method: 'POST',
      body: {
        'title': title,
        'description': ?description,
        'due_date': ?dueDate,
        'completed': completed,
      },
    );
    return TaskSummary.fromJson(resp);
  }

  Future<List<TaskSummary>> listOwnTasks() async {
    final resp = await api.request('/me/tasks', method: 'GET');
    final items = (resp['items'] as List?) ?? const [];
    return [for (final it in items) TaskSummary.fromJson(Map<String, dynamic>.from(it as Map))];
  }

  /// Refreshes all cards referencing [taskId]. Marks them unavailable on 404/410.
  Future<void> refreshTask(String taskId) async {
    try {
      final resp = await api.request('/me/tasks/$taskId', method: 'GET');
      final fresh = TaskSummary.fromJson(resp);
      for (final entry in _cards.entries.toList()) {
        if (entry.value.taskId == taskId) {
          _cards[entry.key] = entry.value.copyWith(cached: fresh, unavailable: false);
        }
      }
    } on ApiError catch (err) {
      if (err.status == 404 || err.status == 410) {
        for (final entry in _cards.entries.toList()) {
          if (entry.value.taskId == taskId) {
            _cards[entry.key] = entry.value.copyWith(unavailable: true);
          }
        }
        return;
      }
      rethrow;
    }
  }

  /// Updates a task; when offline/failing, keeps entered changes in `pendingUpdate`
  /// and never claims the update succeeded.
  Future<bool> updateTaskForCard(String cardId, Map<String, Object?> patch) async {
    final existing = _cards[cardId];
    if (existing == null) return false;
    try {
      final resp = await api.request(
        '/me/tasks/${existing.taskId}',
        method: 'PATCH',
        body: patch,
      );
      _cards[cardId] = existing.copyWith(
        cached: TaskSummary.fromJson(resp),
        unavailable: false,
        clearPending: true,
      );
      return true;
    } catch (_) {
      _cards[cardId] = existing.copyWith(pendingUpdate: patch);
      return false;
    }
  }

  /// Separate confirmed deletion of the task itself.
  Future<void> deleteTask(String taskId) async {
    await api.request('/me/tasks/$taskId', method: 'DELETE');
    for (final entry in _cards.entries.toList()) {
      if (entry.value.taskId == taskId) {
        _cards[entry.key] = entry.value.copyWith(unavailable: true);
      }
    }
  }
}
