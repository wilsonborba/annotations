import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:annotations_shared/app.dart';
import 'package:annotations_shared/core/strings.dart';
import 'package:annotations_shared/dal/remote/fernet_token.dart';
import 'package:annotations_shared/domain/services/account_service.dart';
import 'package:annotations_shared/domain/services/my_notes_service.dart';
import 'package:annotations_shared/presentation/frontend/components/controls.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'design_goldens_test.dart' show loadAppFonts;
import 'fixtures.dart';

/// annotations#38 stage 1: the browser account, signed-in state everywhere
/// (Cortex #75, #21, #76 lessons).

const gateway = 'https://gateway.test';
const apiBase = '$gateway/apps/annotations/v1';
const key = 'AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=';

/// A fake gateway that answers like api_for_apps: the session lives in the
/// server; `/user/info/v1/` answers 403 without it; log-out needs the CSRF
/// header equal to the csrf cookie; the exchange needs the token field and
/// the registered app.
class FakeGateway {
  FakeGateway({this.alive = false, this.notes = const [], this.notesStatus});

  bool alive;
  List<Map<String, Object?>> notes;

  /// Forces the status of `/me/notes`, such as 404 like today's gateway.
  int? notesStatus;
  final cookies = <String, String>{};
  final calls = <String>[];
  final opened = <Uri>[];
  final addresses = <String>[];
  Completer<void>? holdInfo;
  Completer<void>? holdNextExchange;
  Completer<http.Response>? holdNextInfoResponse;
  Completer<http.Response>? holdNextNotesResponse;
  String email = 'ana@example.com';

  Future<http.Response> handle(http.Request r) async {
    calls.add('${r.method} ${r.url.path}');
    switch ((r.method, r.url.path)) {
      case ('GET', '/user/info/v1/'):
        final heldResponse = holdNextInfoResponse;
        holdNextInfoResponse = null;
        if (heldResponse != null) return heldResponse.future;
        await holdInfo?.future;
        return alive
            ? json({
                'data': {
                  'email': email,
                  'first_name': email.startsWith('bea') ? 'Bea' : 'Ana',
                  'last_name': 'Lima',
                },
              })
            : json({'detail': 'Missing Authentications Parameters...'}, 403);
      case ('POST', '/apps/api/v1/exchange'):
        final body = jsonDecode(r.body) as Map;
        if (body['auth_exchange_token'] != 'good' ||
            body['app'] != 'annotations') {
          return json({'message': 'Invalid exchange token'}, 400);
        }
        await holdNextExchange?.future;
        alive = true;
        cookies['csrf'] = 'csrf-1';
        return json({'message': 'Success'});
      case ('POST', '/user/sync/v1/log-out'):
        if (!alive || r.headers['X-CSRF-Token'] != cookies['csrf']) {
          return json({'detail': 'Missing Authentications Parameters...'}, 403);
        }
        alive = false;
        return json({'message': 'Logged out successfully.'});
      case ('GET', '/apps/annotations/v1/me/notes'):
        if (notesStatus != null) return json({'detail': 'x'}, notesStatus!);
        // The gateway session route: no session, 401 (api_for_apps e3bc705).
        if (!alive) return json({'detail': 'Authentication required'}, 401);
        final response = json({
          'items': notes,
          'next_cursor': null,
          'sync_cursor': '1',
        });
        final heldResponse = holdNextNotesResponse;
        holdNextNotesResponse = null;
        return heldResponse == null ? response : heldResponse.future;
    }
    return json({'detail': 'Not Found'}, 404);
  }

  static http.Response json(Object body, [int status = 200]) =>
      http.Response(jsonEncode(body), status);

  late final client = MockClient(handle);

  late final account = AccountService(
    client: client,
    gateway: gateway,
    appContextKey: key,
    authBase: 'https://auth.test',
    platform: SessionPlatform(
      readCookie: (name) => cookies[name],
      deleteCookie: cookies.remove,
      origin: () => 'https://annotations.test',
      open: (uri) async => opened.add(uri),
      aes: fakeAes,
    ),
  );
  late final myNotes = MyNotesService(client: client, apiBase: apiBase);

  int count(String call) => calls.where((c) => c == call).length;
}

/// A stand-in cipher for the VM (the browser uses Web Crypto): it keeps the
/// data readable, so the test can open the token.
Future<Uint8List> fakeAes(Uint8List key, Uint8List iv, Uint8List data) async =>
    Uint8List.fromList([for (var i = 0; i < data.length; i++) data[i] ^ 0x5A]);

FakeGateway signedIn() => FakeGateway(alive: true)..cookies['csrf'] = 'csrf-1';

