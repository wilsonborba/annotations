import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import '../../core/log_redactor.dart' as redactor;
import '../../dal/local/reports_private_cache.dart';

class SecureStorageUnavailableException implements Exception {
  final String message;
  const SecureStorageUnavailableException([
    this.message = 'OS secure storage is unavailable; sign in again.',
  ]);
  @override
  String toString() => message;
}

final class NativeSession {
  final String sessionId;
  final String csrfToken;
  final String? locationMessage;

  const NativeSession({
    required this.sessionId,
    required this.csrfToken,
    this.locationMessage,
  });

  Map<String, String> authHeaders({bool isMutation = false}) => {
    'cookie': 'sid=$sessionId; csrf=$csrfToken',
    if (isMutation) 'x-csrf-token': csrfToken,
  };
}

/// OS secure storage abstraction (Keychain, Android Keystore, libsecret).
/// Never falls back to plain preferences.
abstract interface class SecureSessionStorage {
  Future<void> writeSession(NativeSession session);
  Future<NativeSession?> readSession();
  Future<void> deleteSession();
}

final class OsSecureSessionStorage implements SecureSessionStorage {
  static const _channel = MethodChannel(
    'com.asodya.annotations/secure_storage',
  );

  @override
  Future<void> writeSession(NativeSession session) async {
    try {
      await _channel.invokeMethod('write', {
        'session_id': session.sessionId,
        'csrf_token': session.csrfToken,
      });
    } on MissingPluginException {
      throw const SecureStorageUnavailableException();
    } on PlatformException {
      throw const SecureStorageUnavailableException();
    }
  }

  @override
  Future<NativeSession?> readSession() async {
    try {
      final raw = await _channel.invokeMapMethod<String, dynamic>('read');
      if (raw == null) return null;
      final sid = raw['session_id'] as String?;
      final csrf = raw['csrf_token'] as String?;
      if (sid == null || sid.isEmpty || csrf == null || csrf.isEmpty) {
        return null;
      }
      return NativeSession(sessionId: sid, csrfToken: csrf);
    } on MissingPluginException {
      throw const SecureStorageUnavailableException();
    } on PlatformException {
      throw const SecureStorageUnavailableException();
    }
  }

  @override
  Future<void> deleteSession() async {
    try {
      await _channel.invokeMethod('delete');
    } on MissingPluginException {
      throw const SecureStorageUnavailableException();
    } on PlatformException {
      throw const SecureStorageUnavailableException();
    }
  }
}

final class InMemorySecureSessionStorage implements SecureSessionStorage {
  NativeSession? _session;

  @override
  Future<void> writeSession(NativeSession session) async {
    _session = session;
  }

  @override
  Future<NativeSession?> readSession() async => _session;

  @override
  Future<void> deleteSession() async {
    _session = null;
  }
}

final class PendingHandoff {
  final String handoffId;
  final Uint8List secretBytes;
  final String secretBase64Url;
  final String challengeBase64Url;
  final String matchCode;
  final DateTime startedAt;

  const PendingHandoff({
    required this.handoffId,
    required this.secretBytes,
    required this.secretBase64Url,
    required this.challengeBase64Url,
    required this.matchCode,
    required this.startedAt,
  });
}

enum FinishLoginStatus {
  success,
  notFinished,
  expired,
  used,
  cancelled,
  refused,
  invalid,
  disabled,
}

final class FinishLoginResult {
  final FinishLoginStatus status;
  final String message;
  final NativeSession? session;

  const FinishLoginResult({
    required this.status,
    required this.message,
    this.session,
  });
}

/// Installed-app FINAL v2 native handoff login and secure session manager (annotations#36).
class NativeAuthService {
  final http.Client client;
  final SecureSessionStorage storage;
  final String gatewayBaseUrl;

  PendingHandoff? pendingHandoff;
  bool sessionPaused = false;
  bool pendingServerRevocation = false;

  bool get canWriteLocal => true;

