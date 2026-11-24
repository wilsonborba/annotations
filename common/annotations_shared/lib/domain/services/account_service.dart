import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../../core/settings.dart';
import '../../dal/remote/fernet_token.dart';

/// Where the account is: not known yet, signed out or signed in.
enum AccountStatus { checking, signedOut, signedIn }

/// An opaque binding to the browser session which started a private request.
final class AccountSessionGuard {
  const AccountSessionGuard._(this.revision, this._csrf);

  final int revision;
  final String? _csrf;
}

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
  int? _checkingGeneration;
  String? _checkingCsrf;
  int _sessionGeneration = 0;
  String? _sessionCsrf;
  Completer<void>? _exchangeInFlight;
  Future<void>? _loggingOut;

  /// Changes whenever a browser session is replaced, ended or refused.
  /// Private data requests bind their result to this value.
  int get sessionRevision => _sessionGeneration;

  AccountSessionGuard captureSessionGuard() =>
      AccountSessionGuard._(_sessionGeneration, platform.readCookie('csrf'));

  bool isCurrentSession(AccountSessionGuard guard) =>
      signedIn &&
      guard.revision == _sessionGeneration &&
      guard._csrf != null &&
      guard._csrf == platform.readCookie('csrf');

  /// Reads the live session once at a time.
  Future<void> check() {
    final ending = _loggingOut;
    if (ending != null) return ending.then((_) => check());
    final exchanging = _exchangeInFlight;
    if (exchanging != null) {
      return exchanging.future.then((_) => check());
    }

    final csrf = platform.readCookie('csrf');
    final current = _checking;
    if (current != null &&
        _checkingGeneration == _sessionGeneration &&
        _checkingCsrf == csrf) {
      return current;
    }

    if (current != null || csrf != _sessionCsrf) {
      _sessionGeneration++;
      _sessionCsrf = null;
      _set(csrf == null ? AccountStatus.signedOut : AccountStatus.checking);
    }

    final generation = _sessionGeneration;
    if (csrf == null) {
      _set(AccountStatus.signedOut);
      return Future<void>.value();
    }

    _checkingGeneration = generation;
    _checkingCsrf = csrf;
    late final Future<void> request;
    request = _check(generation, csrf).whenComplete(() {
      if (identical(_checking, request)) {
        _checking = null;
        _checkingGeneration = null;
        _checkingCsrf = null;
      }
    });
    _checking = request;
    return request;
  }

  bool _isCurrent(int generation, String csrf) =>
      generation == _sessionGeneration && platform.readCookie('csrf') == csrf;

  Future<void> _check(int generation, String csrf) async {
    try {
      final res = await _client
          .get(Uri.parse('$gateway/user/info/v1/'))
          .timeout(const Duration(seconds: 15));
      if (!_isCurrent(generation, csrf)) {
        if (generation == _sessionGeneration) unawaited(check());
        return;
      }
      if (res.statusCode == 200) {
        final data = (jsonDecode(utf8.decode(res.bodyBytes)) as Map)['data'];
        if (data is Map && '${data['email'] ?? ''}'.isNotEmpty) {
          final first = '${data['first_name'] ?? ''}'.trim();
          final last = '${data['last_name'] ?? ''}'.trim();
          _email = '${data['email']}';
          _name = [first, last].where((s) => s.isNotEmpty).join(' ');
          _sessionCsrf = csrf;
          _set(AccountStatus.signedIn);
          return;
        }
      }
      if (res.statusCode == 401 || res.statusCode == 403) {
        _expire(generation);
        return;
      }
      _set(AccountStatus.signedOut);
    } catch (_) {
      if (!_isCurrent(generation, csrf)) {
        if (generation == _sessionGeneration) unawaited(check());
        return;
      }
      // The gateway did not answer: show Sign in, keep the cookie, so the
      // next page load checks again.
      _set(AccountStatus.signedOut);
    }
  }

  /// A call was refused: the session is dead. Signed out once, no retry.
  void expire() {
    _sessionGeneration++;
    _sessionCsrf = null;
    platform.deleteCookie('csrf');
    _set(AccountStatus.signedOut);
  }

  /// Expires a refused private request only if it still belongs to the
  /// session that made it.
  void expireIfCurrent(AccountSessionGuard guard) {
    if (isCurrentSession(guard)) expire();
  }

  void _expire(int generation) {
    if (generation != _sessionGeneration) return;
    _sessionGeneration++;
    _sessionCsrf = null;
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
    while (true) {
      final ending = _loggingOut;
      if (ending != null) {
        await ending;
        continue;
      }
      final currentExchange = _exchangeInFlight;
      if (currentExchange != null) {
        await currentExchange.future;
        continue;
      }
      break;
    }
    final gate = Completer<void>();
    _exchangeInFlight = gate;
    final generation = ++_sessionGeneration;
    _sessionCsrf = null;
    _set(AccountStatus.checking);
    var exchanged = false;
    try {
      final res = await _client
          .post(
            Uri.parse('$gateway/apps/api/v1/exchange'),
            headers: const {'content-type': 'application/json'},
            body: jsonEncode({tokenParam: token, 'app': appIdentifier}),
          )
          .timeout(const Duration(seconds: 20));
      if (generation == _sessionGeneration && res.statusCode == 200) {
        exchanged = true;
      } else if (generation == _sessionGeneration) {
        _set(AccountStatus.signedOut);
      }
    } catch (_) {
      if (generation == _sessionGeneration) _set(AccountStatus.signedOut);
    } finally {
      if (identical(_exchangeInFlight, gate)) _exchangeInFlight = null;
      gate.complete();
    }
    if (!exchanged || generation != _sessionGeneration) return false;
    final exchangedCsrf = platform.readCookie('csrf');
    if (exchangedCsrf == null) return false;
    await check();
    return signedIn &&
        platform.readCookie('csrf') == exchangedCsrf &&
        _sessionCsrf == exchangedCsrf;
  }

  /// Ends this device session; public reading and Instant keep working.
  Future<void> logOut() {
    final current = _loggingOut;
    if (current != null) return current;

    final generation = ++_sessionGeneration;
    _sessionCsrf = null;
    _set(AccountStatus.signedOut);
    late final Future<void> request;
    request = _finishLogout(generation).whenComplete(() {
      if (identical(_loggingOut, request)) _loggingOut = null;
    });
    _loggingOut = request;
    return request;
  }

  Future<void> _finishLogout(int generation) async {
    final exchanging = _exchangeInFlight;
    if (exchanging != null) await exchanging.future;
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
    if (generation == _sessionGeneration) {
      platform.deleteCookie('csrf');
      _sessionCsrf = null;
      _set(AccountStatus.signedOut);
    }
  }
}
