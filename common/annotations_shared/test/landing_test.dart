import 'dart:convert';

import 'package:annotations_shared/app.dart';
import 'package:annotations_shared/core/landing_settings.dart';
import 'package:annotations_shared/core/landing_strings.dart';
import 'package:annotations_shared/core/strings.dart';
import 'package:annotations_shared/domain/services/annotations_service.dart';
import 'package:annotations_shared/domain/services/preferences.dart';
import 'package:annotations_shared/presentation/frontend/components/controls.dart';
import 'package:annotations_shared/presentation/frontend/components/scope.dart';
import 'package:annotations_shared/presentation/frontend/components/shell.dart';
import 'package:annotations_shared/presentation/frontend/components/sketch_diagram.dart';
import 'package:annotations_shared/presentation/frontend/components/theme.dart';
import 'package:annotations_shared/presentation/frontend/handlers/landing_handler.dart';
import 'package:annotations_shared/presentation/frontend/widgets/landing/download_page.dart';
import 'package:annotations_shared/presentation/frontend/widgets/landing/features_page.dart';
import 'package:annotations_shared/presentation/frontend/widgets/landing/landing_blocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'design_goldens_test.dart' show loadAppFonts;
import 'fixtures.dart';

/// The landing pages and their images (annotations#53, H6 sections 3, 4).
const pages = {
  '/v1/home': [
    'O01',
    'O02',
    'O03',
    'O04',
    'O05',
    'O06',
    'O07',
    'O08',
    'O09',
    'O10',
  ],
  '/v1/home/features': [
    'F01', 'F02', 'F03', 'F04', 'F05', 'F06', 'F16', //
    'F07', 'F08', 'F09', 'F11', 'F12', 'F13', 'F14', 'F15',
  ],
  '/v1/home/how-it-works': [
    'H01',
    'H02',
    'H03',
    'H04',
    'H05',
    'H06',
    'H07',
    'H08',
  ],
  '/v1/home/engineering': ['E01', 'E02', 'E03'],
  '/v1/home/download': ['D01', 'D02', 'D03'],
};

Future<void> open(
  WidgetTester tester,
  String location, {
  double width = 1300,
  String locale = 'en',
  AnnotationsService? service,
}) async {
  SharedPreferences.setMockInitialValues({'annotations.locale': locale});
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, 1000);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    AnnotationsApp(
      // A new app per call: the router starts at [location] again.
      key: UniqueKey(),
      trackingEnabled: false,
      initialLocation: location,
      service: service ?? fixtureService(),
    ),
  );
  await tester.pumpAndSettle();
}

/// Every text on the screen, for wording and privacy checks.
List<String> texts(WidgetTester tester) => [
  for (final element in find.byType(Text).evaluate())
    (element.widget as Text).data ??
        (element.widget as Text).textSpan?.toPlainText() ??
        '',
  for (final element in find.byType(SelectableText).evaluate())
    (element.widget as SelectableText).data ?? '',
];

