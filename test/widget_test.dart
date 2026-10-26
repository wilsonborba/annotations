import 'fixtures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:annotations/app.dart';

void main() {
  testWidgets('public shell starts without authentication', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(
      AnnotationsApp(
        trackingEnabled: false,
        initialLocation: '/v1/home',
        service: fixtureService(),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Annotations'), findsOneWidget);
    expect(find.text('Login'), findsNothing);
  });
}
