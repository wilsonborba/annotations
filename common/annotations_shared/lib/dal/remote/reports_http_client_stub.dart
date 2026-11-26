import 'package:http/http.dart' as http;

http.Client createReportsHttpClient() => http.Client();

Map<String, String> browserReportsHeaders({required bool mutation}) => const {};
