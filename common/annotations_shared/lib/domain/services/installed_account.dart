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
  String _email = '';
  String get email => _email;

  /// The match code while a login waits for Finish, else null.
  String? get matchCode => auth.pendingHandoff?.matchCode;

  /// The last message of the FINAL record (Finish result), or null.
  String? message;

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
    if (status != AccountStatus.signedIn) _email = '';
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
    message = null;
    final handoff = auth.prepareHandoff();
    notifyListeners();
    await open(await loginUri(handoff));
  }

  /// One Finish check, on the user's click (never polled).
  Future<void> finish() async {
    if (finishing) return;
    finishing = true;
    notifyListeners();
    try {
      final result = await auth.finishLogin();
      message = result.message;
      if (result.status == FinishLoginStatus.success) await check();
    } catch (_) {
      message = 'Unable to finish login.';
    } finally {
      finishing = false;
      notifyListeners();
    }
  }

  void cancel() {
    auth.cancelPendingLogin();
    message = null;
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
