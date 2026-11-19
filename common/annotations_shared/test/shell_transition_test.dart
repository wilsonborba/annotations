// annotations#58: a route transition from a tall page to a short page has
// no layout error.
import 'package:annotations_shared/domain/services/preferences.dart';
import 'package:annotations_shared/presentation/frontend/components/scope.dart';
import 'package:annotations_shared/presentation/frontend/components/shell.dart';
import 'package:annotations_shared/presentation/frontend/components/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
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