Future<void> openApp(
  WidgetTester tester,
  FakeGateway g,
  String location, {
  double width = 1300,
  bool settle = true,
  Map<String, Object> prefs = const {},
}) async {
  tester.platformDispatcher.accessibilityFeaturesTestValue =
      const FakeAccessibilityFeatures(disableAnimations: true);
  addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
  SharedPreferences.setMockInitialValues(prefs);
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, 1000);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    AnnotationsApp(
      // A new app each time: a reused state would keep the old account.
      key: UniqueKey(),
      trackingEnabled: false,
      initialLocation: location,
      service: fixtureService(),
      account: g.account,
      myNotes: g.myNotes,
    ),
  );
  if (settle) await tester.pumpAndSettle();
}

String location(WidgetTester tester) => GoRouter.of(
  tester.element(find.byType(Navigator).last),
).state.uri.toString();

const landing = [
  '/v1/home',
  '/v1/home/features',
  '/v1/home/how-it-works',
  '/v1/home/engineering',
  '/v1/home/download',
];

final signInText = translate('signIn', 'en');

void main() {
  setUpAll(loadAppFonts);

  group('Signed out', () {
    testWidgets('every page shows Sign in; no cookie means no call', (
      tester,
    ) async {
      for (final width in [1300.0, 390.0]) {
        for (final page in [...landing, '/v1/menu', '/v1/instant']) {
          final g = FakeGateway();
          await openApp(tester, g, page, width: width);
          if (width < 600) {
            // A phone bar has the Sign in row in its menu.
            expect(find.byKey(const Key('bar-sign-in')), findsNothing);
            await tester.tap(find.byKey(const Key('tabs-menu')));
            await tester.pumpAndSettle();
            expect(find.byKey(const Key('menu-sign-in')), findsOneWidget);
          } else {
            expect(
              find.byKey(const Key('bar-sign-in')),
              findsOneWidget,
              reason: '$page $width',
            );
          }
          expect(find.byKey(const Key('account-avatar')), findsNothing);
          // No csrf cookie: there is no session to ask about.
          expect(g.calls, isEmpty, reason: page);
        }
      }
    });

    testWidgets('Sign in opens auth_apps with a Fernet app context', (
      tester,
    ) async {
      final g = FakeGateway();
      await openApp(tester, g, '/v1/home/features');
      await tester.tap(find.byKey(const Key('bar-sign-in')));
      await tester.pumpAndSettle();
      expect(g.opened, hasLength(1));
      final uri = g.opened.single;
      expect(uri.origin, 'https://auth.test');
      expect(uri.path, '/login');
      final token = base64Url.decode(uri.queryParameters['app_context']!);
      // Fernet: version, time, IV, cipher text, HMAC-SHA256 of the rest.
      expect(token.first, 0x80);
      final raw = base64Url.decode(key);
      final mac = Hmac(
        sha256,
        raw.sublist(0, 16),
      ).convert(token.sublist(0, token.length - 32)).bytes;
      expect(token.sublist(token.length - 32), mac);
      final cipher = token.sublist(25, token.length - 32);
      final context =
          jsonDecode(utf8.decode([for (final b in cipher) b ^ 0x5A])) as Map;
      expect(context['name'], 'Annotations');
      expect(context['url_app'], 'https://annotations.test');
      // The page to come back to is kept for after the login.
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('annotations.after_login'), '/v1/home/features');
    });

    testWidgets('the hero offers Sign in', (tester) async {
      final g = FakeGateway();
      await openApp(tester, g, '/v1/home');
      expect(find.byKey(const Key('overview-sign-in')), findsOneWidget);
      expect(find.byKey(const Key('overview-my-notes')), findsNothing);
    });
  });

  group('Signed in', () {
    testWidgets('every page shows the avatar and no Sign in anywhere', (
      tester,
    ) async {
      for (final width in [1300.0, 390.0]) {
        for (final page in [...landing, '/v1/menu', '/v1/instant']) {
          final g = signedIn();
          await openApp(tester, g, page, width: width);
          expect(
            find.byKey(const Key('account-avatar')),
            findsOneWidget,
            reason: '$page $width',
          );
          // No Sign in action anywhere (How it works may name the step).
          expect(
            find.ancestor(
              of: find.text(signInText),
              matching: find.byWidgetPredicate(
                (w) => w is AppButton || w is MenuItemButton,
              ),
            ),
            findsNothing,
            reason: '$page $width',
          );
          for (final key in ['bar-sign-in', 'overview-sign-in']) {
            expect(find.byKey(Key(key)), findsNothing, reason: '$page $key');
          }
          expect(g.count('GET /user/info/v1/'), 1);
        }
      }
    });

    testWidgets('the menu has the email, My notes and Log out', (tester) async {
      final g = signedIn();
      await openApp(tester, g, '/v1/home');
      await tester.tap(find.byKey(const Key('account-avatar')));
      await tester.pumpAndSettle();
      expect(find.text('ana@example.com'), findsOneWidget);
      expect(find.text('Ana Lima'), findsOneWidget);
      await tester.tap(find.byKey(const Key('account-my-notes')));
      await tester.pumpAndSettle();
      expect(location(tester), '/v1/me/notes');
      expect(g.opened, isEmpty);
    });

    testWidgets('the hero action opens My notes, never a login', (
      tester,
    ) async {
      final g = signedIn();
      await openApp(tester, g, '/v1/home');
      expect(find.byKey(const Key('overview-sign-in')), findsNothing);
      expect(
        find.descendant(
          of: find.byKey(const Key('overview-my-notes')),
          matching: find.text(translate('myNotes', 'en')),
        ),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('overview-my-notes')));
      await tester.pumpAndSettle();
      expect(location(tester), '/v1/me/notes');
      expect(g.opened, isEmpty);
    });

    testWidgets('while the check runs neither state shows', (tester) async {
      final g = signedIn()..holdInfo = Completer();
      await openApp(tester, g, '/v1/home', settle: false);
      await tester.pump();
      expect(find.byKey(const Key('account-checking')), findsOneWidget);
      expect(find.byKey(const Key('bar-sign-in')), findsNothing);
      expect(find.byKey(const Key('overview-sign-in')), findsNothing);
      g.holdInfo!.complete();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('account-avatar')), findsOneWidget);
    });

    testWidgets('Log out ends the session with the CSRF header', (
      tester,
    ) async {
      final g = signedIn();
      await openApp(tester, g, '/v1/me/notes');
      await tester.tap(find.byKey(const Key('account-avatar')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('account-log-out')));
      await tester.pumpAndSettle();
      expect(g.count('POST /user/sync/v1/log-out'), 1);
      expect(g.alive, isFalse, reason: 'the gateway accepted the log-out');
      expect(g.cookies, isEmpty);
      expect(find.byKey(const Key('bar-sign-in')), findsOneWidget);
      // A private page has nothing to show signed out.
      expect(location(tester), '/v1/home');
      // Public reading keeps working.
      await tester.tap(find.byKey(const Key('overview-browse')));
      await tester.pumpAndSettle();
      expect(location(tester), '/v1/menu');
    });

    test(
      'a late successful identity response cannot undo browser logout',
      () async {
        final g = signedIn();
        final delayed = Completer<http.Response>();
        g.holdNextInfoResponse = delayed;

        final checking = g.account.check();
        await Future<void>.delayed(Duration.zero);
        await g.account.logOut();
        expect(g.cookies, isEmpty);
        expect(g.account.signedIn, isFalse);

        delayed.complete(
          FakeGateway.json({
            'data': {
              'email': 'ana@example.com',
              'first_name': 'Ana',
              'last_name': 'Lima',
            },
          }),
        );
        await checking;

        expect(g.account.signedIn, isFalse);
        expect(g.account.email, isEmpty);
        expect(g.cookies, isEmpty);
      },
    );

    test('a replaced CSRF session starts a fresh identity check', () async {
      final g = signedIn();
      final oldSession = g.account.captureSessionGuard();
      final delayed = Completer<http.Response>();
      g.holdNextInfoResponse = delayed;
      final checkA = g.account.check();
      await Future<void>.delayed(Duration.zero);

      g.cookies['csrf'] = 'csrf-b';
      g.email = 'bea@example.com';
      final delayedB = Completer<http.Response>();
      g.holdNextInfoResponse = delayedB;
      final checkB = g.account.check();
      await Future<void>.delayed(Duration.zero);

      delayed.complete(FakeGateway.json({'detail': 'old A session'}, 403));
      await checkA;
      expect(g.account.status, AccountStatus.checking);
      expect(identical(g.account.check(), checkB), isTrue);
      expect(g.count('GET /user/info/v1/'), 2);

      delayedB.complete(
        FakeGateway.json({
          'data': {
            'email': 'bea@example.com',
            'first_name': 'Bea',
            'last_name': 'Lima',
          },
        }),
      );
      await checkB;
      expect(g.account.signedIn, isTrue);
      expect(g.account.email, 'bea@example.com');
      expect(g.cookies['csrf'], 'csrf-b');
      g.account.expireIfCurrent(oldSession);
      expect(g.account.signedIn, isTrue, reason: 'a stale private refusal');
    });

    test(
      'a new cookie is not current until its identity is verified',
      () async {
        final g = signedIn();
        await g.account.check();
        expect(g.account.signedIn, isTrue);
        expect(
          g.account.isCurrentSession(g.account.captureSessionGuard()),
          isTrue,
        );

        g.cookies['csrf'] = 'csrf-b';
        final unverified = g.account.captureSessionGuard();
        expect(
          g.account.isCurrentSession(unverified),
          isFalse,
          reason: 'signed-in identity A must remain bound to its verified CSRF',
        );

        await g.account.check();
        expect(g.account.signedIn, isTrue);
        expect(
          g.account.isCurrentSession(g.account.captureSessionGuard()),
          isTrue,
        );
      },
    );

    test(
      'logout waits for a pending exchange and revokes its new session',
      () async {
        final g = FakeGateway();
        final exchangeGate = Completer<void>();
        g.holdNextExchange = exchangeGate;

        final exchanging = g.account.exchange('good');
        await Future<void>.delayed(Duration.zero);
        final loggingOut = g.account.logOut();
        expect(g.account.signedIn, isFalse);

        exchangeGate.complete();
        expect(await exchanging, isFalse);
        await loggingOut;

        expect(g.count('POST /user/sync/v1/log-out'), 1);
        expect(g.alive, isFalse);
        expect(g.cookies, isEmpty);
        expect(g.account.signedIn, isFalse);
      },
    );

    test('the state is never a stored flag', () async {
      SharedPreferences.setMockInitialValues({});
      final g = signedIn();
      await g.account.check();
      expect(g.account.signedIn, isTrue);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getKeys(), isEmpty);
      // Same cookie, but the server ended the session: signed out.
      g.alive = false;
      await g.account.check();
      expect(g.account.signedIn, isFalse);
    });
  });

  group('Dead session', () {
    testWidgets('a refused check signs out once: no loop, no login', (
      tester,
    ) async {
      for (final page in [...landing, '/v1/me/notes']) {
        final g = FakeGateway()..cookies['csrf'] = 'old';
        await openApp(tester, g, page);
        expect(find.byKey(const Key('bar-sign-in')), findsOneWidget);
        expect(g.cookies, isEmpty, reason: 'the dead cookie goes');
        expect(g.count('GET /user/info/v1/'), 1, reason: page);
        expect(g.opened, isEmpty, reason: 'no automatic login');
        expect(find.byKey(const Key('my-notes-error')), findsNothing);
      }
    });

    testWidgets('a session that dies on My notes signs out once', (
      tester,
    ) async {
      final g = signedIn();
      await openApp(tester, g, '/v1/home');
      g.alive = false;
      await tester.tap(find.byKey(const Key('overview-my-notes')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('my-notes-signed-out')), findsOneWidget);
      expect(find.byKey(const Key('bar-sign-in')), findsOneWidget);
      expect(g.count('GET /apps/annotations/v1/me/notes'), 1);
      expect(g.opened, isEmpty);
    });
  });

  group('Return from auth_apps', () {
    testWidgets('the token is redeemed once and the kept page opens', (
      tester,
    ) async {
      final g = FakeGateway();
      await openApp(
        tester,
        g,
        '/sync?auth_exchange_token=good',
        prefs: {'annotations.after_login': '/v1/home/download'},
      );
      expect(g.count('POST /apps/api/v1/exchange'), 1);
      expect(location(tester), '/v1/home/download');
      expect(find.byKey(const Key('account-avatar')), findsOneWidget);
    });

    testWidgets('a bad token shows the error with Retry', (tester) async {
      final g = FakeGateway();
      await openApp(tester, g, '/sync?auth_exchange_token=bad');
      expect(find.byKey(const Key('sync-failed')), findsOneWidget);
      expect(g.count('POST /apps/api/v1/exchange'), 1);
      await tester.tap(find.byKey(const Key('sync-retry')));
      await tester.pumpAndSettle();
      expect(g.opened, hasLength(1));
    });

    test('only internal pages come back after a login', () {
      expect(AccountService.safeNext('/v1/home'), '/v1/home');
      for (final bad in [
        'https://evil.test/v1/x',
        '//evil.test',
        '/v1/../x',
        'javascript:alert(1)',
        null,
      ]) {
        expect(AccountService.safeNext(bad), '/v1/me/notes', reason: bad);
      }
    });
  });

  group('My notes', () {
    testWidgets('lists the notes read only, Untitled until named', (
      tester,
    ) async {
      final g = signedIn()
        ..notes = [
          {
            'note_id': 'n1',
            'title': 'Biology',
            'updated_at': 1794996000,
            'published': {'slug': 'bio'},
          },
          {
            'note_id': 'n2',
            'title': null,
            'updated_at': 1794880000,
            'published': null,
          },
        ];
      await openApp(tester, g, '/v1/me/notes');
      expect(find.text('Biology'), findsOneWidget);
      expect(find.text(translate('untitledNote', 'en')), findsOneWidget);
      expect(find.text(translate('notePublished', 'en')), findsOneWidget);
      expect(find.text(translate('notePrivate', 'en')), findsOneWidget);
      expect(find.text('2026-11-18'), findsOneWidget);
      expect(find.byType(TextField), findsNothing, reason: 'read only');
    });

    testWidgets('a failed load shows the error with Retry', (tester) async {
      // A server failure: the error state with Retry, still signed in.
      final g = signedIn()..notesStatus = 500;
      await openApp(tester, g, '/v1/me/notes');
      expect(find.byKey(const Key('my-notes-error')), findsOneWidget);
      expect(find.byKey(const Key('account-avatar')), findsOneWidget);
      g.notesStatus = null;
      await tester.tap(find.text(translate('retry', 'en')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('my-notes-empty')), findsOneWidget);
    });

    testWidgets('late private notes from the replaced session stay hidden', (
      tester,
    ) async {
      final g = signedIn()
        ..notes = [
          {
            'note_id': 'private-a',
            'title': 'A private note',
            'updated_at': 1794996000,
            'published': null,
          },
        ];
      final delayed = Completer<http.Response>();
      g.holdNextNotesResponse = delayed;
      await openApp(tester, g, '/v1/me/notes', settle: false);
      await tester.pump();
      await tester.idle();
      await tester.pump();
      expect(g.count('GET /apps/annotations/v1/me/notes'), 1);
      expect(find.byKey(const Key('my-notes-loading')), findsOneWidget);

      g.cookies['csrf'] = 'csrf-b';
      g.email = 'bea@example.com';
      g.notes = [
        {
          'note_id': 'private-b',
          'title': 'B private note',
          'updated_at': 1794996000,
          'published': null,
        },
      ];
      delayed.complete(
        FakeGateway.json({
          'items': [
            {
              'note_id': 'private-a',
              'title': 'A private note',
              'updated_at': 1794996000,
              'published': null,
            },
          ],
          'next_cursor': null,
          'sync_cursor': 'old-a',
        }),
      );
      await tester.pump();
      expect(find.text('A private note'), findsNothing);
      await tester.pumpAndSettle();
      expect(find.text('B private note'), findsOneWidget);
      expect(find.text('A private note'), findsNothing);
    });

    testWidgets('old rendered notes stay hidden while the new session loads', (
      tester,
    ) async {
      final g = signedIn()
        ..notes = [
          {
            'note_id': 'private-a',
            'title': 'A private note',
            'updated_at': 1794996000,
            'published': null,
          },
        ];
      await openApp(tester, g, '/v1/me/notes');
      expect(find.text('A private note'), findsOneWidget);

      final delayedB = Completer<http.Response>();
      g.cookies['csrf'] = 'csrf-b';
      g.email = 'bea@example.com';
      g.notes = [
        {
          'note_id': 'private-b',
          'title': 'B private note',
          'updated_at': 1794996000,
          'published': null,
        },
      ];
      g.holdNextNotesResponse = delayedB;
      await g.account.check();
      await tester.pump();

      expect(find.byKey(const Key('my-notes-loading')), findsOneWidget);
      expect(find.text('A private note'), findsNothing);
      delayedB.complete(
        FakeGateway.json({
          'items': g.notes,
          'next_cursor': null,
          'sync_cursor': 'new-b',
        }),
      );
      await tester.pumpAndSettle();
      expect(find.text('B private note'), findsOneWidget);
      expect(find.text('A private note'), findsNothing);
    });

    testWidgets('signed out it asks to sign in', (tester) async {
      final g = FakeGateway();
      await openApp(tester, g, '/v1/me/notes');
      expect(find.byKey(const Key('my-notes-signed-out')), findsOneWidget);
      expect(g.calls, isEmpty);
    });
  });

  test('the Fernet token time is big-endian seconds', () async {
    final token = await fernetEncrypt(
      key,
      'x',
      aes: fakeAes,
      now: DateTime.fromMillisecondsSinceEpoch(1794996000 * 1000),
      iv: Uint8List(16),
    );
    final raw = base64Url.decode(token);
    final time = ByteData.sublistView(Uint8List.fromList(raw.sublist(1, 9)));
    expect(time.getUint32(0) * 0x100000000 + time.getUint32(4), 1794996000);
  });
}
