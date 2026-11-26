import '../services/installed_account.dart';

/// A short-lived, live-verified account snapshot for transcription requests.
/// Callers must not persist its headers or session tokens.
final class TranscriptionSession {
  const TranscriptionSession({
    required this.accountId,
    required this.readHeaders,
    required this.mutationHeaders,
    required this.isCurrent,
  });

  final String accountId;
  final Map<String, String> readHeaders;
  final Map<String, String> mutationHeaders;
  final bool Function() isCurrent;

  Map<String, String> headers({required bool mutation}) =>
      mutation ? mutationHeaders : readHeaders;

  void requireCurrent() {
    if (!isCurrent()) throw const TranscriptionSessionChangedException();
  }

  /// Use only after InstalledAccount has completed its live gateway check.
  static TranscriptionSession? fromInstalledAccount(InstalledAccount account) {
    final userId = account.userId;
    final native = account.activeSession;
    if (!account.signedIn ||
        userId.trim().isEmpty ||
        native == null ||
        native.verifiedUserId != userId) {
      return null;
    }
    final sessionId = native.sessionId;
    final csrfToken = native.csrfToken;
    bool current() {
      final active = account.activeSession;
      return account.signedIn &&
          account.userId == userId &&
          active?.verifiedUserId == userId &&
          active?.sessionId == sessionId &&
          active?.csrfToken == csrfToken;
    }

    return TranscriptionSession(
      accountId: userId,
      readHeaders: Map.unmodifiable(native.authHeaders()),
      mutationHeaders: Map.unmodifiable(native.authHeaders(isMutation: true)),
      isCurrent: current,
    );
  }
}

final class TranscriptionSessionChangedException implements Exception {
  const TranscriptionSessionChangedException();
}

final class TranscriptionSignInRequiredException implements Exception {
  const TranscriptionSignInRequiredException();
}

/// A callback that returns a verified, current account or null while signed out.
typedef TranscriptionSessionProvider = Future<TranscriptionSession?> Function();

/// Builds a provider from the app's live installed-account controller.
TranscriptionSessionProvider installedTranscriptionSessionProvider(
  InstalledAccount account,
) =>
    () async => TranscriptionSession.fromInstalledAccount(account);
