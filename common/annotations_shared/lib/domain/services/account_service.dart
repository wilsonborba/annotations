import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../../core/settings.dart';
import '../../dal/remote/fernet_token.dart';

/// Where the account is: not known yet, signed out or signed in.
enum AccountStatus { checking, signedOut, signedIn }

/// The browser cookie, page and launch operations the account needs. The
/// browser gives the real ones; tests give fakes.
class SessionPlatform {
  const SessionPlatform({
    required this.readCookie,
    required this.deleteCookie,
    required this.origin,
    required this.open,
    required this.aes,
  });

  final String? Function(String name) readCookie;
  final void Function(String name) deleteCookie;
  final String Function() origin;

  /// Opens [uri] in this tab (the auth_apps login).
  final Future<void> Function(Uri uri) open;
  final AesCbcEncrypt aes;
}

/// The browser account of Annotations (annotations#38, F2, H6 section 3
/// point 2), with the central login of every Asodya app:
/// 1. [signIn] keeps the page to come back to and opens auth_apps with an
///    encrypted `app_context` (Annotations and this origin).
/// 2. auth_apps returns to `<origin>/sync?auth_exchange_token=...`.
/// 3. [exchange] redeems the one-time token at `POST /apps/api/v1/exchange`;
///    the gateway sets the httpOnly `sid` and the readable `csrf` cookies.
/// 4. [check] asks the gateway who is signed in (`GET /user/info/v1/`).
/// 5. [logOut] ends the session at `POST /user/sync/v1/log-out`.
///
/// The state is never a stored flag (Cortex #21): without the `csrf` cookie
/// there is no session; with it, one gateway check decides. A refused call
/// (401 or 403) means the session is dead: the state becomes signed out
/// once, the cookie goes, and nothing retries (Cortex #76).
class AccountService extends ChangeNotifier {
  AccountService({
    required http.Client client,
    required this.platform,
    String? gateway,
    this.appContextKey = '',
    this.authBase = defaultAuthBase,
  }) : _client = client,
       gateway = gateway ?? Uri.parse(Settings.current.apiBase).origin;

  static const defaultAuthBase = 'https://auth.asodya.com';
  static const appIdentifier = 'annotations';
  static const syncPath = '/sync';
  static const tokenParam = 'auth_exchange_token';

  final http.Client _client;
  final SessionPlatform platform;

  /// The gateway origin, such as `https://api.asodya.com`.
  final String gateway;

  /// The shared key that encrypts the app context for auth_apps.
  final String appContextKey;

  /// The auth_apps origin.
  final String authBase;

  AccountStatus _status = AccountStatus.checking;
  AccountStatus get status => _status;
  String _email = '', _name = '';

  /// The signed-in email, empty when signed out.
  String get email => _email;

  /// The signed-in name, empty when unknown.
  String get name => _name;
  bool get signedIn => _status == AccountStatus.signedIn;

  Future<void>? _checking;

  /// Reads the live session once at a time.
  Future<void> check() =>
      _checking ??= _check().whenComplete(() => _checking = null);

  Future<void> _check() async {
    final csrf = platform.readCookie('csrf');
    if (csrf == null) {
      _set(AccountStatus.signedOut);
      return;
    }
    try {
      final res = await _client
          .get(Uri.parse('$gateway/user/info/v1/'))
          .timeout(const Duration(seconds: 15));
      if (res.statusCode == 200) {
        final data = (jsonDecode(utf8.decode(res.bodyBytes)) as Map)['data'];
        if (data is Map && '${data['email'] ?? ''}'.isNotEmpty) {
          final first = '${data['first_name'] ?? ''}'.trim();
          final last = '${data['last_name'] ?? ''}'.trim();
          _email = '${data['email']}';
          _name = [first, last].where((s) => s.isNotEmpty).join(' ');
          _set(AccountStatus.signedIn);
          return;
        }
      }
      if (res.statusCode == 401 || res.statusCode == 403) {
        expire();
        return;
      }
      _set(AccountStatus.signedOut);
    } catch (_) {
      // The gateway did not answer: show Sign in, keep the cookie, so the
      // next page load checks again.
      _set(AccountStatus.signedOut);
    }
  }

  /// A call was refused: the session is dead. Signed out once, no retry.
  void expire() {
    platform.deleteCookie('csrf');
    _set(AccountStatus.signedOut);
  }

  void _set(AccountStatus status) {
    if (status != AccountStatus.signedIn) _email = _name = '';
    _status = status;
    notifyListeners();
  }

  /// The internal page to show after a login: a path under /v1, else
  /// My notes.
  static String safeNext(String? next) {
    final n = (next ?? '').trim();
    final internal =
        n.startsWith('/v1/') &&
        !n.contains('//') &&
        !n.contains('..') &&
        !n.contains('\\') &&
        !n.contains(':');
    return internal ? n : myNotesPath;
  }

  static const myNotesPath = '/v1/me/notes';

  /// The auth_apps login address for this app.
  Future<Uri> loginUri() async {
    final origin = platform.origin();
    final context = jsonEncode({
      'name': 'Annotations',
      'description': 'Notes, drawing and Instant share by Asodya.',
      'logo_image_url': '$origin/icons/Icon-192.png',
      'url_app': origin,
      'two_fa_auth': false,
      'primary_color': '#0B0C10',
      'secondary_color': '#12151E',
      'tertiary_color': '#A201FF',
      'quartary_color': null,
      'created_at': DateTime.now().toUtc().toIso8601String(),
    });
    final token = await fernetEncrypt(
      appContextKey,
      context,
      aes: platform.aes,
    );
    return Uri.parse(
      authBase,
    ).replace(path: '/login', queryParameters: {'app_context': token});
  }

  /// Starts the login and returns to [returnTo] afterwards. Signed in, it
  /// does nothing: the caller opens the signed-in page instead.
  Future<void> signIn({
    String? returnTo,
    required Future<void> Function(String) keepNext,
  }) async {
    if (signedIn) return;
    await keepNext(safeNext(returnTo));
    await platform.open(await loginUri());
  }

  /// Redeems the one-time token, then reads the account. True when a
  /// session opened.
  Future<bool> exchange(String token) async {
    try {
      final res = await _client
          .post(
            Uri.parse('$gateway/apps/api/v1/exchange'),
            headers: const {'content-type': 'application/json'},
            body: jsonEncode({tokenParam: token, 'app': appIdentifier}),
          )
          .timeout(const Duration(seconds: 20));
      if (res.statusCode != 200) return false;
    } catch (_) {
      return false;
    }
    await check();
    return signedIn;
  }

  /// Ends this device session; public reading and Instant keep working.
  Future<void> logOut() async {
    final csrf = platform.readCookie('csrf');
    try {
      await _client
          .post(
            Uri.parse('$gateway/user/sync/v1/log-out'),
            headers: {'X-CSRF-Token': ?csrf},
          )
          .timeout(const Duration(seconds: 15));
    } catch (_) {
      // The local state goes anyway.
    }
    expire();
  }
}
