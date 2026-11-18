import 'package:flutter/material.dart';
import '../../dal/local/preferences_adapter.dart';

class Preferences extends ChangeNotifier {
  final PreferencesAdapter storage;
  String locale = 'en';
  ThemeMode theme = ThemeMode.system;

  /// False after Don't show this message again on the text space limit
  /// message (B2.3). Kept on this device; the red border and the shake stay.
  bool spaceLimitMessage = true;
  Preferences({PreferencesAdapter? storage})
    : storage = storage ?? PreferencesAdapter();
  Future<void> load() async {
    final language = await storage.read('locale');
    if (['en', 'pt-BR', 'th'].contains(language)) locale = language!;
    final mode = await storage.read('theme');
    theme = mode == 'dark'
        ? ThemeMode.dark
        : mode == 'light'
        ? ThemeMode.light
        : ThemeMode.system;
    spaceLimitMessage = await storage.read('spaceLimitMessage') != 'off';
    notifyListeners();
  }

  Future<void> language(String value) async {
    locale = value;
    notifyListeners();
    await storage.write('locale', value);
  }

  Future<void> toggle(bool currentlyDark) async {
    theme = currentlyDark ? ThemeMode.light : ThemeMode.dark;
    notifyListeners();
    await storage.write('theme', currentlyDark ? 'light' : 'dark');
  }

  Future<void> hideSpaceLimitMessage() async {
    spaceLimitMessage = false;
    notifyListeners();
    await storage.write('spaceLimitMessage', 'off');
  }
}
