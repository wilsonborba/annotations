import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../../dal/remote/fernet_token.dart';
import 'account_service.dart' show AccountStatus;
import 'native_auth_service.dart';

/// The account of an installed app (annotations#38 scope 2, with #36): the
/// FINAL native handoff. Sign in opens auth_apps in the system browser with
/// the handoff inside the encrypted app context; the app shows the match
/// code; the user presses Finish after the browser login. The state comes
/// from the stored session plus one live gateway check, never a flag; a
/// refused check signs out once.
class InstalledAccount extends ChangeNotifier {
  InstalledAccount({
    required this.auth,
    required this.client,
    required this.platform,
    required this.open,
    required this.aes,
    this.appContextKey = '',
    this.authBase = 'https://auth.asodya.com',
  });

  final NativeAuthService auth;
  final http.Client client;

  /// auth_apps platform name: linux, macos, android, ios or ipados.
  final String platform;

  /// Opens a URL in the system browser.
  final Future<void> Function(Uri uri) open;
  final AesCbcEncrypt aes;
  final String appContextKey;
  final String authBase;

  AccountStatus _status = AccountStatus.checking;
  AccountStatus get status => _status;
  bool get signedIn => _status == AccountStatus.signedIn;
  String _email = '', _userId = '';
  String get email => _email;

  /// The account id the notes are bound to (gateway user id).
  String get userId => _userId;

  /// The match code while a login waits for Finish, else null.
  String? get matchCode => auth.pendingHandoff?.matchCode;

  /// What the last login step said, as a stable kind the UI translates
  /// (never the English text of the service), or null.
  LoginNotice? notice;

  /// True while Finish waits for the gateway.
  bool finishing = false;

  NativeSession? _session;

  /// The session headers for the user's API calls, or null signed out.
  Map<String, String>? headers({bool mutation = false}) =>
      _session?.authHeaders(isMutation: mutation);

  Future<void> check() async {
    _session = await auth.storage.readSession();
    if (_session == null) return _set(AccountStatus.signedOut);
    try {
      final res = await client
          .get(
            Uri.parse('${auth.gatewayBaseUrl}/user/info/v1/'),
            headers: _session!.authHeaders(),
          )
          .timeout(const Duration(seconds: 15));
      if (res.statusCode == 200) {
        final data = (jsonDecode(utf8.decode(res.bodyBytes)) as Map)['data'];
        _email = data is Map ? '${data['email'] ?? ''}' : '';
        _userId = data is Map ? '${data['id'] ?? data['user_id'] ?? ''}' : '';
        return _set(AccountStatus.signedIn);
      }
      if (res.statusCode == 401 || res.statusCode == 403) return expire();
      // Another answer: keep the session, show it signed in only after a
      // real check; local writing keeps working.
      _set(AccountStatus.signedOut);
    } catch (_) {
      // Offline: local writing keeps working; sync waits for a check.
      _set(AccountStatus.signedOut);
    }
  }

  /// A refused call: the session is dead. Signed out once, no retry.
  Future<void> expire() async {
    auth.markSessionExpired();
    await auth.storage.deleteSession();
    _session = null;
    _set(AccountStatus.signedOut);
  }

  void _set(AccountStatus status) {
    if (status != AccountStatus.signedIn) _email = _userId = '';
    _status = status;
    notifyListeners();
  }

  /// The auth_apps login address with the handoff in the app context.
  Future<Uri> loginUri(PendingHandoff handoff) async {
    final context = jsonEncode({
      'name': 'Annotations',
      'description': 'Notes, drawing and Instant share by Asodya.',
      'logo_image_url': '',
      'url_app': '',
      'two_fa_auth': false,
      'primary_color': '#0B0C10',
      'secondary_color': '#12151E',
      'tertiary_color': '#A201FF',
      'quartary_color': null,
      'created_at': DateTime.now().toUtc().toIso8601String(),
      'handoff_id': handoff.handoffId,
      'challenge': handoff.challengeBase64Url,
      'platform': platform,
    });
    final token = await fernetEncrypt(appContextKey, context, aes: aes);
    return Uri.parse(
      authBase,
    ).replace(path: '/login', queryParameters: {'app_context': token});
  }

