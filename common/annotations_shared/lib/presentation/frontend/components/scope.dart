import 'package:flutter/material.dart';
import '../../../domain/services/account_service.dart';
import '../../../domain/services/installed_account.dart';
import '../../../domain/services/local_workspace.dart';
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

  /// The writer workspace of an installed app; null in the browser.
  final LocalWorkspace? workspace;

  /// The installed-app account (native handoff); null in the browser.
  final InstalledAccount? installed;
  const AppScope({
    super.key,
    required this.preferences,
    required this.service,
    this.account,
    this.myNotes,
    this.workspace,
    this.installed,
    required super.child,
  });
  static AppScope of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppScope>()!;
  @override
  bool updateShouldNotify(AppScope oldWidget) => true;
}

extension ContextStrings on BuildContext {
  String tr(String key, [Map<String, String> args = const {}]) =>
      translate(key, AppScope.of(this).preferences.locale, args);
}
