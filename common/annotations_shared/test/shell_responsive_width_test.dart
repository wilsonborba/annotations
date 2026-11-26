import 'dart:convert';

import 'package:annotations_shared/domain/services/account_service.dart';
import 'package:annotations_shared/domain/services/preferences.dart';
import 'package:annotations_shared/presentation/frontend/components/scope.dart';
import 'package:annotations_shared/presentation/frontend/components/shell.dart';
import 'package:annotations_shared/presentation/frontend/components/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'design_goldens_test.dart' show loadAppFonts;
import 'fixtures.dart';

enum _AccountState { checking, signedOut, signedIn }

void main() {
  setUpAll(loadAppFonts);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  final matrix = <(double, _AccountState, Brightness, double)>[
    for (final width in [
      320.0,
      359.0,
      360.0,
      375.0,
      390.0,
      414.0,
      429.0,
      430.0,
      431.0,
    ])
      for (final state in _AccountState.values)
        for (final brightness in Brightness.values)
          for (final scale in [1.0, 1.3]) (width, state, brightness, scale),
    for (final width in [
      460.0,
      480.0,
      519.0,
      520.0,
      521.0,
      560.0,
      579.0,
      580.0,
      600.0,
      619.0,
      620.0,
      621.0,
      640.0,
      679.0,
      680.0,
      699.0,
      700.0,
      701.0,
      720.0,
      760.0,
      779.0,
      780.0,
      799.0,
      800.0,
      801.0,
      999.0,
    ])
      for (final state in _AccountState.values)
        for (final brightness in Brightness.values)
          (width, state, brightness, 1.3),
    for (final width in [
      1199.0,
      1200.0,
      1201.0,
      1179.0,
      1180.0,
      1280.0,
      1559.0,
      1560.0,
      1561.0,
      1440.0,
    ])
      for (final state in _AccountState.values)
        for (final brightness in Brightness.values)
          for (final scale in [1.0, 1.3]) (width, state, brightness, scale),
  ];

  for (final (width, accountState, brightness, scale) in matrix) {
    testWidgets(
      'toolbar fits ${width}px ${accountState.name} ${brightness.name} ${scale}x',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = Size(width, 1000);
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

        final client = MockClient((request) async {
          if (accountState == _AccountState.signedIn &&
              request.url.path == '/user/info/v1/') {
            return http.Response(
              jsonEncode({
                'data': {
                  'email': 'local-fixture@example.test',
                  'first_name': 'Local',
                  'last_name': 'Fixture',
                },
              }),
              200,
              headers: {'content-type': 'application/json'},
            );
          }
          return http.Response('', 200);
        });
        addTearDown(client.close);
        final account = AccountService(
          client: client,
          gateway: 'https://api.test',
          platform: SessionPlatform(
            readCookie: (name) =>
                accountState == _AccountState.signedIn && name == 'csrf'
                ? 'fixture-csrf'
                : null,
            deleteCookie: (_) {},
            origin: () => 'https://annotations.test',
            open: (_) async {},
            aes: (key, iv, data) async => data,
          ),
        );
        addTearDown(account.dispose);
        if (accountState != _AccountState.checking) await account.check();

        final preferences = Preferences();
        addTearDown(preferences.dispose);
        await tester.pumpWidget(
          AnimatedBuilder(
            animation: preferences,
            builder: (context, _) => AppScope(
              preferences: preferences,
              service: fixtureService(),
              account: account,
              child: MaterialApp.router(
                theme: appTheme(brightness),
                routerConfig: router,
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(
                    context,
                  ).copyWith(textScaler: TextScaler.linear(scale)),
                  child: child!,
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final layoutError = tester.takeException();
        expect(layoutError, isNull, reason: '$width px at ${scale}x');
        expect(find.byKey(const Key('language-switch')), findsOneWidget);
        expect(find.byKey(const Key('theme-toggle')), findsOneWidget);
        final inlineNavigation = width >= tabsMenuWidth * scale;
        expect(
          find.byKey(const Key('tabs-menu')),
          inlineNavigation ? findsNothing : findsOneWidget,
          reason: '$width px at ${scale}x',
        );

        if (accountState == _AccountState.signedOut && !inlineNavigation) {
          await tester.tap(find.byKey(const Key('tabs-menu')));
          await tester.pumpAndSettle();
          expect(find.byKey(const Key('menu-sign-in')), findsOneWidget);
          await tester.tapAt(const Offset(10, 200));
          await tester.pumpAndSettle();
        }

        final compact = width < 800;
        for (final code in ['en', 'pt-BR', 'th']) {
          if (compact) {
            await tester.tap(find.byKey(const Key('language-switch')));
            await tester.pumpAndSettle();
            await tester.tap(find.byKey(Key('compact-language-$code')));
          } else {
            await tester.tap(find.byKey(Key('language-$code')));
          }
          await tester.pumpAndSettle();
          expect(preferences.locale, code);

          final overview = switch (code) {
            'pt-BR' => 'Visão geral',
            'th' => 'ภาพรวม',
            _ => 'Overview',
          };
          if (inlineNavigation) {
            expect(find.text(overview), findsOneWidget);
          } else {
            await tester.tap(find.byKey(const Key('tabs-menu')));
            await tester.pumpAndSettle();
            expect(find.byKey(const Key('menu-tabOverview')), findsOneWidget);
            expect(find.text(overview), findsOneWidget);
            await tester.tapAt(Offset(10, tester.view.physicalSize.height / 2));
            await tester.pumpAndSettle();
          }
          expect(tester.takeException(), isNull);
        }
      },
    );
  }
}
