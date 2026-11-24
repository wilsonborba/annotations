import 'package:annotations_shared/dal/local/device_note_store_stub.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('browser device-store opener fails explicitly', () async {
    await expectLater(openDeviceNoteStore(), throwsUnsupportedError);
  });
}
