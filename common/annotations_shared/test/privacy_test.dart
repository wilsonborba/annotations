import 'dart:async';
import 'dart:convert';
import 'package:annotations_shared/app.dart';
import 'package:annotations_shared/core/logs.dart';
import 'package:annotations_shared/core/settings.dart';
import 'package:annotations_shared/core/tracking.dart';
import 'package:annotations_shared/core/tracking_manifest.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'fixtures.dart';

/// Captures every request body that the shared transport sends.
class Gateway {
  final bodies = <String>[];
  bool online = true;
  late final transport = createTrailTransport(
    client: MockClient((request) async {
      if (!online) throw http.ClientException('offline', request.url);
      bodies.add(request.body);
      return http.Response('{}', 202);
    }),
  );
  List<Map<String, dynamic>> get events => bodies
      .map((b) => jsonDecode(b) as Map<String, dynamic>)
      .where((b) => b.containsKey('events'))
      .expand((b) => (b['events'] as List).cast<Map<String, dynamic>>())
      .toList();
  List<Map<String, dynamic>> get errors => bodies
      .map((b) => jsonDecode(b) as Map<String, dynamic>)
      .where((b) => b.containsKey('error_type'))
      .toList();
}

Future<void> drain(ScreenTrail tracker) async {
  for (var i = 0; i < 30; i++) {
    await tracker.flush();
  }
}

