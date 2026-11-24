// annotations#58: a route transition from a tall page to a short page has
// no layout error.
import 'package:annotations_shared/domain/services/account_service.dart';
import 'package:annotations_shared/domain/services/preferences.dart';
import 'package:annotations_shared/presentation/frontend/components/scope.dart';
import 'package:annotations_shared/presentation/frontend/components/shell.dart';
import 'package:annotations_shared/presentation/frontend/components/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

class _Tall extends StatelessWidget {
  const _Tall();
  @override
  Widget build(BuildContext context) => Column(
    children: [
      for (var i = 0; i < 30; i++) SizedBox(height: 60, child: Text('Row $i')),
      TextButton(
        key: const Key('to-short'),
        onPressed: () => context.go('/short'),
        child: const Text('Short'),
      ),
    ],
  );
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('narrow toolbar respects enlarged text without overflow', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    addTearDown(semantics.dispose);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 1000);
    addTearDown(tester.view.reset);
    final router = GoRouter(
      initialLocation: '/home',
      routes: [
        ShellRoute(
          builder: (_, _, child) => PageShell(child: child),
          routes: [
            GoRoute(
              path: '/home',
              builder: (_, _) => const ShellPage(
                child: SizedBox(height: 80, child: Text('Home')),
              ),
            ),
          ],
        ),
      ],
    );
    addTearDown(router.dispose);
    final client = MockClient((_) async => http.Response('', 200));
    addTearDown(client.close);
    final account = AccountService(
      client: client,
      gateway: 'https://api.test',
      platform: SessionPlatform(
        readCookie: (_) => null,
        deleteCookie: (_) {},
        origin: () => 'https://annotations.test',
        open: (_) async {},
        aes: (key, iv, data) async => data,
      ),
    );
    addTearDown(account.dispose);
    final preferences = Preferences();
    addTearDown(preferences.dispose);
    await tester.pumpWidget(
      AppScope(
        preferences: preferences,
        service: fixtureService(),
        account: account,
        child: MaterialApp.router(
          theme: appTheme(Brightness.light),
          routerConfig: router,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(1.3)),
            child: child!,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('language-switch')), findsOneWidget);
    expect(find.byKey(const Key('theme-toggle')), findsOneWidget);
    expect(find.byKey(const Key('tabs-menu')), findsOneWidget);
    expect(
      tester
          .getSemantics(find.byKey(const Key('language-switch')))
          .getSemanticsData()
          .hasAction(SemanticsAction.tap),
      isTrue,
    );
    for (final code in ['en', 'pt-BR', 'th']) {
      await tester.tap(find.byKey(const Key('language-switch')));
      await tester.pumpAndSettle();
      final item = find.byKey(Key('compact-language-$code'));
      expect(item, findsOneWidget);
      await tester.tap(item);
      await tester.pumpAndSettle();
      expect(preferences.locale, code);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('tall page to short page and back without overflow', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(800, 600);
    addTearDown(tester.view.reset);
    final router = GoRouter(
      initialLocation: '/tall',
      routes: [
        ShellRoute(
          builder: (_, _, child) => PageShell(child: child),
          routes: [
            GoRoute(
              path: '/tall',
              builder: (_, _) => const ShellPage(child: _Tall()),
            ),
            GoRoute(
              path: '/short',
              builder: (_, _) => const ShellPage(
                child: SizedBox(height: 80, child: Text('Short page')),
              ),
            ),
          ],
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      AppScope(
        preferences: Preferences(),
        service: fixtureService(),
        child: MaterialApp.router(
          theme: appTheme(Brightness.light),
          routerConfig: router,
        ),
      ),
    );
    await tester.pumpAndSettle();
    router.go('/short');
    // Every frame of the transition.
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      expect(tester.takeException(), isNull);
    }
    expect(find.text('Short page'), findsOneWidget);
    router.go('/tall');
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      expect(tester.takeException(), isNull);
    }
    expect(find.text('Row 0'), findsOneWidget);
  });
}
