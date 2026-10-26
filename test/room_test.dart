import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:annotations/app.dart';
import 'package:annotations/presentation/frontend/handlers/room_handler.dart';
import 'fixtures.dart';

void main() {
  test(
    'room handler preserves a stale edit error and accepts expiry from the server',
    () async {
      var expired = false;
      final state = {
        'code': 'transfer',
        'revision': 0,
        'expires_at': DateTime.now().millisecondsSinceEpoch ~/ 1000 + 900,
        'items': [],
      };
      final service = fixtureService(
        handler: (request) async {
          if (expired) return http.Response('{"error":"expired"}', 410);
          if (request.url.path.endsWith('/items')) {
            return http.Response('{"error":"reload before editing"}', 409);
          }
          return http.Response(jsonEncode(state), 200);
        },
      );
      final handler = RoomHandler(service, 'transfer');
      addTearDown(handler.dispose);
      await handler.open();
      expect(await handler.edit('stale', id: 'id'), false);
      expect(handler.error, contains('reload'));
      expired = true;
      await handler.refresh();
      expect(handler.expired, true);
    },
  );
  testWidgets('temporary room UI opens without login', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final service = fixtureService(
      handler: (request) async => http.Response(
        jsonEncode({
          'code': 'transfer',
          'revision': 0,
          'expires_at': DateTime.now().millisecondsSinceEpoch ~/ 1000 + 900,
          'items': [],
        }),
        200,
      ),
    );
    await tester.pumpWidget(
      AnnotationsApp(service: service, initialLocation: '/v1/instant/transfer'),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('room-text')), findsOneWidget);
    expect(find.text('Choose files'), findsOneWidget);
    expect(find.text('Login'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
  testWidgets('items added by mistake can be removed', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final deleted = <String>[];
    final state = {
      'code': 'transfer',
      'revision': 1,
      'expires_at': DateTime.now().millisecondsSinceEpoch ~/ 1000 + 900,
      'items': [
        {'id': 'typo', 'kind': 'text', 'text': 'wrong note'},
      ],
    };
    final service = fixtureService(
      handler: (request) async {
        if (request.method == 'DELETE') {
          deleted.add(request.url.path);
          state['items'] = [];
        }
        return http.Response(jsonEncode(state), 200);
      },
    );
    await tester.pumpWidget(
      AnnotationsApp(service: service, initialLocation: '/v1/instant/transfer'),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('room-sheet')), findsOneWidget);
    await tester.ensureVisible(find.byKey(const Key('remove-typo')));
    await tester.tap(find.byKey(const Key('remove-typo')));
    await tester.pumpAndSettle();
    expect(deleted.single, endsWith('/instant/transfer/items/typo'));
    expect(find.text('wrong note'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
}
