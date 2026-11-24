import 'package:http/http.dart' as http;

/// Browser session helpers (annotations#38). Outside a browser there are no
/// cookies and no page origin: the installed apps use the native handoff.

/// The value of the readable cookie [name], or null.
String? readCookie(String name) => null;

/// Removes the readable cookie [name] from this site.
void deleteCookie(String name) {}

/// The origin of the page, such as `https://annotations.asodya.com`.
String currentOrigin() => '';

/// Replaces the address shown in the browser without a reload.
void replaceAddress(String path) {}

/// An HTTP client that sends the session cookies to the gateway.
http.Client createCredentialsClient() => http.Client();
