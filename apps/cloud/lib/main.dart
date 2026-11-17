import 'package:flutter/material.dart';
import 'package:flutter_web_plugins/url_strategy.dart';
import 'package:annotations_shared/app.dart';
import 'package:annotations_shared/core/features.dart';
import 'package:annotations_shared/core/settings.dart';
import 'core/settings.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  Settings.use(settings);
  usePathUrlStrategy();
  await AppFeatures.start();
  runApp(const AnnotationsApp());
}
