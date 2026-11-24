// Private review captures for annotations#38. Set the output directory to a
// caller-owned cache path; this test never writes into the repository by default.
import 'dart:io';
import 'dart:typed_data';

import 'package:annotations_shared/app.dart';
import 'package:annotations_shared/domain/services/account_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'design_goldens_test.dart' show loadAppFonts;
import 'fixtures.dart';

final output = Platform.environment['ANNOTATIONS_SURFACE_CAPTURE_DIR'];

AccountService signedInAccount() {
  final client = MockClient((request) async {
    if (request.method == 'GET' && request.url.path == '/user/info/v1/') {
      return http.Response(
        '{"data":{"email":"ana@example.test","first_name":"Ana","last_name":"Lima"}}',
        200,
      );
    }
    return http.Response('{}', 404);
  });
  return AccountService(
    client: client,
    gateway: 'https://gateway.test',
    platform: SessionPlatform(
      readCookie: (name) => name == 'csrf' ? 'capture-session' : null,
      deleteCookie: (_) {},
      origin: () => 'https://annotations.test',
      open: (_) async {},
      aes: (_, _, data) async => Uint8List.fromList(data),
    ),
  );
}

void main() {
  setUpAll(loadAppFonts);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('capture signed-in account surfaces', skip: output == null, (
    tester,
  ) async {
    final directory = Directory(output!);
    await tester.runAsync(() => directory.create(recursive: true));
    debugDisableShadows = false;
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);

    Future<void> capture(String name) async => expectLater(
      find.byType(MaterialApp).first,
      matchesGoldenFile(Uri.file('${directory.path}/$name.png')),
    );

    for (final width in [1300.0, 390.0]) {
      for (final brightness in ['light', 'dark']) {
        for (final locale in ['en', 'pt-BR', 'th']) {
          SharedPreferences.setMockInitialValues({
            'annotations.locale': locale,
            'annotations.theme': brightness,
          });
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = Size(width, width < 600 ? 844 : 860);
          addTearDown(tester.view.reset);
          final account = signedInAccount();
          // A breadcrumb per viewport keeps a slow local renderer observable.
          // ignore: avoid_print
          print('rendering ${width.toInt()} $brightness $locale');
          await tester.pumpWidget(
            AnnotationsApp(
              key: UniqueKey(),
              trackingEnabled: false,
              initialLocation: '/v1/home',
              service: fixtureService(),
              account: account,
            ),
          );
          await tester.pump();
          await tester.runAsync(() async {
            for (final element in find.byType(Image).evaluate()) {
              await precacheImage((element.widget as Image).image, element);
            }
          });
          await tester.pumpAndSettle(
            const Duration(milliseconds: 100),
            EnginePhase.sendSemanticsUpdate,
            const Duration(seconds: 20),
          );
          final name =
              '${width.toInt()}_${brightness}_${locale.replaceAll('-', '_')}';
          if (width < 600) {
            // Keep a clean hero frame beside the open mobile menu capture.
            await capture('${name}_closed');
            await tester.tap(find.byKey(const Key('tabs-menu')));
          } else {
            await tester.tap(find.byKey(const Key('account-avatar')));
          }
          await tester.pumpAndSettle(
            const Duration(milliseconds: 100),
            EnginePhase.sendSemanticsUpdate,
            const Duration(seconds: 20),
          );
          await capture(name);
          // ignore: avoid_print
          print('saved ${width.toInt()} $brightness $locale');
          await tester.pumpWidget(const SizedBox());
          account.dispose();
        }
      }
    }
    // AutomatedTestWidgetsFlutterBinding sets this back to true by default.
    debugDisableShadows = true;
  });
}
