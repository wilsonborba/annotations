import 'fixtures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:annotations_shared/app.dart';

void main() {
  testWidgets('public shell starts without authentication', (tester) async {
    SharedPreferences.setMockInitialValues({});
    // The landing hero and showcase move; reduced motion keeps them still.
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    await tester.pumpWidget(
      AnnotationsApp(
        trackingEnabled: false,
        initialLocation: '/v1/home',
        service: fixtureService(),
      ),
    );
    await tester.pumpAndSettle();
    // The title next to the shared logo (the showcase window has its own).
    expect(
      find.descendant(
        of: find.byKey(const Key('brand-home')),
        matching: find.text('Annotations'),
      ),
      findsOneWidget,
    );
    expect(find.text('Login'), findsNothing);
  });
}
