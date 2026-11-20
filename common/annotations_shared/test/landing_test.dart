import 'dart:convert';

import 'package:annotations_shared/app.dart';
import 'package:annotations_shared/core/landing_settings.dart';
import 'package:annotations_shared/core/landing_strings.dart';
import 'package:annotations_shared/core/strings.dart';
import 'package:annotations_shared/domain/services/annotations_service.dart';
import 'package:annotations_shared/domain/services/preferences.dart';
import 'package:annotations_shared/presentation/frontend/components/controls.dart';
import 'package:annotations_shared/presentation/frontend/components/interactive_card.dart';
import 'package:annotations_shared/presentation/frontend/components/scope.dart';
import 'package:annotations_shared/presentation/frontend/components/shell.dart';
import 'package:annotations_shared/presentation/frontend/components/sketch_art.dart';
import 'package:annotations_shared/presentation/frontend/components/sketch_diagram.dart';
import 'package:annotations_shared/presentation/frontend/components/theme.dart';
import 'package:annotations_shared/presentation/frontend/components/tokens.dart';
import 'package:annotations_shared/presentation/frontend/handlers/landing_handler.dart';
import 'package:annotations_shared/presentation/frontend/widgets/landing/download_page.dart';
import 'package:annotations_shared/presentation/frontend/widgets/landing/features_page.dart';
import 'package:annotations_shared/presentation/frontend/widgets/landing/landing_blocks.dart';
import 'package:annotations_shared/presentation/frontend/widgets/landing/landing_sections.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'design_goldens_test.dart' show loadAppFonts;
import 'fixtures.dart';

/// The landing pages and their photos (annotations#53 redesign: at most
/// three photos on the whole site, from the allowed set).
const pages = {
  '/v1/home': <String>[],
  '/v1/home/features': <String>[],
  '/v1/home/how-it-works': <String>[],
  '/v1/home/engineering': ['E02'],
  '/v1/home/download': <String>[],
};

/// The allowed photo slots (owner direction 2026-11-20): the stickers, the
/// library shelves, a computer in use.
const allowedPhotos = {'E02', 'F15', 'O09'};

/// Turns on reduced motion for one test: the hero marks stay still and the
/// showcase does not move, so pumpAndSettle can settle.
void stillMotion(WidgetTester tester) {
  tester.platformDispatcher.accessibilityFeaturesTestValue =
      const FakeAccessibilityFeatures(disableAnimations: true);
  addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
}