void main() {
  setUpAll(loadAppFonts);

  testWidgets('/ redirects to the Overview and every tab opens its own page', (
    tester,
  ) async {
    await open(tester, '/');
    expect(find.text(translate('overviewTitle', 'en')), findsOneWidget);
    for (final (route, key, _) in landingTabs) {
      await tester.tap(find.byKey(Key('tab-$key')));
      await tester.pumpAndSettle();
      final tab = tester.widget<ShellTab>(find.byKey(Key('tab-$key')));
      expect(tab.selected, isTrue, reason: route);
      // Only the current tab is selected.
      expect(
        tester
            .widgetList<ShellTab>(find.byType(ShellTab))
            .where((t) => t.selected)
            .length,
        1,
      );
    }
    // The logo goes home from any page.
    await tester.tap(find.byKey(const Key('brand-home')));
    await tester.pumpAndSettle();
    expect(find.text(translate('overviewTitle', 'en')), findsOneWidget);
  });

  testWidgets('the tabs go into one menu at 1000 px and below', (tester) async {
    await open(tester, '/v1/home/features', width: 1001);
    expect(find.byType(ShellTab), findsNWidgets(5));
    expect(find.byKey(const Key('tabs-menu')), findsNothing);
    expect(find.byKey(const Key('bar-notes')), findsOneWidget);
    expect(find.byKey(const Key('bar-instant')), findsOneWidget);

    await open(tester, '/v1/home/features', width: 1000);
    expect(find.byType(ShellTab), findsNothing);
    expect(find.byKey(const Key('bar-notes')), findsNothing);
    await tester.tap(find.byKey(const Key('tabs-menu')));
    await tester.pumpAndSettle();
    for (final key in [
      for (final (_, key, _) in landingTabs) key,
      'barNotes',
      'barInstant',
    ]) {
      expect(find.byKey(Key('menu-$key')), findsOneWidget, reason: key);
    }
    await tester.tap(find.byKey(const Key('menu-tabDownload')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('platform-iosIpados')), findsOneWidget);
  });

  testWidgets('the window never overflows at 390, 768, 1001 and 1300 px', (
    tester,
  ) async {
    final unbreakable = <String>{};
    for (final locale in ['en', 'pt-BR', 'th']) {
      for (final width in [390.0, 768.0, 1001.0, 1300.0]) {
        for (final route in pages.keys) {
          await open(tester, route, width: width, locale: locale);
          expect(
            tester.takeException(),
            isNull,
            reason: '$route $width $locale',
          );
          // No text has an unbreakable run wider than its box (Thai has no
          // spaces between words, so a long run cannot wrap).
          for (final paragraph in tester.renderObjectList<RenderParagraph>(
            find.byType(RichText),
          )) {
            if (paragraph.computeMinIntrinsicWidth(double.infinity) >
                paragraph.size.width + 0.5) {
              unbreakable.add(
                '$width $locale: ${paragraph.text.toPlainText()}',
              );
            }
          }
        }
      }
    }
    expect(unbreakable, isEmpty);
  });

  testWidgets('each landing image is at its mapped page', (tester) async {
    for (final MapEntry(key: route, value: ids) in pages.entries) {
      await open(tester, route);
      for (final id in ids) {
        expect(find.byKey(Key('image-$id')), findsOneWidget, reason: id);
      }
      // No image of another page.
      for (final other in landingImages.keys.where((i) => !ids.contains(i))) {
        expect(find.byKey(Key('image-$other')), findsNothing, reason: other);
      }
    }
  });

  testWidgets('the state images sit above their messages', (tester) async {
    await open(
      tester,
      '/v1/menu/wilson/private-note',
      service: fixtureService(handler: (_) async => http.Response('{}', 404)),
    );
    final s01 = tester.getTopLeft(find.byKey(const Key('image-S01')));
    expect(
      s01.dy,
      lessThan(tester.getTopLeft(find.byKey(const Key('not-found'))).dy),
    );

    await open(tester, '/v1/menu');
    final s03 = tester.getTopLeft(find.byKey(const Key('image-S03')));
    expect(
      s03.dy,
      lessThan(tester.getTopLeft(find.byKey(const Key('no-results'))).dy),
    );

    // The room opens, then the server says it expired at the next refresh.
    var expired = false;
    await open(
      tester,
      '/v1/instant/transfer',
      service: fixtureService(
        handler: (_) async => expired
            ? http.Response('{"error":"expired"}', 410)
            : http.Response(
                jsonEncode({
                  'code': 'transfer',
                  'revision': 0,
                  'expires_at':
                      DateTime.now().millisecondsSinceEpoch ~/ 1000 + 900,
                  'items': [],
                }),
                200,
              ),
      ),
    );
    expired = true;
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
    final s02 = tester.getTopLeft(find.byKey(const Key('image-S02')));
    expect(
      s02.dy,
      lessThan(tester.getTopLeft(find.byKey(const Key('room-expired'))).dy),
    );
  });

  testWidgets('feature rows alternate sides; each group starts on the right', (
    tester,
  ) async {
    await open(tester, '/v1/home/features');
    const handler = LandingHandler();
    for (final group in handler.groups) {
      for (final (i, row) in handler.rows(group).indexed) {
        final side = i.isEven ? 'right' : 'left';
        expect(find.byKey(Key('row-${row.image}-$side')), findsOneWidget);
        // The row title; the top bar also has an "Instant" text.
        final text = tester.getCenter(
          find
              .descendant(
                of: find.byKey(Key('row-${row.image}-$side')),
                matching: find.text(
                  translate('feature${row.image}Title', 'en'),
                ),
              )
              .first,
        );
        final image = tester.getCenter(find.byKey(Key('image-${row.image}')));
        expect(text.dx < image.dx, i.isEven, reason: row.image);
      }
    }
    // Each feature says what it needs.
    expect(
      find.descendant(
        of: find.byKey(const Key('needs-F14')),
        matching: find.text('Needs internet, no login'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const Key('needs-F08')),
        matching: find.text('Needs internet and sign-in'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const Key('needs-F01')),
        matching: find.text('Works offline, no login'),
      ),
      findsOneWidget,
    );
  });

  test('a feature outside the release is removed with its image', () {
    // Handwriting to text waits for the model release (transcription off).
    const off = LandingHandler(transcription: false);
    expect(
      off.rows(FeatureGroup.study).map((r) => r.image),
      isNot(contains('F10')),
    );
    const on = LandingHandler(transcription: true);
    expect(on.rows(FeatureGroup.study).map((r) => r.image), contains('F10'));
    // Every row of the page has its image and both strings.
    for (final row in landingFeatures) {
      expect(landingImages.containsKey(row.image), isTrue);
      expect(landingStrings.containsKey('feature${row.image}Title'), isTrue);
      expect(landingStrings.containsKey('feature${row.image}Text'), isTrue);
    }
  });

  testWidgets('the release switch removes the F10 row and its image', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1300, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    Future<void> pump(bool transcription) async {
      SharedPreferences.setMockInitialValues({});
      await tester.pumpWidget(
        AppScope(
          service: fixtureService(),
          preferences: Preferences(),
          child: MaterialApp(
            theme: appTheme(Brightness.light),
            home: Scaffold(
              body: SingleChildScrollView(
                child: FeaturesPage(
                  handler: LandingHandler(transcription: transcription),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    await pump(false);
    expect(find.byKey(const Key('image-F10')), findsNothing);
    await pump(true);
    expect(find.byKey(const Key('image-F10')), findsOneWidget);
  });

  testWidgets('on a phone the text comes first and the image below it', (
    tester,
  ) async {
    await open(tester, '/v1/home/engineering', width: 390);
    final title = tester.getTopLeft(
      find.text(translate('engSourceTitle', 'en')),
    );
    final image = tester.getTopLeft(find.byKey(const Key('image-E02')));
    expect(image.dy, greaterThan(title.dy));
    // Full width: the image spans the content column.
    expect(tester.getSize(find.byKey(const Key('image-E02'))).width, 350);
  });

  testWidgets('one strong action: Download is the only primary button', (
    tester,
  ) async {
    await open(tester, '/v1/home');
    await tester.tap(find.byKey(const Key('overview-download')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('platform-mac')), findsOneWidget);
    await open(tester, '/v1/home');
    await tester.tap(find.byKey(const Key('overview-browse')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('no-results')), findsOneWidget);
  });

  testWidgets('training notice links Terms and Privacy on two pages', (
    tester,
  ) async {
    for (final route in ['/v1/home', '/v1/home/how-it-works']) {
      await open(tester, route);
      expect(find.byKey(const Key('training-notice')), findsOneWidget);
      expect(
        tester.widget<TextLink>(find.byKey(const Key('notice-terms'))).url,
        'https://asodya.com/terms-of-service',
      );
      expect(
        tester.widget<TextLink>(find.byKey(const Key('notice-privacy'))).url,
        'https://asodya.com/privacy-policy',
      );
      expect(find.text(translate('noticeText', 'en')), findsOneWidget);
    }
  });

  testWidgets('the footer has the H6 links and the build version', (
    tester,
  ) async {
    await open(tester, '/v1/home/engineering');
    for (final url in [
      'https://asodya.com',
      'https://reports.asodya.com',
      'https://certifications.asodya.com',
      'https://cortex.asodya.com',
      'https://api.asodya.com/docs',
      'https://asodya.com/terms-of-service',
      'https://asodya.com/privacy-policy',
      for (final repo in LandingSettings.repos) repo.url,
    ]) {
      expect(
        find.descendant(
          of: find.byKey(const Key('footer')),
          matching: find.byKey(Key('footer-$url')),
        ),
        findsOneWidget,
        reason: url,
      );
    }
    expect(find.byKey(const Key('footer-build')), findsOneWidget);
    // The footer lines up with the page content, not centered narrower.
    expect(
      tester.getTopLeft(find.byKey(const Key('footer-content'))).dx,
      tester.getTopLeft(find.byKey(const Key('image-E02'))).dx,
    );
    // The public repositories of H6 section 3 point 11; screen_trail is the
    // public tracking package.
    expect(LandingSettings.repos.map((r) => r.name), [
      'annotations',
      'annotations_api',
      'api_for_apps',
      'fsm',
      'reports',
      'certifications',
      'cortex',
      'screen_trail',
    ]);
  });

  testWidgets('each diagram part links to its repository at a tag', (
    tester,
  ) async {
    final opened = <String>[];
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(1300, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      AppScope(
        service: fixtureService(),
        preferences: Preferences(),
        child: MaterialApp(
          theme: appTheme(Brightness.light),
          home: Scaffold(
            body: SketchDiagram(
              name: 'architecture',
              stages: architectureStages,
              onOpen: (repo) => opened.add(repo.url),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    for (final part in architectureStages.expand((s) => s)) {
      await tester.tap(find.byKey(Key('diagram-architecture-${part.label}')));
    }
    expect(opened, [
      for (final part in architectureStages.expand((s) => s)) part.repo!.url,
    ]);
    for (final url in opened) {
      expect(
        url,
        matches(
          RegExp(
            r'^https://github\.com/wilsonborba/[a-z_]+/tree/v\d+\.\d+\.\d+$',
          ),
        ),
      );
    }
    // The visitor sees a diagram, not source code.
    expect(find.byType(CustomPaint), findsWidgets);
  });

  testWidgets('download cards: status per platform and the copy commands', (
    tester,
  ) async {
    await open(tester, '/v1/home/download');
    expect(
      tester.widget<Text>(find.byKey(const Key('status-iosIpados'))).data,
      'Not available to the public yet.',
    );
    for (final p in ['mac', 'linux', 'android']) {
      expect(
        tester.widget<Text>(find.byKey(Key('status-$p'))).data,
        'No public release yet.',
      );
    }
    final copied = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied.add((call.arguments as Map)['text'] as String);
        }
        return null;
      },
    );
    await tester.tap(
      find.descendant(
        of: find.byKey(const Key('source-command')),
        matching: find.byType(AppIconButton),
      ),
    );
    await tester.pumpAndSettle();
    expect(copied, [LandingSettings.cloneCommand]);
  });

  testWidgets('a released card shows version, date, checksum and command', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(1300, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      AppScope(
        service: fixtureService(),
        preferences: Preferences(),
        child: MaterialApp(
          theme: appTheme(Brightness.light),
          home: const Scaffold(
            body: SingleChildScrollView(
              child: DownloadPage(
                releases: {
                  DownloadPlatform.linux: PlatformRelease(
                    version: '2.0.0',
                    date: '2026-12-01',
                    checksum: 'abc123',
                    installCommand: 'sh install.sh',
                  ),
                },
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final card = find.byKey(const Key('platform-linux'));
    for (final line in [
      'Version: 2.0.0',
      'Date: 2026-12-01',
      'SHA-256: abc123',
      'sh install.sh',
    ]) {
      expect(
        find.descendant(of: card, matching: find.text(line)),
        findsOneWidget,
        reason: line,
      );
    }
    expect(
      tester.widget<Text>(find.byKey(const Key('status-linux'))).data,
      'Available',
    );
    expect(
      tester.widget<Text>(find.byKey(const Key('status-mac'))).data,
      'No public release yet.',
    );
  });

  testWidgets('no page shows private or internal names', (tester) async {
    final forbidden = RegExp(
      r'hippo|\bLAN\b|192\.168|localhost|auth_apps|plane-slim|asodya_tracking|wilsonborba/domain|\.local\b',
      caseSensitive: false,
    );
    for (final locale in ['en', 'pt-BR', 'th']) {
      for (final route in pages.keys) {
        await open(tester, route, locale: locale);
        for (final text in texts(tester)) {
          expect(forbidden.hasMatch(text), isFalse, reason: '$route: $text');
        }
      }
    }
  });

  test('every landing string has EN, pt-BR and TH and no dash characters', () {
    for (final MapEntry(:key, :value) in landingStrings.entries) {
      expect(value, hasLength(3), reason: key);
      for (final text in value) {
        expect(text.trim(), isNotEmpty, reason: key);
        expect(
          text.contains('\u2014') || text.contains('\u2013'),
          isFalse,
          reason: key,
        );
      }
    }
  });

  test('the image map has the 43 target ids with their files', () {
    expect(landingImages, hasLength(43));
    for (final MapEntry(:key, :value) in landingImages.entries) {
      expect(value.file, startsWith('${key}_'));
    }
  });
}