void main() {
  test('settings keep the shared gateway telemetry routes', () {
    const settings = Settings();
    expect(
      settings.telemetryEvents.toString(),
      'https://api.asodya.com/apps/api/v1/telemetry/events',
    );
    expect(
      settings.telemetryErrors.toString(),
      'https://api.asodya.com/apps/api/v1/telemetry/errors',
    );
    final transport = createTrailTransport(settings: settings);
    expect(transport.includeCredentials, isTrue);
    transport.close();
    final tracker = createTracker(transport: Gateway().transport);
    expect(tracker.appId, 'annotations');
    expect(tracker.recordTypedText, isTrue);
    tracker.dispose();
  });

  test('debug logs print only in development builds', () {
    final lines = <String>[];
    final previous = debugPrint;
    debugPrint = (message, {wrapWidth}) => lines.add(message ?? '');
    try {
      Settings.use(const Settings(development: false));
      logDebug('test', 'hidden');
      logInfo('test', 'shown info');
      logWarning('test', 'shown warning');
      logError('test', 'shown error');
      Settings.use(const Settings());
      logDebug('test', 'shown debug');
    } finally {
      debugPrint = previous;
      Settings.use(const Settings());
    }
    expect(lines.join('\n'), isNot(contains('hidden')));
    expect(lines.where((l) => l.contains('shown')).length, 4);
    expect(lines.first, contains('INFO annotations test: shown info'));
  });

  testWidgets('a typed note text never appears in any queued event or error', (
    tester,
  ) async {
    const note = 'My private note about the launch plan';
    const element = TrailElement(
      id: 'note.body.text',
      label: 'Note body text',
      path: 'note > body > text',
    );
    final gateway = Gateway();
    final tracker = createTracker(
      transport: gateway.transport,
      autoFlush: false,
    );
    final errors = ClientErrors(tracker, platform: 'linux');
    final controller = TextEditingController();
    await tester.pumpWidget(
      MaterialApp(
        home: ScreenTrailRoot(
          tracker: tracker,
          child: Scaffold(
            body: TrackedInput(
              element: element,
              controller: controller,
              sensitive: true,
              child: TextField(controller: controller),
            ),
          ),
        ),
      ),
    );
    await tester.enterText(find.byType(TextField), note);
    await tester.pump();
    // A failed save whose exception text contains the note.
    final reference = errors.report(
      StateError('save failed: $note'),
      StackTrace.current,
      operation: 'note.save',
    );
    // A later failure that also names the note, with the note passed again.
    errors.report(
      FormatException('bad document', note),
      null,
      operation: 'note.open',
      sensitive: [note],
    );
    await drain(tracker);
    final input = gateway.events.where((e) => e['element_id'] == element.id);
    expect(input, isNotEmpty);
    expect(
      input.every((e) => e['value'] == null && e['sensitive'] == true),
      isTrue,
    );
    expect(gateway.errors.length, 2);
    final first = gateway.errors.first['message'] as String;
    expect(first, contains('ref=$reference'));
    expect(first, contains('platform=linux'));
    expect(first, contains('operation=note.save'));
    expect(gateway.errors.first['build_version'], '1.0.0 (development)');
    expect(gateway.bodies.join(), isNot(contains(note)));
    expect(gateway.bodies.join(), isNot(contains('launch plan')));
    tracker.dispose();
    controller.dispose();
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('an Instant route records /v1/instant/:code and never the code', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    const code = 'SECRET42ROOM';
    final gateway = Gateway();
    final tracker = createTracker(
      transport: gateway.transport,
      autoFlush: false,
    );
    await tester.pumpWidget(
      AnnotationsApp(
        trackingEnabled: false,
        tracker: tracker,
        initialLocation: '/v1/instant/$code',
        service: fixtureService(
          handler: (request) async => http.Response(
            jsonEncode({'error': 'Room failed at ${request.url}'}),
            500,
            headers: {'content-type': 'application/json'},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    // The user sees the short error with its reference and Retry.
    expect(find.byKey(const Key('error-reference')), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
    await drain(tracker);
    final views = gateway.events.where((e) => e['event_type'] == 'view');
    expect(views, isNotEmpty);
    expect(
      views.every(
        (e) =>
            e['route'] == '/v1/instant/:code' &&
            e['path'] == '/v1/instant/:code',
      ),
      isTrue,
    );
    expect(gateway.errors, isNotEmpty);
    expect(gateway.errors.first['route'], '/v1/instant/:code');
    expect(
      gateway.errors.first['message'],
      contains('operation=PUT /instant/:code'),
    );
    expect(gateway.bodies.join(), isNot(contains(code)));
    await tester.pumpWidget(const SizedBox());
    tracker.dispose();
  });

  testWidgets(
    'real Instant composer and editor exclude content and reflected errors',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      const code = 'PRIVATE-ROOM-17';
      const composed = 'Private composer fragment unique';
      const preloaded = 'Preloaded private original fragment';
      const edited = 'Private edited draft fragment';
      final submitted = <String>[];
      Completer<http.Response>? pendingResponse;
      String? reflectedError;
      final gateway = Gateway();
      final tracker = createTracker(
        transport: gateway.transport,
        autoFlush: false,
      );
      final room = {
        'code': code,
        'revision': 1,
        'expires_at': DateTime.now().millisecondsSinceEpoch ~/ 1000 + 900,
        'items': [
          {'id': 'item-1', 'kind': 'text', 'text': preloaded},
        ],
      };
      final service = fixtureService(
        handler: (request) async {
          if (request.method == 'POST') {
            final text = (jsonDecode(request.body) as Map)['text'] as String;
            submitted.add(text);
            // Error bodies can echo only a fragment, or preloaded text that was
            // never registered by the tracking input listener.
            reflectedError = jsonEncode({
              'error': 'Rejected: ${text.split(' ').last} $text',
            });
            pendingResponse = Completer<http.Response>();
            return pendingResponse!.future;
          }
          return http.Response(jsonEncode(room), 200);
        },
      );
      await tester.pumpWidget(
        AnnotationsApp(
          trackingEnabled: false,
          tracker: tracker,
          service: service,
          initialLocation: '/v1/instant/$code',
        ),
      );
      await tester.pumpAndSettle();
      final composer = find.byKey(const Key('room-text'));
      await tester.enterText(composer, composed);
      await tester.pump();
      await tester.ensureVisible(find.text('Add item'));
      await tester.tap(find.text('Add item'));
      await tester.pumpAndSettle();
      pendingResponse!.complete(http.Response(reflectedError!, 422));
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(composer).controller!.text, composed);
      for (final replacement in <String?>[null, edited]) {
        await tester.ensureVisible(find.byTooltip('Edit'));
        await tester.tap(find.byTooltip('Edit'));
        await tester.pumpAndSettle();
        final field = find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(TextField),
        );
        expect(tester.widget<TextField>(field).controller!.text, preloaded);
        if (replacement != null) {
          await tester.enterText(field, replacement);
          await tester.pump();
        }
        await tester.tap(find.text('Save'));
        // Let the dialog finish its exit transition before the API responds.
        // Controller disposal during that transition is a separate existing bug.
        await tester.pumpAndSettle();
        pendingResponse!.complete(http.Response(reflectedError!, 422));
        await tester.pumpAndSettle();
      }
      expect(submitted, [composed, preloaded, edited]);
      await drain(tracker);
      for (final id in ['instant.composer.text', 'instant.edit.content']) {
        final input = gateway.events.where(
          (e) => e['element_id'] == id && e['event_type'] == 'input',
        );
        expect(input, isNotEmpty, reason: id);
        expect(
          input.every((e) => e['value'] == null && e['sensitive'] == true),
          isTrue,
        );
      }
      expect(gateway.events.any((e) => e['event_type'] == 'submit'), isTrue);
      expect(gateway.errors, hasLength(3));
      expect(
        gateway.errors.every(
          (e) => (e['message'] as String).contains('status=422'),
        ),
        isTrue,
      );
      expect(gateway.errors.every((e) => e['stack'] == ''), isTrue);
      for (final value in [code, composed, preloaded, edited, 'fragment']) {
        expect(gateway.bodies.join(), isNot(contains(value)));
      }
      await tester.pumpWidget(const SizedBox());
      gateway.transport.close();
    },
  );

  test(
    'unregistered short content and fragments never enter error reports or logs',
    () async {
      final gateway = Gateway();
      final tracker = createTracker(
        transport: gateway.transport,
        autoFlush: false,
      );
      final errors = ClientErrors(tracker, platform: 'linux');
      final logs = <String>[];
      final previous = debugPrint;
      debugPrint = (message, {wrapWidth}) => logs.add(message ?? '');
      const content = [
        'xy',
        'note-fragment',
        'ink-strokes',
        'transcription-draft',
        'file-bytes',
        'clipboard-value',
        'credential-value',
      ];
      try {
        for (final value in content) {
          // No sensitive-value registration. A supplied stack can also contain
          // user text, so exact-match redaction cannot establish privacy.
          errors.report(
            StateError(value),
            StackTrace.fromString(value),
            operation: 'note.save',
          );
        }
        await drain(tracker);
      } finally {
        debugPrint = previous;
      }
      expect(gateway.errors, hasLength(content.length));
      for (final value in content) {
        expect(gateway.bodies.join(), isNot(contains(value)));
        expect(logs.join(), isNot(contains(value)));
      }
      expect(gateway.errors.every((e) => e['stack'] == ''), isTrue);
      expect(gateway.errors.first['message'], contains('error=StateError'));
      tracker.dispose();
      gateway.transport.close();
    },
  );

  test(
    'the installed app sends after reconnect and the queue stays bounded',
    () async {
      var clock = DateTime(2026, 11, 17);
      final gateway = Gateway()..online = false;
      final tracker = createTracker(
        transport: gateway.transport,
        autoFlush: false,
        now: () => clock,
      );
      final errors = ClientErrors(tracker, platform: 'linux');
      final references = <String>[];
      final element = annotationElements['shell.theme.toggle']!;
      for (var i = 0; i < 260; i++) {
        tracker.event('click', element);
      }
      for (var i = 0; i < 25; i++) {
        // Reporting while offline returns at once and never throws.
        final reference = errors.report(
          StateError('offline $i'),
          null,
          operation: 'sync',
        );
        references.add(reference);
        expect(reference, hasLength(8));
      }
      await tracker.flush();
      expect(gateway.bodies, isEmpty);
      gateway.online = true;
      clock = clock.add(const Duration(minutes: 2));
      await drain(tracker);
      final clicks = gateway.events.where((e) => e['element_id'] == element.id);
      expect(clicks.length, 200);
      expect(gateway.errors.length, 20);
      expect(gateway.errors.first['message'], contains('ref=${references[5]}'));
      tracker.dispose();
    },
  );
}
