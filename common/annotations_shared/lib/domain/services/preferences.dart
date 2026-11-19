import 'dart:convert';

import 'package:flutter/material.dart';
import '../../dal/local/preferences_adapter.dart';
import '../models/toolbar_placement.dart';
import 'draw_tools.dart';

class Preferences extends ChangeNotifier {
  final PreferencesAdapter storage;
  String locale = 'en';
  ThemeMode theme = ThemeMode.system;

  /// False after Don't show this message again on the text space limit
  /// message (B2.3). Kept on this device; the red border and the shake stay.
  bool spaceLimitMessage = true;

  /// Finger drawing in Draw mode (B8): off at first, kept on this device.
  bool fingerDrawing = false;

  /// Moving and zooming the page with fingers (B8): on at first, kept on
  /// this device. Off leaves toolbar taps, the pen and the mouse as they are.
  bool fingerNavigation = true;

  /// The active drawing tool and the settings that each tool remembers
  /// (B6.2), kept on this device. Never note data.
  DrawTools drawTools = DrawTools.initial();

  /// Where the editor toolbar sits (B7 rule 7), kept on this device.
  ToolbarPlacement toolbar = const ToolbarPlacement();
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
    fingerDrawing = await storage.read('fingerDrawing') == 'on';
    fingerNavigation = await storage.read('fingerNavigation') != 'off';
    final toolbarValue = await storage.read('toolbar');
    if (toolbarValue != null) {
      try {
        toolbar = ToolbarPlacement.fromJson(jsonDecode(toolbarValue));
      } on FormatException {
        toolbar = const ToolbarPlacement();
      }
    }
    final tools = await storage.read('drawTools');
    if (tools != null) {
      try {
        drawTools = DrawTools.fromJson(jsonDecode(tools));
      } on FormatException {
        drawTools = DrawTools.initial();
      }
    }
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

  Future<void> setFingerDrawing(bool on) async {
    fingerDrawing = on;
    notifyListeners();
    await storage.write('fingerDrawing', on ? 'on' : 'off');
  }

  Future<void> setFingerNavigation(bool on) async {
    fingerNavigation = on;
    notifyListeners();
    await storage.write('fingerNavigation', on ? 'on' : 'off');
  }

  Future<void> saveToolbar(ToolbarPlacement value) async {
    toolbar = value;
    await storage.write('toolbar', jsonEncode(value.toJson()));
  }

  Future<void> _drawWrites = Future.value();

  /// Keeps the drawing tools. The draw handler owns the live value and
  /// tells its own listeners, so the app does not rebuild for a tool change.
  /// Writes run one after another and each writes the newest value, so a
  /// quick series of changes keeps the last one.
  Future<void> saveDrawTools(DrawTools tools) {
    drawTools = tools;
    return _drawWrites = _drawWrites.then(
      (_) => storage.write('drawTools', jsonEncode(drawTools.toJson())),
    );
  }
}