  NativeAuthService({
    http.Client? client,
    required this.storage,
    this.gatewayBaseUrl = 'https://api.asodya.com',
  }) : client = client ?? http.Client();

  static String _base64UrlNoPad(List<int> bytes) =>
      base64UrlEncode(bytes).replaceAll('=', '');

  static Uint8List _decodeBase64Url(String input) {
    final padLen = (4 - input.length % 4) % 4;
    return base64Url.decode(input + ('=' * padLen));
  }

  /// First 4 uppercase RFC 4648 base32 characters of the 32 decoded challenge bytes.
  static String matchCodeFromChallenge(String challengeBase64Url) {
    const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
    final bytes = _decodeBase64Url(challengeBase64Url);
    if (bytes.length < 3) return '';
    // 4 base32 chars consume 20 bits (2.5 bytes).
    final bits = (bytes[0] << 16) | (bytes[1] << 8) | bytes[2];
    return String.fromCharCodes([
      alphabet.codeUnitAt((bits >> 19) & 0x1F),
      alphabet.codeUnitAt((bits >> 14) & 0x1F),
      alphabet.codeUnitAt((bits >> 9) & 0x1F),
      alphabet.codeUnitAt((bits >> 4) & 0x1F),
    ]);
  }

  /// Prepares handoff id (32B), secret (32B), raw SHA-256 challenge, and match code.
  PendingHandoff prepareHandoff({
    Uint8List? secretOverride,
    Uint8List? handoffIdOverride,
    DateTime? now,
  }) {
    final rng = Random.secure();
    final idBytes =
        handoffIdOverride ??
        Uint8List.fromList(List<int>.generate(32, (_) => rng.nextInt(256)));
    final secBytes =
        secretOverride ??
        Uint8List.fromList(List<int>.generate(32, (_) => rng.nextInt(256)));

    final challengeBytes = sha256.convert(secBytes).bytes;
    final challenge = _base64UrlNoPad(challengeBytes);
    final handoff = PendingHandoff(
      handoffId: _base64UrlNoPad(idBytes),
      secretBytes: secBytes,
      secretBase64Url: _base64UrlNoPad(secBytes),
      challengeBase64Url: challenge,
      matchCode: matchCodeFromChallenge(challenge),
      startedAt: now ?? DateTime.now().toUtc(),
    );
    pendingHandoff = handoff;
    return handoff;
  }

  void cancelPendingLogin() {
    pendingHandoff = null;
  }

  static String formatLoggedInMessage({String? city, String? country}) {
    final c = city?.trim() ?? '';
    final co = country?.trim() ?? '';
    if (c.isNotEmpty && co.isNotEmpty) return 'Logged in from $c, $co';
    if (co.isNotEmpty) return 'Logged in from $co';
    return 'Logged in';
  }

