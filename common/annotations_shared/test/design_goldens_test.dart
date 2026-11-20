import 'dart:io';
import 'fixtures.dart';
import 'package:annotations_shared/app.dart';
import 'package:annotations_shared/presentation/frontend/components/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _fonts = 'lib/presentation/frontend/assets/fonts';

Future<ByteData> _font(String file) async => ByteData.sublistView(
  Uint8List.fromList(await File('$_fonts/$file').readAsBytes()),
);

/// Loads the real Ubuntu Sans and IBM Plex Sans Thai, not the test font, so
/// Latin and Thai glyphs render as in the application.
Future<void> loadAppFonts() async {
  await (FontLoader(appFontFamily)
        ..addFont(_font('UbuntuSans-Variable.ttf'))
        ..addFont(_font('UbuntuSans-Italic-Variable.ttf')))
      .load();
  await (FontLoader(appFontFallback.single)
        ..addFont(_font('IBMPlexSansThai-Regular.ttf'))
        ..addFont(_font('IBMPlexSansThai-SemiBold.ttf'))
        ..addFont(_font('IBMPlexSansThai-Bold.ttf')))
      .load();
}

void main() {
  setUpAll(loadAppFonts);

  for (final theme in ['light', 'dark']) {
    for (final locale in ['en', 'pt-BR', 'th']) {
      testWidgets('component gallery, $theme, $locale', (tester) async {
        // Draw the real panel shadows, not the test outlines.
        debugDisableShadows = false;
        SharedPreferences.setMockInitialValues({
          'annotations.locale': locale,
          'annotations.theme': theme,
        });
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(1280, 1000);
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          AnnotationsApp(
            trackingEnabled: false,
            initialLocation: '/v1/gallery',
            service: fixtureService(),
          ),
        );
        await tester.pumpAndSettle();
        // Grow the window until the whole gallery fits, for one image.
        final scroll = tester
            .state<ScrollableState>(find.byType(Scrollable).first)
            .position;
        tester.view.physicalSize = Size(1280, 1000 + scroll.maxScrollExtent);
        await tester.pumpAndSettle();
        expect(find.text('Component gallery'), findsOneWidget);
        // Decode the logo before the image is taken.
        await tester.runAsync(() async {
          for (final element in find.byType(Image).evaluate()) {
            await precacheImage((element.widget as Image).image, element);
          }
        });
        await tester.pumpAndSettle();
        await expectLater(
          find.byType(MaterialApp),
          matchesGoldenFile('goldens/gallery_${theme}_$locale.png'),
        );
        debugDisableShadows = true;
      });
    }
  }

  testWidgets('the logo and the title go home', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(
      AnnotationsApp(
        trackingEnabled: false,
        initialLocation: '/v1/menu',
        service: fixtureService(),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Annotations'), findsOneWidget);
    expect(find.byKey(const Key('overview-download')), findsNothing);
    await tester.tap(find.byKey(const Key('brand-home')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('overview-download')), findsOneWidget);
  });

  testWidgets('icon buttons: the label is the tooltip, none when disabled', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1280, 1000);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      AnnotationsApp(
        trackingEnabled: false,
        initialLocation: '/v1/gallery',
        service: fixtureService(),
      ),
    );
    await tester.pumpAndSettle();
    final semantics = tester.ensureSemantics();
    expect(find.byTooltip('Edit'), findsWidgets);
    expect(find.byTooltip('Choose files'), findsNothing);
    expect(find.bySemanticsLabel('Choose files'), findsOneWidget);
    semantics.dispose();
  });
}
