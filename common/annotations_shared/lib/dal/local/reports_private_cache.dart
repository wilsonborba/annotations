import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';

abstract interface class ReportsPrivateCache {
  Future<Map<String, dynamic>?> read(String accountId, String logicalKey);
  Future<Map<String, dynamic>?> readActive(String logicalKey);
  Future<void> write(
    String accountId,
    String logicalKey,
    Map<String, dynamic> value,
  );
  Future<void> remove(String accountId, String logicalKey);
  Future<void> clear();
}

/// Account-scoped cache for viewer-authorized Reports pages and snapshots.
/// Clearing this store never removes note files, drafts, or other preferences.
final class PreferencesReportsPrivateCache implements ReportsPrivateCache {
  static const _prefix = 'annotations.reports.restricted.v1.';
  static const _activeAccountKey = '${_prefix}active_account';

  final Future<SharedPreferences> Function() _preferences;

  PreferencesReportsPrivateCache({
    Future<SharedPreferences> Function()? preferences,
  }) : _preferences = preferences ?? SharedPreferences.getInstance;

  String _digest(String value) => sha256.convert(utf8.encode(value)).toString();

  String _keyFromHash(String accountHash, String logicalKey) =>
      '$_prefix$accountHash.${_digest(logicalKey)}';

  String _key(String accountId, String logicalKey) =>
      _keyFromHash(_digest(accountId), logicalKey);

  Future<void> bindAccount(String accountId) async {
    final prefs = await _preferences();
    final accountHash = _digest(accountId);
    final existing = prefs.getString(_activeAccountKey);
    if (existing != null && existing != accountHash) {
      for (final key in prefs.getKeys().where((k) => k.startsWith(_prefix))) {
        await prefs.remove(key);
      }
    }
    await prefs.setString(_activeAccountKey, accountHash);
  }

  @override
  Future<Map<String, dynamic>?> read(
    String accountId,
    String logicalKey,
  ) async {
    final prefs = await _preferences();
    if (prefs.getString(_activeAccountKey) != _digest(accountId)) return null;
    final raw = prefs.getString(_key(accountId, logicalKey));
    return _decode(raw, _key(accountId, logicalKey), prefs);
  }

  @override
  Future<Map<String, dynamic>?> readActive(String logicalKey) async {
    final prefs = await _preferences();
    final accountHash = prefs.getString(_activeAccountKey);
    if (accountHash == null) return null;
    final key = _keyFromHash(accountHash, logicalKey);
    return _decode(prefs.getString(key), key, prefs);
  }

  Future<Map<String, dynamic>?> _decode(
    String? raw,
    String storageKey,
    SharedPreferences prefs,
  ) async {
    if (raw == null) return null;
    try {
      final value = jsonDecode(raw);
      return value is Map<String, dynamic> ? value : null;
    } on FormatException {
      await prefs.remove(storageKey);
      return null;
    }
  }

  @override
  Future<void> write(
    String accountId,
    String logicalKey,
    Map<String, dynamic> value,
  ) async {
    await bindAccount(accountId);
    final prefs = await _preferences();
    await prefs.setString(_key(accountId, logicalKey), jsonEncode(value));
  }

  @override
  Future<void> remove(String accountId, String logicalKey) async {
    final prefs = await _preferences();
    await prefs.remove(_key(accountId, logicalKey));
  }

  @override
  Future<void> clear() async {
    final prefs = await _preferences();
    for (final key in prefs.getKeys().where((k) => k.startsWith(_prefix))) {
      await prefs.remove(key);
    }
  }
}
