import 'dart:convert';
import 'dart:io';

import 'package:annotations_shared/dal/local/sqlite_note_store.dart';
import 'package:annotations_shared/dal/remote/api_adapter.dart';
import 'package:annotations_shared/domain/models/local_note.dart';
import 'package:annotations_shared/domain/models/note_document.dart';
import 'package:annotations_shared/domain/services/task_card_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test(
    'uses status open/completed (never completed bool), persists task_card reference only in SqliteNoteStore, and marks remaining cards unavailable on delete',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'annotations_50_test_',
      );
      final store = await SqliteNoteStore.open(tempDir.path);
      try {
        final origSchema = DocumentSchema(
          DocumentFamily.original.schemaName,
          1,
        );
        await store.save(
          LocalNoteDraft(
            id: 'n1',
            schema: origSchema,
            document: NoteDocument.fromJson({
              'page': {
                'width': 1000,
                'background': {'kind': 'blank'},
              },
              'items': [],
            }, schema: origSchema),
            title: 'Tasks Note',
          ),
        );

        final tasks = <String, Map<String, Object?>>{};
        var seq = 0;

        final mock = MockClient((req) async {
          if (req.method == 'POST' && req.url.path.endsWith('/me/tasks')) {
            final id = 't_${++seq}';
            final body = jsonDecode(req.body) as Map<String, dynamic>;
            expect(body.containsKey('completed'), isFalse);
            expect(body['status'], anyOf('open', 'completed'));
            final t = {'task_id': id, ...body};
            tasks[id] = t;
            return http.Response(jsonEncode(t), 201);
          }
          if (req.method == 'PATCH' && req.url.path.contains('/me/tasks/')) {
            final id = req.url.pathSegments.last;
            final body = jsonDecode(req.body) as Map<String, dynamic>;
            expect(body.containsKey('completed'), isFalse);
            expect(body['status'], anyOf('open', 'completed'));
            tasks[id] = {...?tasks[id], ...body};
            return http.Response(jsonEncode(tasks[id]), 200);
          }
          if (req.method == 'GET' && req.url.path.contains('/me/tasks/')) {
            final id = req.url.pathSegments.last;
            final t = tasks[id];
            if (t == null) {
              return http.Response(jsonEncode({'error': 'not_found'}), 404);
            }
            return http.Response(jsonEncode(t), 200);
          }
          if (req.method == 'DELETE' && req.url.path.contains('/me/tasks/')) {
            final id = req.url.pathSegments.last;
            tasks.remove(id);
            return http.Response('{}', 200);
          }
          return http.Response('{}', 404);
        });

        final api = ApiAdapter(
          client: mock,
          base: 'https://api.asodya.com/apps/annotations/v1',
        );
        final service1 = TaskCardService(api);

        // Notes only; Instant rejected.
        expect(
          () => service1.attachCard('c0', 't_1', isInstant: true),
          throwsA(isA<StateError>()),
        );

        final created = await service1.createTask(
          title: 'Prepare release',
          isInstant: false,
        );
        expect(created.completed, isFalse);

        await service1.attachCardToNote(
          store,
          noteId: 'n1',
          cardId: 'card_1',
          taskId: created.taskId,
          cached: created,
        );
        await service1.attachCardToNote(
          store,
          noteId: 'n1',
          cardId: 'card_2',
          taskId: created.taskId,
          y: 140,
          cached: created,
        );

        // Verify only the task_card reference is stored in the note document (no task title/status).
        final storedJson = jsonEncode(
          (await store.load('n1'))!.document.toJson(),
        );
        expect(storedJson, contains('"task_id":"${created.taskId}"'));
        expect(storedJson, isNot(contains('Prepare release')));

        // Brand-new TaskCardService loads cards back from SqliteNoteStore.
        final service2 = TaskCardService(api);
        final loaded = await service2.loadCardsFromNote(store, 'n1');
        expect(loaded.map((c) => c.cardId).toSet(), {'card_1', 'card_2'});

        // Update status sends status: "completed".
        expect(
          await service2.updateTaskForCard('card_2', {'completed': true}),
          isTrue,
        );
        expect(service2.card('card_2')!.cached!.completed, isTrue);

        // Removing card_1 keeps the task alive on the server and on card_2.
        await service2.removeCardFromNote(
          store,
          noteId: 'n1',
          cardId: 'card_1',
        );
        expect(service2.card('card_1'), isNull);
        await service2.refreshTask(created.taskId);
        expect(service2.card('card_2')!.unavailable, isFalse);

        // Deleting the task marks card_2 unavailable.
        await service2.deleteTask(created.taskId);
        expect(service2.card('card_2')!.unavailable, isTrue);
      } finally {
        await store.close();
        if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
      }
    },
  );

  test(
    'offline update keeps pending normalized status for retry and never claims success',
    () async {
      final mock = MockClient((_) async => throw Exception('offline'));
      final service = TaskCardService(
        ApiAdapter(
          client: mock,
          base: 'https://api.asodya.com/apps/annotations/v1',
        ),
      );
      const cached = TaskSummary(taskId: 't_1', title: 'Old', completed: false);
      service.attachCard('card_1', 't_1', isInstant: false, cached: cached);

      final ok = await service.updateTaskForCard('card_1', {'completed': true});
      expect(ok, isFalse);
      expect(service.card('card_1')!.cached!.completed, isFalse);
      expect(service.card('card_1')!.pendingUpdate, {'status': 'completed'});
    },
  );
}
