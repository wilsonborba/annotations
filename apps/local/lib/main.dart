import 'package:flutter/material.dart';
import 'package:annotations_shared/app.dart';
import 'package:annotations_shared/core/features.dart';
import 'package:annotations_shared/core/settings.dart';
import 'core/settings.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  Settings.use(settings);
  await AppFeatures.start();
  runApp(const AnnotationsApp());
}
