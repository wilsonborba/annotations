import 'package:flutter/material.dart';
import '../../../domain/services/account_service.dart';
import '../../../domain/services/my_notes_service.dart';
import '../../../domain/services/preferences.dart';
import '../../../domain/services/annotations_service.dart';
import '../../../core/strings.dart';

class AppScope extends InheritedWidget {
  final Preferences preferences;
  final AnnotationsService service;

  /// The browser account (annotations#38); null where the app has no
  /// browser session (the installed apps use the native handoff).
  final AccountService? account;

  /// The signed-in user's notes in the browser (read only).
  final MyNotesService? myNotes;
  const AppScope({
    super.key,
    required this.preferences,
    required this.service,
    this.account,
    this.myNotes,
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
