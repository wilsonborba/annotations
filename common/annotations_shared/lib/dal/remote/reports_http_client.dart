import 'package:http/http.dart' as http;

import 'reports_http_client_stub.dart'
    if (dart.library.js_interop) 'reports_http_client_web.dart'
    as platform;

http.Client createReportsHttpClient() => platform.createReportsHttpClient();

Map<String, String> browserReportsHeaders({required bool mutation}) =>
    platform.browserReportsHeaders(mutation: mutation);
