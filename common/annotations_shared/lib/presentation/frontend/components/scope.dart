import 'package:flutter/material.dart';
import '../../../domain/services/preferences.dart';
import '../../../domain/services/annotations_service.dart';
import '../../../core/strings.dart';

class AppScope extends InheritedWidget {
  final Preferences preferences;
  final AnnotationsService service;
  const AppScope({
    super.key,
    required this.preferences,
    required this.service,
    required super.child,
  });
  static AppScope of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppScope>()!;
  @override
  bool updateShouldNotify(AppScope oldWidget) => true;
}

extension ContextStrings on BuildContext {
  String tr(String key) => translate(key, AppScope.of(this).preferences.locale);
}
