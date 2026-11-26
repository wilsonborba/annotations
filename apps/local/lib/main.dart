import 'package:flutter/material.dart';
import 'package:annotations_shared/app.dart';
import 'package:annotations_shared/core/features.dart';
import 'package:annotations_shared/core/settings.dart';
import 'package:annotations_shared/domain/services/local_workspace.dart';
import 'core/settings.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  Settings.use(settings);
  final features = await AppFeatures.start();
  // The writer workspace (annotations#38): the notes on this device, their
  // projects and tags, and the first-start intro until it was seen.
  runApp(
    AnnotationsApp(
      workspace: await openDeviceWorkspace(features.profile),
      introSeen: await introWasSeen(),
      installed: openInstalledAccount(features.profile),
    ),
  );
}