Future<void> open(
  WidgetTester tester,
  String location, {
  double width = 1300,
  String locale = 'en',
  String theme = 'light',
  AnnotationsService? service,
}) async {
  stillMotion(tester);
  SharedPreferences.setMockInitialValues({
    'annotations.locale': locale,
    'annotations.theme': theme,
  });
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

Widget bare(Widget child, {Brightness brightness = Brightness.light}) =>
    AppScope(
      service: fixtureService(),
      preferences: Preferences(),
      child: MaterialApp(
        theme: appTheme(brightness),
        home: Scaffold(body: SingleChildScrollView(child: child)),
      ),
    );

/// Every text on the screen, for wording and privacy checks.
List<String> texts(WidgetTester tester) => [
  for (final element in find.byType(Text).evaluate())
    (element.widget as Text).data ??
        (element.widget as Text).textSpan?.toPlainText() ??
        '',
  for (final element in find.byType(SelectableText).evaluate())
    (element.widget as SelectableText).data ?? '',
];

String headline(String locale) =>
    '${translate('heroBefore', locale)}${translate('heroWord', locale)}'
    '${translate('heroAfter', locale)}';

int primaryButtons(WidgetTester tester) => tester
    .widgetList<AppButton>(find.byType(AppButton))
    .where((b) => b.kind == AppButtonKind.primary)
    .length;

void main() {
  setUpAll(loadAppFonts);

  testWidgets('/ redirects to the Overview and every tab opens its own page', (
    tester,
  ) async {
    await open(tester, '/');
    expect(find.byKey(const Key('hero-headline')), findsOneWidget);
    for (final (route, key, _) in landingTabs) {
      await tester.tap(find.byKey(Key('tab-$key')));
      await tester.pumpAndSettle();
      final tab = tester.widget<ShellTab>(find.byKey(Key('tab-$key')));
      expect(tab.selected, isTrue, reason: route);
      expect(
        tester
            .widgetList<ShellTab>(find.byType(ShellTab))
            .where((t) => t.selected)
            .length,
        1,
      );
    }
    // The shared Asodya logo goes home from any page.
    await tester.tap(find.byKey(const Key('brand-home')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('hero-headline')), findsOneWidget);
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
    expect(find.byKey(const Key('install-iphone')), findsOneWidget);
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
                '$route $width $locale: ${paragraph.text.toPlainText()}',
              );
            }
          }
        }
      }
    }
    expect(unbreakable, isEmpty);
  });

  testWidgets('at most three photos, only allowed ones, none of people', (
    tester,
  ) async {
    expect(landingImages.length, lessThanOrEqualTo(3));
    expect(allowedPhotos.containsAll(landingImages.keys), isTrue);
    for (final MapEntry(key: route, value: ids) in pages.entries) {
      await open(tester, route);
      for (final id in landingImages.keys) {
        expect(
          find.byKey(Key('image-$id')),
          ids.contains(id) ? findsOneWidget : findsNothing,
          reason: '$route $id',
        );
      }
    }
  });

  testWidgets('the state images are drawn and sit above their messages', (
    tester,
  ) async {
    await open(
      tester,
      '/v1/menu/wilson/private-note',
      service: fixtureService(handler: (_) async => http.Response('{}', 404)),
    );
    expect(
      tester.getTopLeft(find.byKey(const Key('image-S01'))).dy,
      lessThan(tester.getTopLeft(find.byKey(const Key('not-found'))).dy),
    );
    expect(
      find.descendant(
        of: find.byKey(const Key('image-S01')),
        matching: find.byKey(const Key('sketch-emptyDesk')),
      ),
      findsOneWidget,
    );

    await open(tester, '/v1/menu');
    expect(
      tester.getTopLeft(find.byKey(const Key('image-S03'))).dy,
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
    expect(
      tester.getTopLeft(find.byKey(const Key('image-S02'))).dy,
      lessThan(tester.getTopLeft(find.byKey(const Key('room-expired'))).dy),
    );
  });

  group('Overview hero', () {
    testWidgets('the headline is at least 56 px with the marked word', (
      tester,
    ) async {
      for (final locale in ['en', 'pt-BR', 'th']) {
        await open(tester, '/v1/home', locale: locale);
        final rich = tester.widget<Text>(
          find.byKey(const Key('hero-headline')),
        );
        expect(rich.textSpan!.style!.fontSize, greaterThanOrEqualTo(56));
        expect(
          find.bySemanticsLabel(headline(locale)),
          findsOneWidget,
          reason: locale,
        );
        expect(find.text(translate('heroWord', locale)), findsOneWidget);
      }
      await open(tester, '/v1/home', width: 390);
      final phone = tester.widget<Text>(find.byKey(const Key('hero-headline')));
      expect(phone.textSpan!.style!.fontSize, 40);
    });

    testWidgets('the word marks move, and stay still under reduced motion', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1300, 900);
      addTearDown(tester.view.reset);
      Future<double> progressAfter(Duration wait) async {
        await tester.pump(wait);
        final paint = tester.widget<CustomPaint>(
          find.byKey(const Key('hero-word-marks')),
        );
        return (paint.painter as dynamic).progress as double;
      }

      await tester.pumpWidget(bare(const AnimatedHeadline()));
      final a = await progressAfter(const Duration(milliseconds: 300));
      final b = await progressAfter(const Duration(milliseconds: 900));
      expect(b, isNot(a));
      await tester.pumpWidget(const SizedBox());

      stillMotion(tester);
      await tester.pumpWidget(bare(const AnimatedHeadline()));
      expect(await progressAfter(const Duration(seconds: 1)), stillProgress);
      expect(await progressAfter(const Duration(seconds: 2)), stillProgress);
    });

    testWidgets('one strong purple action per page; it is Download here', (
      tester,
    ) async {
      for (final route in pages.keys) {
        await open(tester, route);
        expect(primaryButtons(tester), 1, reason: route);
      }
      await open(tester, '/v1/home');
      final download = tester.widget<AppButton>(
        find.byKey(const Key('overview-download')),
      );
      expect(download.kind, AppButtonKind.primary);
      await tester.tap(find.byKey(const Key('overview-download')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('install-mac')), findsOneWidget);
    });
  });

  group('Product showcase', () {
    Future<ProductShowcaseState> pumpShowcase(
      WidgetTester tester, {
      bool still = false,
    }) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1300, 1200);
      addTearDown(tester.view.reset);
      if (still) stillMotion(tester);
      await tester.pumpWidget(
        bare(const ProductShowcase(interval: Duration(seconds: 2))),
      );
      await tester.pump();
      return tester.state<ProductShowcaseState>(find.byType(ProductShowcase));
    }

    testWidgets('real desktop and phone screenshots, stacked', (tester) async {
      await pumpShowcase(tester);
      final assets = [
        for (final image in tester.widgetList<Image>(find.byType(Image)))
          (image.image as AssetImage).assetName,
      ];
      expect(assets, contains(desktopShot.asset(false)));
      expect(assets, contains(phoneShot.asset(false)));
      // The phone overlaps the corner of the desktop window.
      final window = tester.getRect(find.byKey(const Key('window-mac')));
      final phone = tester.getRect(find.byKey(const Key('phone-frame')));
      expect(window.overlaps(phone), isTrue);
      expect(phone.right, greaterThan(window.right));
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('switches by itself, by choice, and waits on hover', (
      tester,
    ) async {
      final s = await pumpShowcase(tester);
      expect(s.platform, ShowcasePlatform.mac);
      await tester.pump(const Duration(seconds: 2));
      expect(s.platform, ShowcasePlatform.linux);
      // The user chooses the browser.
      await tester.tap(find.byKey(const Key('showcase-browser')));
      await tester.pump(const Duration(milliseconds: 400));
      expect(s.platform, ShowcasePlatform.browser);
      expect(
        (tester
            .widgetList<Image>(find.byType(Image))
            .map((i) => (i.image as AssetImage).assetName)),
        contains(browserShot.asset(false)),
      );
      // The pointer on it pauses the timer.
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(
        location: tester.getCenter(find.byKey(const Key('phone-frame'))),
      );
      await tester.pump();
      expect(s.paused, isTrue);
      await tester.pump(const Duration(seconds: 5));
      expect(s.platform, ShowcasePlatform.browser);
      await mouse.moveTo(const Offset(1, 1199));
      await tester.pump();
      expect(s.paused, isFalse);
      await tester.pump(const Duration(seconds: 2));
      expect(s.platform, ShowcasePlatform.mac);
      await mouse.removePointer();
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('the focus pauses it too', (tester) async {
      final s = await pumpShowcase(tester);
      Focus.of(
        tester.element(find.byKey(const Key('showcase-linux'))),
      ).requestFocus();
      await tester.pump();
      FocusManager.instance.highlightStrategy =
          FocusHighlightStrategy.alwaysTraditional;
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(s.paused, isTrue);
      await tester.pump(const Duration(seconds: 6));
      expect(s.platform, ShowcasePlatform.mac);
      await tester.pumpWidget(const SizedBox());
      FocusManager.instance.highlightStrategy =
          FocusHighlightStrategy.automatic;
    });

    testWidgets('never moves under reduced motion', (tester) async {
      final s = await pumpShowcase(tester, still: true);
      await tester.pump(const Duration(seconds: 10));
      expect(s.platform, ShowcasePlatform.mac);
    });
  });

  group('Install section', () {
    testWidgets('every platform has its icon, action and install path', (
      tester,
    ) async {
      await open(tester, '/v1/home');
      for (final p in InstallPlatform.values) {
        final block = find.byKey(Key('install-${p.name}'));
        expect(block, findsOneWidget, reason: p.name);
        expect(
          find.descendant(of: block, matching: find.byType(SketchIcon)),
          findsOneWidget,
          reason: p.name,
        );
        expect(
          find.byKey(Key('install-${p.name}-action')),
          findsOneWidget,
          reason: p.name,
        );
        if (p != InstallPlatform.browser) {
          expect(find.byKey(Key('install-${p.name}-how')), findsOneWidget);
        }
      }
      // The browser has an address to copy; nothing is released yet.
      expect(find.byKey(const Key('install-browser-copy')), findsOneWidget);
      expect(
        tester
            .widget<Text>(find.byKey(const Key('install-iphone-status')))
            .data,
        'Not available to the public yet.',
      );
      for (final p in ['mac', 'linux', 'tablets', 'androidPhones']) {
        expect(
          tester.widget<Text>(find.byKey(Key('install-$p-status'))).data,
          'No public release yet.',
        );
        expect(
          tester
              .widget<AppButton>(find.byKey(Key('install-$p-action')))
              .onPressed,
          isNull,
        );
      }
      expect(find.byKey(const Key('install-note')), findsOneWidget);
      await tester.ensureVisible(find.byKey(const Key('install-mac-how')));
      await tester.tap(find.byKey(const Key('install-mac-how')));
      await tester.pumpAndSettle();
      expect(find.text(translate('downloadTitle', 'en')), findsWidgets);
    });

    testWidgets('copying the address and the source command', (tester) async {
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
      await open(tester, '/v1/home/download');
      for (final key in ['install-browser-copy', 'source-command']) {
        final button = find.descendant(
          of: find.byKey(Key(key)),
          matching: find.byType(AppIconButton),
        );
        await tester.ensureVisible(button);
        await tester.tap(button);
        await tester.pumpAndSettle();
      }
      expect(copied, [
        LandingSettings.siteAddress,
        LandingSettings.cloneCommand,
      ]);
    });

    testWidgets('a released platform shows version, date, command, action', (
      tester,
    ) async {
      stillMotion(tester);
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1300, 1000);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        bare(
          const DownloadPage(
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
      );
      await tester.pumpAndSettle();
      final block = find.byKey(const Key('install-linux'));
      expect(
        tester.widget<Text>(find.byKey(const Key('install-linux-status'))).data,
        'Available',
      );
      expect(
        find.descendant(
          of: block,
          matching: find.text('Version 2.0.0 · 2026-12-01'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(of: block, matching: find.text('sh install.sh')),
        findsOneWidget,
      );
      expect(
        tester
            .widget<AppButton>(find.byKey(const Key('install-linux-action')))
            .onPressed,
        isNotNull,
      );
      expect(
        tester
            .widget<AppButton>(find.byKey(const Key('install-mac-action')))
            .onPressed,
        isNull,
      );
    });
  });

  group('Interactive states', () {
    testWidgets('a card shows hover, focus-visible and pressed states', (
      tester,
    ) async {
      var taps = 0;
      await tester.pumpWidget(
        bare(
          Center(
            child: SizedBox(
              width: 300,
              child: InteractiveCard(
                onTap: () => taps++,
                child: const Text('Card'),
              ),
            ),
          ),
        ),
      );
      final s = tester.state<InteractiveCardState>(
        find.byType(InteractiveCard),
      );
      BoxDecoration surface() =>
          tester
                  .widget<AnimatedContainer>(
                    find.byKey(const Key('card-surface')),
                  )
                  .decoration!
              as BoxDecoration;
      final rest = surface();
      expect(s.state, CardState.rest);

      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: tester.getCenter(find.text('Card')));
      await tester.pumpAndSettle();
      expect(s.state, CardState.hover);
      expect(surface().border, isNot(rest.border));
      expect(surface().color, AppColors.light.subtle);
      await mouse.moveTo(const Offset(1, 1));
      await tester.pumpAndSettle();

      FocusManager.instance.highlightStrategy =
          FocusHighlightStrategy.alwaysTraditional;
      Focus.of(tester.element(find.text('Card'))).requestFocus();
      await tester.pumpAndSettle();
      expect(s.state, CardState.focus);
      expect(
        (surface().border! as Border).top.color,
        AppColors.light.selectionOutline,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(taps, 1);
      FocusManager.instance.highlightStrategy =
          FocusHighlightStrategy.automatic;

      final press = await tester.startGesture(
        tester.getCenter(find.text('Card')),
      );
      await tester.pumpAndSettle();
      expect(s.state, CardState.pressed);
      expect(surface().color, AppColors.light.pressed);
      await press.up();
      await tester.pumpAndSettle();
      expect(taps, 2);
      await mouse.removePointer();
    });

    testWidgets('a link shows hover, focus-visible and pressed states', (
      tester,
    ) async {
      var taps = 0;
      await tester.pumpWidget(
        bare(
          Center(
            child: AppLink(label: 'Read more', onTap: () => taps++),
          ),
        ),
      );
      final s = tester.state<AppLinkState>(find.byType(AppLink));
      TextStyle style() => tester.widget<Text>(find.byType(Text).last).style!;
      expect(style().decoration, TextDecoration.none);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: tester.getCenter(find.byType(AppLink)));
      await tester.pumpAndSettle();
      expect(s.state, CardState.hover);
      expect(style().decoration, TextDecoration.underline);
      await mouse.moveTo(const Offset(1, 1));
      await tester.pumpAndSettle();
      FocusManager.instance.highlightStrategy =
          FocusHighlightStrategy.alwaysTraditional;
      Focus.of(tester.element(find.text('Read more'))).requestFocus();
      await tester.pumpAndSettle();
      expect(s.state, CardState.focus);
      expect(
        ((tester
                            .widget<Container>(
                              find.byKey(const Key('link-surface')),
                            )
                            .decoration!
                        as BoxDecoration)
                    .border!
                as Border)
            .top
            .color,
        AppColors.light.selectionOutline,
      );
      FocusManager.instance.highlightStrategy =
          FocusHighlightStrategy.automatic;
      Focus.of(tester.element(find.text('Read more'))).unfocus();
      await tester.pumpAndSettle();
      final press = await tester.startGesture(
        tester.getCenter(find.byType(AppLink)),
      );
      await tester.pumpAndSettle();
      expect(s.state, CardState.pressed);
      await press.up();
      await tester.pumpAndSettle();
      expect(taps, 1);
      await mouse.removePointer();
    });

    testWidgets('the Overview cards are controls that open their page', (
      tester,
    ) async {
      await open(tester, '/v1/home');
      for (final key in [
        'card-notes',
        'card-instant',
        'card-writing',
        'card-chart',
        'card-tasks',
      ]) {
        expect(
          find.descendant(
            of: find.byKey(Key(key)),
            matching: find.byType(InteractiveCard),
          ),
          findsOneWidget,
          reason: key,
        );
      }
      await tester.ensureVisible(find.byKey(const Key('card-chart')));
      await tester.tap(find.byKey(const Key('card-chart')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('group-pageContent')), findsOneWidget);
    });
  });

  test('colour jobs per H7 in both themes', () {
    for (final c in [AppColors.light, AppColors.dark]) {
      // Purple fill with white text: the one main action.
      expect(c.accent, AppPalette.purple);
      expect(c.onAccent, AppPalette.white);
      // Green fill with dark text: selection, the current tab, focus.
      expect(c.selection, AppPalette.green);
      expect(c.onSelection, AppPalette.night);
    }
    expect(AppColors.light.link, AppPalette.purple);
    expect(AppColors.dark.link, AppPalette.green);
  });

  testWidgets('green and purple both show on every page in both themes', (
    tester,
  ) async {
    for (final theme in ['light', 'dark']) {
      for (final route in pages.keys) {
        await open(tester, route, theme: theme);
        // Purple: the page's one main action.
        expect(primaryButtons(tester), 1, reason: '$route $theme');
        // Green: the current tab and the chosen language.
        final tab = tester.widgetList<ShellTab>(find.byType(ShellTab));
        expect(tab.where((t) => t.selected), hasLength(1));
      }
    }
  });

  testWidgets('features: groups alternate sides; rows say what they need', (
    tester,
  ) async {
    await open(tester, '/v1/home/features');
    const handler = LandingHandler();
    for (final (g, group) in handler.groups.indexed) {
      final section = find.byKey(Key('group-${group.name}'));
      final art = tester.getCenter(
        find.descendant(of: section, matching: find.byType(SketchArt)),
      );
      final first = handler.rows(group).first;
      final text = tester.getCenter(find.byKey(Key('feature-${first.image}')));
      expect(art.dx > text.dx, g.isEven, reason: group.name);
      // At most one visual per group.
      expect(
        find.descendant(of: section, matching: find.byType(SketchArt)),
        findsOneWidget,
      );
    }
    for (final (id, label) in [
      ('F14', 'Needs internet, no login'),
      ('F08', 'Needs internet and sign-in'),
      ('F01', 'Works offline, no login'),
    ]) {
      expect(
        find.descendant(
          of: find.byKey(Key('needs-$id')),
          matching: find.text(label),
        ),
        findsOneWidget,
      );
    }
  });

  test('a feature outside the release is removed', () {
    const off = LandingHandler(transcription: false);
    expect(
      off.rows(FeatureGroup.study).map((r) => r.image),
      isNot(contains('F10')),
    );
    const on = LandingHandler(transcription: true);
    expect(on.rows(FeatureGroup.study).map((r) => r.image), contains('F10'));
    for (final row in landingFeatures) {
      expect(landingStrings.containsKey('feature${row.image}Title'), isTrue);
      expect(landingStrings.containsKey('feature${row.image}Text'), isTrue);
    }
  });

  testWidgets('the release switch removes the F10 row', (tester) async {
    tester.view.physicalSize = const Size(1300, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    Future<void> pump(bool transcription) async {
      SharedPreferences.setMockInitialValues({});
      await tester.pumpWidget(
        bare(
          FeaturesPage(handler: LandingHandler(transcription: transcription)),
        ),
      );
      await tester.pumpAndSettle();
    }

    await pump(false);
    expect(find.byKey(const Key('feature-F10')), findsNothing);
    await pump(true);
    expect(find.byKey(const Key('feature-F10')), findsOneWidget);
  });

  testWidgets('on a phone the text comes first and the visual below it', (
    tester,
  ) async {
    await open(tester, '/v1/home/engineering', width: 390);
    final title = tester.getTopLeft(
      find.text(translate('engSourceTitle', 'en')),
    );
    final image = tester.getTopLeft(find.byKey(const Key('image-E02')));
    expect(image.dy, greaterThan(title.dy));
    expect(tester.getSize(find.byKey(const Key('image-E02'))).width, 350);
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
    expect(
      tester.getTopLeft(find.byKey(const Key('footer-content'))).dx,
      tester.getTopLeft(find.byKey(const Key('image-E02'))).dx,
    );
  });

  testWidgets('each diagram part links to its repository at a tag', (
    tester,
  ) async {
    final opened = <String>[];
    tester.view.physicalSize = const Size(1300, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      bare(
        SketchDiagram(
          name: 'architecture',
          stages: architectureStages,
          onOpen: (repo) => opened.add(repo.url),
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
        expect(text.contains('—') || text.contains('–'), isFalse, reason: key);
      }
    }
  });
}
