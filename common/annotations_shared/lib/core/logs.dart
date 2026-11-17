import 'package:flutter/foundation.dart';
import 'settings.dart';

/// Console logs of the application: debug, info, warning and error.
///
/// Debug lines are printed only when [Settings.development] is true. Logs
/// stay in the console; the app writes no log files. Never pass note text,
/// strokes, drafts, file or clipboard content, credentials or room codes.
enum LogLevel { debug, info, warning, error }

void _write(LogLevel level, String module, String message) {
  if (level == LogLevel.debug && !Settings.current.development) return;
  debugPrint(
    '${DateTime.now().toUtc().toIso8601String()} '
    '${level.name.toUpperCase()} ${Settings.appId} $module: $message',
  );
}

/// Prints a debug line in development builds only.
void logDebug(String module, String message) =>
    _write(LogLevel.debug, module, message);

/// Prints an info line.
void logInfo(String module, String message) =>
    _write(LogLevel.info, module, message);

/// Prints a warning line.
void logWarning(String module, String message) =>
    _write(LogLevel.warning, module, message);

/// Prints an error line.
void logError(String module, String message) =>
    _write(LogLevel.error, module, message);
