import '../../dal/remote/api_adapter.dart';
import '../models/local_note.dart';
import '../models/note_document.dart';
import 'local_note_store.dart';

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
    completed:
        (j['completed'] as bool?) ??
        ('${j['status'] ?? 'open'}' == 'completed'),
  );
}

final class TaskSummaryPage {
  final List<TaskSummary> items;
  final String? nextCursor;

  const TaskSummaryPage({required this.items, required this.nextCursor});

  factory TaskSummaryPage.fromJson(Map<String, dynamic> json) =>
      TaskSummaryPage(
        items: [
          for (final item in (json['items'] as List?) ?? const [])
            TaskSummary.fromJson(Map<String, dynamic>.from(item as Map)),
        ],
        nextCursor: (json['next_cursor'] as String?)?.trim().isNotEmpty == true
            ? (json['next_cursor'] as String).trim()
            : null,
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
  }) => TaskCardRef(
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

  void attachCard(
    String cardId,
    String taskId, {
    required bool isInstant,
    TaskSummary? cached,
  }) {
    if (isInstant) {
      throw StateError(
        'Tasks are allowed in notes only, never in Instant rooms.',
      );
    }
    _cards[cardId] = TaskCardRef(
      cardId: cardId,
      taskId: taskId,
      cached: cached,
    );
  }

  /// Removing a card removes only the card reference; the task remains on the server.
  void removeCardOnly(String cardId) {
    _cards.remove(cardId);
  }

  TaskCardRef? card(String cardId) => _cards[cardId];

  /// Attaches a `task_card` reference item (`{id, kind: 'task_card', x, y, width, height, task_id}`)
  /// inside the note document persisted in [store]. Never stores task body fields in the note.
  Future<void> attachCardToNote(
    LocalNoteStore store, {
    required String noteId,
    required String cardId,
    required String taskId,
    int x = 0,
    int y = 0,
    int width = 300,
    int height = 120,
    TaskSummary? cached,
  }) async {
    final note = await store.load(noteId);
    if (note == null) throw StateError('Note $noteId not found');
    final docJson = Map<String, dynamic>.from(note.document.toJson());
    final items = List<Map<String, dynamic>>.from(
      ((docJson['items'] as List?) ?? const []).map(
        (e) => Map<String, dynamic>.from(e as Map),
      ),
    );
    items.removeWhere((it) => '${it['id']}' == cardId);
    items.add({
      'id': cardId,
      'kind': 'task_card',
      'x': x,
      'y': y,
      'width': width,
      'height': height,
      'task_id': taskId,
    });
    docJson['items'] = items;
    await store.save(
      LocalNoteDraft(
        id: note.id,
        schema: note.schema,
        document: NoteDocument.fromJson(docJson, schema: note.schema),
        title: note.title,
      ),
    );
    attachCard(cardId, taskId, isInstant: false, cached: cached);
  }

  /// Removes only the `task_card` reference item from the note document in [store].
  Future<void> removeCardFromNote(
    LocalNoteStore store, {
    required String noteId,
    required String cardId,
  }) async {
    final note = await store.load(noteId);
    if (note != null) {
      final docJson = Map<String, dynamic>.from(note.document.toJson());
      final items = List<Map<String, dynamic>>.from(
        ((docJson['items'] as List?) ?? const []).map(
          (e) => Map<String, dynamic>.from(e as Map),
        ),
      );
      items.removeWhere((it) => '${it['id']}' == cardId);
      docJson['items'] = items;
      await store.save(
        LocalNoteDraft(
          id: note.id,
          schema: note.schema,
          document: NoteDocument.fromJson(docJson, schema: note.schema),
          title: note.title,
        ),
      );
    }
    removeCardOnly(cardId);
  }

  /// Loads `task_card` references from the persisted note document in [store].
  Future<List<TaskCardRef>> loadCardsFromNote(
    LocalNoteStore store,
    String noteId,
  ) async {
    final note = await store.load(noteId);
    if (note == null) return const [];
    final items = (note.document.toJson()['items'] as List?) ?? const [];
    final loaded = <TaskCardRef>[];
    for (final raw in items) {
      if (raw is Map && '${raw['kind'] ?? ''}' == 'task_card') {
        final cardId = '${raw['id']}';
        final taskId = '${raw['task_id']}';
        final ref = TaskCardRef(
          cardId: cardId,
          taskId: taskId,
          cached: _cards[cardId]?.cached,
        );
        _cards[cardId] = ref;
        loaded.add(ref);
      }
    }
    return loaded;
  }

  Future<TaskSummary> createTask({
    required String title,
    String? description,
    String? dueDate,
    bool completed = false,
    required bool isInstant,
  }) async {
    if (isInstant) {
      throw StateError(
        'Tasks are allowed in notes only, never in Instant rooms.',
      );
    }
    final resp = await api.request(
      '/me/tasks',
      method: 'POST',
      body: {
        'title': title,
        'description': ?description,
        'due_date': ?dueDate,
        'status': completed ? 'completed' : 'open',
      },
    );
    return TaskSummary.fromJson(resp);
  }

  Future<List<TaskSummary>> listOwnTasks() async {
    return (await listOwnTaskPage()).items;
  }

  Future<TaskSummaryPage> listOwnTaskPage({String? cursor}) async {
    final query = <String, String>{'limit': '50'};
    if (cursor != null && cursor.isNotEmpty) query['cursor'] = cursor;
    final response = await api.request(
      '/me/tasks',
      method: 'GET',
      query: query,
    );
    return TaskSummaryPage.fromJson(response);
  }

  /// Refreshes all cards referencing [taskId]. Marks them unavailable on 404/410.
  Future<void> refreshTask(String taskId) async {
    try {
      final resp = await api.request('/me/tasks/$taskId', method: 'GET');
      final fresh = TaskSummary.fromJson(resp);
      for (final entry in _cards.entries.toList()) {
        if (entry.value.taskId == taskId) {
          _cards[entry.key] = entry.value.copyWith(
            cached: fresh,
            unavailable: false,
          );
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

  /// Updates a task; normalizes `completed` to `status: "open" | "completed"`.
  /// When offline/failing, keeps entered changes in `pendingUpdate` and never claims success.
  Future<bool> updateTaskForCard(
    String cardId,
    Map<String, Object?> patch,
  ) async {
    final existing = _cards[cardId];
    if (existing == null) return false;
    final body = Map<String, Object?>.from(patch);
    if (body.containsKey('completed')) {
      final done = body.remove('completed') == true;
      body.putIfAbsent('status', () => done ? 'completed' : 'open');
    }
    try {
      final resp = await api.request(
        '/me/tasks/${existing.taskId}',
        method: 'PATCH',
        body: body,
      );
      _cards[cardId] = existing.copyWith(
        cached: TaskSummary.fromJson(resp),
        unavailable: false,
        clearPending: true,
      );
      return true;
    } catch (_) {
      _cards[cardId] = existing.copyWith(pendingUpdate: body);
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