  /// One-shot Finish check (called on user Finish click or app resume; never polled).
  Future<FinishLoginResult> finishLogin({DateTime? now}) async {
    final handoff = pendingHandoff;
    if (handoff == null) {
      return const FinishLoginResult(
        status: FinishLoginStatus.used,
        message: 'Start again.',
      );
    }
    final current = now ?? DateTime.now().toUtc();
    if (current.difference(handoff.startedAt) >= const Duration(minutes: 30)) {
      pendingHandoff = null;
      return const FinishLoginResult(
        status: FinishLoginStatus.expired,
        message: 'This login expired. Start again.',
      );
    }

    final resp = await client.post(
      Uri.parse('$gatewayBaseUrl/apps/api/v1/exchange'),
      headers: {'content-type': 'application/json'},
      body: jsonEncode({
        'app': 'annotations',
        'handoff_id': handoff.handoffId,
        'secret': handoff.secretBase64Url,
      }),
    );

    Map<String, dynamic> json;
    try {
      json = jsonDecode(resp.body) as Map<String, dynamic>;
    } catch (_) {
      return const FinishLoginResult(
        status: FinishLoginStatus.notFinished,
        message:
            'The login is not finished. Finish it in the browser, then click Finish.',
      );
    }

    final dataMap = json['data'] is Map
        ? Map<String, dynamic>.from(json['data'] as Map)
        : const <String, dynamic>{};
    final gatewayCode = '${dataMap['code'] ?? ''}'.toUpperCase();

    if (resp.statusCode >= 400 ||
        gatewayCode.isNotEmpty && !dataMap.containsKey('session_id')) {
      switch (gatewayCode) {
        case 'HANDOFF_NOT_FINISHED':
          // Keep pendingHandoff so the user can finish in the browser and click Finish again.
          return const FinishLoginResult(
            status: FinishLoginStatus.notFinished,
            message:
                'The login is not finished. Finish it in the browser, then click Finish.',
          );
        case 'HANDOFF_EXPIRED':
          pendingHandoff = null;
          return const FinishLoginResult(
            status: FinishLoginStatus.expired,
            message: 'This login expired. Start again.',
          );
        case 'HANDOFF_USED':
          pendingHandoff = null;
          return const FinishLoginResult(
            status: FinishLoginStatus.used,
            message: 'Start again.',
          );
        case 'HANDOFF_CANCELLED':
          pendingHandoff = null;
          return const FinishLoginResult(
            status: FinishLoginStatus.cancelled,
            message: 'Login cancelled. Start again.',
          );
        case 'LOGIN_REFUSED_NETWORK':
          pendingHandoff = null;
          return const FinishLoginResult(
            status: FinishLoginStatus.refused,
            message: 'Login refused. The login came from a different location.',
          );
        case 'INVALID_HANDOFF':
          pendingHandoff = null;
          return const FinishLoginResult(
            status: FinishLoginStatus.invalid,
            message: 'Invalid installed-app login fields.',
          );
        case 'NATIVE_HANDOFF_DISABLED':
          pendingHandoff = null;
          return const FinishLoginResult(
            status: FinishLoginStatus.disabled,
            message: 'Installed-app login is disabled.',
          );
        default:
          if (resp.statusCode >= 500) {
            return const FinishLoginResult(
              status: FinishLoginStatus.notFinished,
              message: 'Unable to finish login.',
            );
          }
          pendingHandoff = null;
          return const FinishLoginResult(
            status: FinishLoginStatus.used,
            message: 'Start again.',
          );
      }
    }

    final location = dataMap['location'] is Map
        ? Map<String, dynamic>.from(dataMap['location'] as Map)
        : dataMap;
    final locMsg = formatLoggedInMessage(
      city: location['city'] as String?,
      country: location['country'] as String?,
    );
    final session = NativeSession(
      sessionId: '${dataMap['session_id'] ?? json['session_id'] ?? ''}',
      csrfToken: '${dataMap['csrf_token'] ?? json['csrf_token'] ?? ''}',
      locationMessage: locMsg,
    );
    await storage.writeSession(session);
    sessionPaused = false;
    pendingServerRevocation = false;
    pendingHandoff = null;
    return FinishLoginResult(
      status: FinishLoginStatus.success,
      message: locMsg,
      session: session,
    );
  }

  /// Signs out only this device session, keeping local notes untouched.
  /// Works immediately when offline with `pendingServerRevocation = true`.
  Future<void> signOut() async {
    final existing = await storage.readSession();
    await storage.deleteSession();
    await PreferencesReportsPrivateCache().clear();
    sessionPaused = false;
    if (existing == null) return;
    try {
      await client.post(
        Uri.parse('$gatewayBaseUrl/user/sync/v1/log-out'),
        headers: existing.authHeaders(isMutation: true),
      );
      pendingServerRevocation = false;
    } catch (_) {
      pendingServerRevocation = true;
    }
  }

  void markSessionExpired() {
    sessionPaused = true;
  }

  /// Strips secrets, session IDs, CSRF tokens, cookies, and full handoff IDs from logs.
  static String sanitizeForLog(String raw) => redactor.sanitizeForLog(raw);
}
