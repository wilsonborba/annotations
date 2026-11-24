// The Instant room page (annotations#44): opening a free code creates the
// room and shows the shared editor without login and without Undo or Redo;
// the remaining time warns near the expiry; a lost connection shows Try
// again; an expired room shows S02 and "This room has expired".
import 'package:annotations_shared/app.dart';
import 'package:annotations_shared/dal/remote/api_adapter.dart';
import 'package:annotations_shared/domain/services/annotations_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_room_server.dart';

AnnotationsService serviceFor(FakeRoomServer server) => AnnotationsService(
  api: ApiAdapter(base: 'http://annotations.test', client: server.client()),
);

Future<void> openRoom(
  WidgetTester tester,
  FakeRoomServer server, {
  Size size = const Size(1280, 860),
}) async {
  SharedPreferences.setMockInitialValues({});
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    AnnotationsApp(
      trackingEnabled: false,
      service: serviceFor(server),
      initialLocation: '/v1/instant/${server.code}',
    ),
  );
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> closeRoom(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 1));
}

void main() {
  testWidgets('a free code creates the room and shows the shared editor '
      'without login, Undo or Redo', (tester) async {
    final server = FakeRoomServer(code: 'river-lab', exists: false);
    await openRoom(tester, server);
    expect(server.calls.take(2), [
      'GET /instant/river-lab',
      'PUT /instant/river-lab',
    ]);
    expect(find.byKey(const Key('room-code')), findsOneWidget);
    expect(find.text('river-lab'), findsOneWidget);
    expect(find.byKey(const Key('paper-status')), findsOneWidget);
    expect(find.byKey(const Key('room-state-shared')), findsOneWidget);
    expect(find.byKey(const Key('toolbar-undo')), findsNothing);
    expect(find.byKey(const Key('toolbar-redo')), findsNothing);
    expect(find.byKey(const Key('save-state-saved')), findsNothing);
    expect(find.text('Login'), findsNothing);
    expect(find.byKey(const Key('room-time')), findsOneWidget);
    await closeRoom(tester);
  });

  testWidgets('near the expiry the time shows a warning', (tester) async {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final server = FakeRoomServer(expiresAt: now + 90);
    await openRoom(tester, server);
    expect(find.byKey(const Key('room-time-warning')), findsOneWidget);
    expect(find.text('This room expires soon'), findsOneWidget);
    await closeRoom(tester);
  });

  testWidgets('a lost connection shows Try again; it reads the room again', (
    tester,
  ) async {
    final server = FakeRoomServer();
    await openRoom(tester, server);
    server.offline = true;
    await tester.pump(const Duration(seconds: 3));
    await tester.pump();
    expect(find.byKey(const Key('room-state-connectionLost')), findsOneWidget);
    expect(find.text('Connection lost'), findsOneWidget);
    server.offline = false;
    await tester.tap(find.byKey(const Key('room-retry')));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(server.calls.last, 'GET /instant/ROOM12');
    expect(find.byKey(const Key('room-state-shared')), findsOneWidget);
    await closeRoom(tester);
  });

  testWidgets('an expired room shows S02 and This room has expired', (
    tester,
  ) async {
    final server = FakeRoomServer()..expired = true;
    await openRoom(tester, server);
    expect(find.byKey(const Key('room-expired')), findsOneWidget);
    expect(find.text('This room has expired'), findsOneWidget);
    expect(find.byKey(const Key('paper-status')), findsNothing);
    await closeRoom(tester);
  });

  testWidgets('the room expires while open: the editor goes and S02 shows', (
    tester,
  ) async {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final server = FakeRoomServer(expiresAt: now + 2);
    await openRoom(tester, server);
    expect(find.byKey(const Key('paper-status')), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
    await tester.pump();
    expect(find.byKey(const Key('room-expired')), findsOneWidget);
    expect(find.byKey(const Key('paper-status')), findsNothing);
    await closeRoom(tester);
  });

  testWidgets('a phone-sized browser gets simple typed controls; every '
      'object stays visible', (tester) async {
    final server = FakeRoomServer();
    server.items['ink'] = {
      'id': 'ink',
      'kind': 'shape',
      'shape': 'rectangle',
      'color': '#DC2626FF',
      'line_width': 2,
      'opacity': 1,
      'x': 100,
      'y': 100,
      'width': 200,
      'height': 80,
    };
    server.itemRevisions['ink'] = 1;
    await openRoom(tester, server, size: const Size(390, 844));
    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('mode-switch')), findsNothing);
    expect(find.byKey(const Key('add-menu')), findsNothing);
    expect(find.byKey(const Key('paper-button')), findsNothing);
    expect(find.byKey(const Key('room-state-shared')), findsOneWidget);
    await closeRoom(tester);
  });

  testWidgets('a desktop browser gets the full editor', (tester) async {
    final server = FakeRoomServer();
    await openRoom(tester, server);
    expect(find.byKey(const Key('mode-switch')), findsOneWidget);
    expect(find.byKey(const Key('paper-button')), findsOneWidget);
    await closeRoom(tester);
  });
}
