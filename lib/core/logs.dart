import 'package:flutter/foundation.dart';
import 'settings.dart';

void appLog(String message, {bool debug = false}) {
  if (!debug || Settings.development) debugPrint(message);
}
