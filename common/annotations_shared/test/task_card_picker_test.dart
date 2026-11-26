import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:annotations_shared/dal/remote/api_adapter.dart';
import 'package:annotations_shared/domain/services/task_card_service.dart';
import 'package:annotations_shared/presentation/frontend/components/task_card_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'paper_canvas_test.dart' show host;

void main() {
  testWidgets('selects only an existing owner task', (tester) async {
    TaskSummary? selected;
    final task = const TaskSummary(
      taskId: 'task-1',
      title: 'Existing task',
      completed: false,
    );
    await tester.pumpWidget(
      host(
        Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              selected = await showTaskCardPicker(
                context,
                tasks: [task],
                isOwnerScopeCurrent: () => true,
              );
            },
            child: const Text('Open picker'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open picker'));
    await tester.pumpAndSettle();
    expect(find.text('Existing task'), findsOneWidget);
    await tester.tap(find.byKey(const Key('task-choice-task-1')));
    await tester.pumpAndSettle();
    expect(selected?.taskId, 'task-1');
  });

  testWidgets('closes when the verified owner scope changes', (tester) async {
    var current = true;
    final revision = ValueNotifier(4);
    addTearDown(revision.dispose);
    await tester.pumpWidget(
      host(
        Builder(
          builder: (context) => TextButton(
            onPressed: () => showTaskCardPicker(
              context,
              tasks: const [
                TaskSummary(
                  taskId: 'task-private',
                  title: 'Private owner task',
                  completed: false,
                ),
              ],
              isOwnerScopeCurrent: () => current,
              ownerScopeRevision: revision,
              expectedOwnerScopeRevision: 4,
            ),
            child: const Text('Open picker'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open picker'));
    await tester.pumpAndSettle();
    expect(find.text('Private owner task'), findsOneWidget);
    current = false;
    revision.value = 5;
    await tester.pumpAndSettle();
    expect(find.text('Private owner task'), findsNothing);
  });

  testWidgets('explains when there are no tasks to attach', (tester) async {
    await tester.pumpWidget(
      host(
        Builder(
          builder: (context) => TextButton(
            onPressed: () => showTaskCardPicker(context, tasks: const []),
            child: const Text('Open picker'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open picker'));
    await tester.pumpAndSettle();
    expect(find.text('You have no tasks to add to this note.'), findsOneWidget);
  });

  testWidgets('checks tasks after a lost create response before retrying', (
    tester,
  ) async {
    var postCount = 0;
    var listCount = 0;
    final service = TaskCardService(
      ApiAdapter(
        client: MockClient((request) async {
          if (request.method == 'POST' &&
              request.url.path.endsWith('/me/tasks')) {
            postCount++;
            throw const SocketException('response lost after create');
          }
          if (request.method == 'GET' &&
              request.url.path.endsWith('/me/tasks')) {
            listCount++;
            return http.Response(
              jsonEncode({
                'items': [
                  {
                    'task_id': 'task-created-before-timeout',
                    'title': 'Review chapter',
                    'description': 'Check the final section',
                    'due_date': '2026-12-01',
                    'status': 'open',
                  },
                ],
                'next_cursor': null,
              }),
              200,
            );
          }
          fail('Unexpected request: ${request.method} ${request.url.path}');
        }),
      ),
    );
    TaskSummary? selected;
    Future<TaskSummary?>? result;
    await tester.pumpWidget(
      host(
        Builder(
          builder: (context) => TextButton(
            onPressed: () {
              result = showTaskCardPicker(
                context,
                tasks: const [],
                createTask:
                    ({
                      required title,
                      description,
                      dueDate,
                      required completed,
                    }) => service.createTask(
                      title: title,
                      description: description,
                      dueDate: dueDate,
                      completed: completed,
                      isInstant: false,
                    ),
                loadTaskPage: service.listOwnTaskPage,
              );
            },
            child: const Text('Open picker'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open picker'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('task-create-open')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('task-create-title')),
      'Review chapter',
    );
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('task-create-title')))
          .controller!
          .text,
      'Review chapter',
    );
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('task-create-submit')))
          .onPressed,
      isNotNull,
    );
    await tester.tap(find.byKey(const Key('task-create-submit')));
    await tester.pumpAndSettle();

    expect(postCount, 1);
    expect(listCount, 0);
    expect(find.byKey(const Key('task-create-uncertain')), findsOneWidget);
    expect(find.byKey(const Key('task-create-confirm-retry')), findsNothing);

    await tester.tap(find.byKey(const Key('task-create-check-existing')));
    await tester.pumpAndSettle();
    expect(listCount, 1);
    expect(
      find.byKey(const Key('task-create-found-task-created-before-timeout')),
      findsOneWidget,
    );
    await tester.ensureVisible(
      find.byKey(const Key('task-create-found-task-created-before-timeout')),
    );
    await tester.tap(
      find.byKey(const Key('task-create-found-task-created-before-timeout')),
    );
    await tester.pumpAndSettle();
    selected = await result;
    expect(selected?.taskId, 'task-created-before-timeout');
    expect(postCount, 1);
  });

  testWidgets('allows only an explicit retry after an empty task check', (
    tester,
  ) async {
    var postCount = 0;
    final postedBodies = <Map<String, dynamic>>[];
    final service = TaskCardService(
      ApiAdapter(
        client: MockClient((request) async {
          if (request.method == 'POST' &&
              request.url.path.endsWith('/me/tasks')) {
            postCount++;
            postedBodies.add(jsonDecode(request.body) as Map<String, dynamic>);
            if (postCount == 1) {
              throw const SocketException('response lost');
            }
            return http.Response(
              jsonEncode({
                'task_id': 'task-explicit-retry',
                'title': 'Prepare review',
                'status': 'completed',
              }),
              201,
            );
          }
          if (request.method == 'GET' &&
              request.url.path.endsWith('/me/tasks')) {
            return http.Response(
              jsonEncode({'items': <Object?>[], 'next_cursor': null}),
              200,
            );
          }
          fail('Unexpected request: ${request.method} ${request.url.path}');
        }),
      ),
    );
    Future<TaskSummary?>? result;
    await tester.pumpWidget(
      host(
        Builder(
          builder: (context) => TextButton(
            onPressed: () {
              result = showTaskCardPicker(
                context,
                tasks: const [],
                createTask:
                    ({
                      required title,
                      description,
                      dueDate,
                      required completed,
                    }) => service.createTask(
                      title: title,
                      description: description,
                      dueDate: dueDate,
                      completed: completed,
                      isInstant: false,
                    ),
                loadTaskPage: service.listOwnTaskPage,
              );
            },
            child: const Text('Open picker'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open picker'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('task-create-open')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('task-create-title')),
      'Prepare review',
    );
    await tester.enterText(
      find.byKey(const Key('task-create-description')),
      'Read the comments',
    );
    await tester.enterText(
      find.byKey(const Key('task-create-due-date')),
      '2026-12-01',
    );
    await tester.tap(find.byKey(const Key('task-create-status')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Completed').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('task-create-submit')));
    await tester.pumpAndSettle();
    expect(postCount, 1);
    expect(find.byKey(const Key('task-create-uncertain')), findsOneWidget);

    await tester.tap(find.byKey(const Key('task-create-check-existing')));
    await tester.pumpAndSettle();
    expect(find.text('You have no tasks to add to this note.'), findsWidgets);
    expect(find.byKey(const Key('task-create-confirm-retry')), findsOneWidget);
    expect(postCount, 1);

    await tester.tap(find.byKey(const Key('task-create-confirm-retry')));
    await tester.pumpAndSettle();
    expect(postCount, 2);
    expect(postedBodies.first, postedBodies.last);
    expect(postedBodies.last, {
      'title': 'Prepare review',
      'description': 'Read the comments',
      'due_date': '2026-12-01',
      'status': 'completed',
    });
    expect((await result)?.taskId, 'task-explicit-retry');
  });

  testWidgets('loads the next owner task page and selects its older task', (
    tester,
  ) async {
    final requestedCursors = <String?>[];
    final tasks = [
      for (var index = 1; index <= 51; index++)
        {'task_id': 'task-$index', 'title': 'Task $index', 'status': 'open'},
    ];
    final service = TaskCardService(
      ApiAdapter(
        client: MockClient((request) async {
          if (request.method == 'GET' &&
              request.url.path.endsWith('/me/tasks')) {
            final cursor = request.url.queryParameters['cursor'];
            requestedCursors.add(cursor);
            expect(request.url.queryParameters['limit'], '50');
            if (cursor == null) {
              return http.Response(
                jsonEncode({
                  'items': tasks.take(50).toList(),
                  'next_cursor': 'tasks:page-2',
                }),
                200,
              );
            }
            expect(cursor, 'tasks:page-2');
            return http.Response(
              jsonEncode({
                'items': tasks.skip(50).toList(),
                'next_cursor': null,
              }),
              200,
            );
          }
          fail('Unexpected request: ${request.method} ${request.url.path}');
        }),
      ),
    );
    Future<TaskSummary?>? result;
    await tester.pumpWidget(
      host(
        Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              final page = await service.listOwnTaskPage();
              result = showTaskCardPicker(
                context,
                tasks: page.items,
                nextCursor: page.nextCursor,
                loadTaskPage: service.listOwnTaskPage,
              );
            },
            child: const Text('Open picker'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open picker'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('task-choice-task-1')), findsOneWidget);
    expect(find.byKey(const Key('task-choice-task-51')), findsNothing);

    await tester.tap(find.byKey(const Key('task-load-more')));
    await tester.pumpAndSettle();
    expect(requestedCursors, [null, 'tasks:page-2']);
    await tester.scrollUntilVisible(
      find.byKey(const Key('task-choice-task-51')),
      200,
      scrollable: find
          .descendant(
            of: find.byType(AlertDialog).last,
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(find.byKey(const Key('task-choice-task-51')), findsOneWidget);
    await tester.ensureVisible(find.byKey(const Key('task-choice-task-51')));
    await tester.tap(find.byKey(const Key('task-choice-task-51')));
    await tester.pumpAndSettle();
    expect((await result)?.taskId, 'task-51');
    expect(requestedCursors, [null, 'tasks:page-2']);
  });

  testWidgets('discards a task page returned after owner scope changes', (
    tester,
  ) async {
    final revision = ValueNotifier<int>(0);
    var ownerCurrent = true;
    final pageResult = Completer<TaskSummaryPage>();
    Future<TaskSummary?>? result;
    await tester.pumpWidget(
      host(
        Builder(
          builder: (context) => TextButton(
            onPressed: () {
              result = showTaskCardPicker(
                context,
                tasks: const [
                  TaskSummary(
                    taskId: 'task-first-page',
                    title: 'First page task',
                    completed: false,
                  ),
                ],
                nextCursor: 'tasks:page-2',
                isOwnerScopeCurrent: () => ownerCurrent,
                ownerScopeRevision: revision,
                expectedOwnerScopeRevision: 0,
                loadTaskPage: ({String? cursor}) => pageResult.future,
              );
            },
            child: const Text('Open picker'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open picker'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('task-load-more')));
    await tester.tap(find.byKey(const Key('task-load-more')));
    await tester.pump();

    ownerCurrent = false;
    revision.value = 1;
    await tester.pumpAndSettle();
    pageResult.complete(
      const TaskSummaryPage(
        items: [
          TaskSummary(
            taskId: 'task-stale-page',
            title: 'Stale page task',
            completed: false,
          ),
        ],
        nextCursor: null,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('task-choice-task-stale-page')), findsNothing);
    expect(await result, isNull);
    revision.dispose();
  });
}
