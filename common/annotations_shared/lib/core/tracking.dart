import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../domain/services/native_auth_service.dart';
import 'logs.dart';
import 'settings.dart';
import 'tracking_manifest.dart';

/// One tracking setup for the browser and the installed apps.
///
/// Both apps send to the shared gateway telemetry routes. In the browser the
/// request sends the session cookie. The installed apps use the native HTTP
/// client of the same transport.
///
/// Never recorded: note text, strokes, transcription drafts, file and
/// clipboard content, credentials and Instant room codes. Fields that hold
/// them are tracked with `sensitive: true` (see [sensitiveElements]), routes
/// use templates (`/v1/instant/:code`) and error details pass [ClientErrors].
/// Only meaningful actions are tracked, never each pen point or mouse move.
///
/// Offline, the tracker keeps at most 200 events and 20 errors in memory,
/// drops the oldest at the limit and sends again with a backoff of up to
/// 64 seconds when the connection returns.
///
/// Pass [client] only in tests.
HttpTrailTransport createTrailTransport({
  Settings? settings,
  http.Client? client,
}) {
  final s = settings ?? Settings.current;
  return HttpTrailTransport(
    eventsUri: s.telemetryEvents,
    errorsUri: s.telemetryErrors,
    includeCredentials: true,
    client: client,
  );
}

/// Creates the tracker of the application with [transport].
///
/// Set [autoFlush] to false and pass [now] for isolated tests.
ScreenTrail createTracker({
  required TrailTransport transport,
  Settings? settings,
  bool autoFlush = true,
  DateTime Function()? now,
}) => ScreenTrail(
  appId: Settings.appId,
  buildVersion: (settings ?? Settings.current).buildLabel,
  screens: annotationScreens,
  transport: transport,
  recordTypedText: true,
  autoFlush: autoFlush,
  now: now,
);

final _roomPath = RegExp(
  r'/instant/(?!:code\b)[^/\s?#"'
  "'"
  r',;)]+',
);

/// Replaces each Instant room code in [text] with `:code`.
String stripPrivatePaths(String text) =>
    text.replaceAll(_roomPath, '/instant/:code');

/// The platform name in error reports, such as `web` or `linux`.
String get platformName => kIsWeb ? 'web' : defaultTargetPlatform.name;

/// Reports client errors with build, platform, screen, operation and
/// safe technical metadata, and gives the user a short reference code.
///
/// Reporting is synchronous, never throws and never waits for the network,
/// so it never blocks editing, saving or opening notes. No note content or
/// screenshot is attached.
class ClientErrors {
  ClientErrors(this.tracker, {String? platform})
    : platform = platform ?? platformName;

  final ScreenTrail tracker;
  final String platform;
  static final _references = Expando<String>('reference');
  static final _random = Random.secure();
  FlutterExceptionHandler? _previousFlutter, _ownFlutter;
  bool Function(Object, StackTrace)? _previousPlatform, _ownPlatform;

  /// The reference code of a reported [error], or null.
  static String? referenceOf(Object? error) {
    if (error == null || error is String || error is num || error is bool) {
      return null;
    }
    return _references[error];
  }

  static String _newReference() => List.generate(
    8,
    (_) => '23456789ABCDEFGHJKLMNPQRSTUVWXYZ'[_random.nextInt(32)],
  ).join();

  /// Queues a report of [error] in [operation] and returns its reference.
  ///
  /// Exception messages and supplied stacks can contain partial, preloaded or
  /// short user content. They never enter a report. Only the exception type and
  /// a typed HTTP status accompany the trusted operation and screen metadata.
  /// Values in [sensitive] are also excluded from later tracked event values.
  String report(
    Object error,
    StackTrace? stack, {
    required String operation,
    String type = 'ClientError',
    int? httpStatus,
    Iterable<String> sensitive = const [],
  }) {
    final reference = _newReference();
    try {
      sensitive.forEach(tracker.privacy.remember);
      final detail =
          'error=${error.runtimeType}'
          '${httpStatus != null && httpStatus >= 100 && httpStatus <= 599 ? ' status=$httpStatus' : ''}';
      final cleanOp = NativeAuthService.sanitizeForLog(
        stripPrivatePaths(operation),
      );
      final message = NativeAuthService.sanitizeForLog(
        'ref=$reference platform=$platform '
        'screen=${tracker.currentScreen.name} '
        'operation=$cleanOp: $detail',
      );
      tracker.error(message, null, type: type);
      if (referenceOf(error) == null &&
          error is! String &&
          error is! num &&
          error is! bool) {
        _references[error] = reference;
      }
      logError('errors', tracker.privacy.clean(message, maxBytes: 600));
    } catch (_) {
      /* Reporting never breaks the operation that failed. */
    }
    return referenceOf(error) ?? reference;
  }

  /// Reports framework and platform errors. Previous handlers still run.
  void install() {
    if (_ownFlutter != null) return;
    _previousFlutter = FlutterError.onError;
    _ownFlutter = (details) {
      report(
        details.exception,
        details.stack,
        operation: 'framework',
        type: 'FlutterError',
      );
      _previousFlutter?.call(details);
    };
    FlutterError.onError = _ownFlutter;
    _previousPlatform = PlatformDispatcher.instance.onError;
    _ownPlatform = (error, stack) {
      report(error, stack, operation: 'platform', type: 'PlatformDispatcher');
      return _previousPlatform?.call(error, stack) ?? false;
    };
    PlatformDispatcher.instance.onError = _ownPlatform;
  }

  /// Restores the handlers that [install] replaced.
  void dispose() {
    if (_ownFlutter != null && FlutterError.onError == _ownFlutter) {
      FlutterError.onError = _previousFlutter;
    }
    if (_ownPlatform != null &&
        PlatformDispatcher.instance.onError == _ownPlatform) {
      PlatformDispatcher.instance.onError = _previousPlatform;
    }
    _ownFlutter = null;
    _ownPlatform = null;
  }
}
