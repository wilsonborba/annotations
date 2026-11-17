import 'package:flutter/material.dart';
import 'package:annotations_shared/app.dart';
import 'package:annotations_shared/core/features.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AppFeatures.start();
  runApp(const AnnotationsApp());
}
