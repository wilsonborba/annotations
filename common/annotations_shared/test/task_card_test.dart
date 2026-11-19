import 'dart:convert';

import 'package:annotations_shared/dal/remote/api_adapter.dart';
import 'package:annotations_shared/domain/services/task_card_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('removing a card keeps the task; deleting the task shows unavailable on other cards', () async {
    final tasks = <String, Map<String, Object?>>{};
    var seq = 0;

    final mock = MockClient((req) async {
      if (req.method == 'POST' && req.url.path.endsWith('/me/tasks')) {
        final id = 't_${++seq}';
        final body = jsonDecode(req.body) as Map<String, dynamic>;
        final t = {'task_id': id, ...body};
        tasks[id] = t;
        return http.Response(jsonEncode(t), 201);
      }
      if (req.method == 'GET' && req.url.path.contains('/me/tasks/')) {
        final id = req.url.pathSegments.last;
        final t = tasks[id];
        if (t == null) return http.Response(jsonEncode({'error': 'not_found'}), 404);
        return http.Response(jsonEncode(t), 200);
      }
      if (req.method == 'DELETE' && req.url.path.contains('/me/tasks/')) {
        final id = req.url.pathSegments.last;
        tasks.remove(id);
        return http.Response('{}', 200);
      }
      return http.Response('{}', 404);
    });

    final service = TaskCardService(
      ApiAdapter(client: mock, base: 'https://api.asodya.com/apps/annotations/v1'),
    );

    // Notes only; Instant rejected.
    expect(
      () => service.attachCard('c0', 't_1', isInstant: true),
      throwsA(isA<StateError>()),
    );

    final created = await service.createTask(title: 'Prepare release', isInstant: false);
    service.attachCard('card_1', created.taskId, isInstant: false, cached: created);
    service.attachCard('card_2', created.taskId, isInstant: false, cached: created);

    // Removing card_1 keeps the task alive on the server and on card_2.
    service.removeCardOnly('card_1');
    expect(service.card('card_1'), isNull);
    await service.refreshTask(created.taskId);
    expect(service.card('card_2')!.unavailable, isFalse);

    // Deleting the task marks card_2 unavailable.
    await service.deleteTask(created.taskId);
    expect(service.card('card_2')!.unavailable, isTrue);
  });

  test('offline update keeps pending changes for retry and never claims success', () async {
    final mock = MockClient((_) async => throw Exception('offline'));
    final service = TaskCardService(
      ApiAdapter(client: mock, base: 'https://api.asodya.com/apps/annotations/v1'),
    );
    const cached = TaskSummary(taskId: 't_1', title: 'Old', completed: false);
    service.attachCard('card_1', 't_1', isInstant: false, cached: cached);

    final ok = await service.updateTaskForCard('card_1', {'completed': true});
    expect(ok, isFalse);
    expect(service.card('card_1')!.cached!.completed, isFalse);
    expect(service.card('card_1')!.pendingUpdate, {'completed': true});
  });
}
