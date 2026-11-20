/// Pure-Dart log redaction helper (safe for CLI scripts without `dart:ui`).
///
/// Strips secrets, session IDs, CSRF tokens, cookies, and full handoff IDs from logs.
String sanitizeForLog(String raw) {
  var out = raw.replaceAllMapped(
    RegExp(
      r'(sid|csrf|secret|session_id|csrf_token|handoff_id|x-csrf-token)=([^&\s;]+)',
      caseSensitive: false,
    ),
    (m) => '${m.group(1)}=[REDACTED]',
  );
  out = out.replaceAllMapped(
    RegExp(
      r'("(?:session_id|csrf_token|secret|handoff_id)"\s*:\s*)"[^"]*"',
      caseSensitive: false,
    ),
    (m) => '${m.group(1)}"[REDACTED]"',
  );
  out = out.replaceAllMapped(
    RegExp(
      r'((?:cookie|set-cookie|x-csrf-token|authorization)\s*:\s*)[^\r\n]+',
      caseSensitive: false,
    ),
    (m) => '${m.group(1)}[REDACTED]',
  );
  return out;
}
