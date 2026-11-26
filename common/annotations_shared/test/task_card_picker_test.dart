import 'package:annotations_shared/domain/services/task_card_service.dart';
import 'package:annotations_shared/presentation/frontend/components/task_card_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

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
}
