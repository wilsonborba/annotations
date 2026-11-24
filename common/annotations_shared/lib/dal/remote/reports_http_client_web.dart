import 'package:http/browser_client.dart';
import 'package:web/web.dart' as web;

BrowserClient createReportsHttpClient() =>
    BrowserClient()..withCredentials = true;

Map<String, String> browserReportsHeaders({required bool mutation}) {
  if (!mutation) return const {};
  final cookies = web.document.cookie;
  for (final cookie in cookies.split(';')) {
    final parts = cookie.trim().split('=');
    if (parts.length > 1 && parts.first == 'csrf') {
      return {'x-csrf-token': Uri.decodeComponent(parts.sublist(1).join('='))};
    }
  }
  return const {};
}