  /// Starts a login: a new handoff and the browser. Signed in, it does
  /// nothing.
  Future<void> startLogin() async {
    if (signedIn) return;
    notice = null;
    final handoff = auth.prepareHandoff();
    try {
      final uri = await loginUri(handoff);
      notifyListeners();
      await open(uri);
    } catch (_) {
      // No key in this build or no browser: say so, keep no handoff.
      auth.cancelPendingLogin();
      notice = const LoginNotice(LoginNoticeKind.unavailable);
      notifyListeners();
    }
  }

  /// One Finish check, on the user's click (never polled).
  Future<void> finish() async {
    if (finishing) return;
    finishing = true;
    notifyListeners();
    try {
      final result = await auth.finishLogin();
      notice = LoginNotice.fromResult(result);
      if (result.status == FinishLoginStatus.success) await check();
    } catch (_) {
      notice = const LoginNotice(LoginNoticeKind.failed);
    } finally {
      finishing = false;
      notifyListeners();
    }
  }

  void cancel() {
    auth.cancelPendingLogin();
    notice = null;
    notifyListeners();
  }

  /// Ends this device session; local notes stay (F2 point 6).
  Future<void> logOut() async {
    await auth.signOut();
    _session = null;
    _set(AccountStatus.signedOut);
  }
}

/// The auth_apps platform name of this installed app.
String handoffPlatform(TargetPlatform platform, {required bool fullWriter}) =>
    switch (platform) {
      TargetPlatform.macOS => 'macos',
      TargetPlatform.linux => 'linux',
      TargetPlatform.android => 'android',
      TargetPlatform.iOS => fullWriter ? 'ipados' : 'ios',
      _ => 'linux',
    };

/// An HTTP client that sends the installed session with each user call:
/// the session cookie always, the CSRF header on writes. A refused answer
/// (401 or 403) ends the session once.
class SessionClient extends http.BaseClient {
  SessionClient(this.account, this.inner);

  final InstalledAccount account;
  final http.Client inner;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final write = request.method != 'GET' && request.method != 'HEAD';
    request.headers.addAll(account.headers(mutation: write) ?? const {});
    final response = await inner.send(request);
    if (response.statusCode == 401 || response.statusCode == 403) {
      await account.expire();
    }
    return response;
  }
}

/// The kinds of login messages the installed sign-in shows (FINAL record
/// statuses plus "cannot start" and an unknown failure).
enum LoginNoticeKind {
  unavailable,
  success,
  notFinished,
  expired,
  used,
  cancelled,
  refused,
  invalid,
  disabled,
  failed,
}

/// One login message: its kind and, for a success, the login place.
final class LoginNotice {
  const LoginNotice(this.kind, {this.city, this.country});

  factory LoginNotice.fromResult(FinishLoginResult result) => LoginNotice(
    switch (result.status) {
      FinishLoginStatus.success => LoginNoticeKind.success,
      FinishLoginStatus.notFinished => LoginNoticeKind.notFinished,
      FinishLoginStatus.expired => LoginNoticeKind.expired,
      FinishLoginStatus.used => LoginNoticeKind.used,
      FinishLoginStatus.cancelled => LoginNoticeKind.cancelled,
      FinishLoginStatus.refused => LoginNoticeKind.refused,
      FinishLoginStatus.invalid => LoginNoticeKind.invalid,
      FinishLoginStatus.disabled => LoginNoticeKind.disabled,
    },
    city: result.city?.trim().isEmpty ?? true ? null : result.city!.trim(),
    country: result.country?.trim().isEmpty ?? true
        ? null
        : result.country!.trim(),
  );

  final LoginNoticeKind kind;
  final String? city, country;
}
