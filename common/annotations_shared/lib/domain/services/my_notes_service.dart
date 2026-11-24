import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../core/settings.dart';

/// One of the signed-in user's notes in the read-only browser list.
class MyNoteSummary {
  const MyNoteSummary({
    required this.id,
    required this.title,
    required this.updatedAt,
    required this.published,
  });

  factory MyNoteSummary.fromJson(Map<String, dynamic> json) => MyNoteSummary(
    id: '${json['note_id']}',
    title: (json['title'] as String?) ?? '',
    updatedAt: DateTime.fromMillisecondsSinceEpoch(
      ((json['updated_at'] as num?) ?? 0).toInt() * 1000,
    ),
    published: json['published'] != null && json['published'] != false,
  );

  final String id;

  /// Empty until the note is named: the list shows "Untitled note".
  final String title;
  final DateTime updatedAt;
  final bool published;
}

/// A refused or failed call; [status] 0 means no answer.
class MyNotesError implements Exception {
  const MyNotesError(this.status);
  final int status;
  bool get refused => status == 401 || status == 403;
}

/// `GET /me/notes` of annotations_api through the gateway, with the
/// session cookies (annotations#38 scope 7: browser My notes, read only).
class MyNotesService {
  MyNotesService({required this.client, String? apiBase})
    : apiBase = apiBase ?? Settings.current.apiBase;

  final http.Client client;
  final String apiBase;

  Future<List<MyNoteSummary>> list() async {
    final http.Response res;
    try {
      res = await client
          .get(Uri.parse('$apiBase/me/notes'))
          .timeout(const Duration(seconds: 20));
    } catch (_) {
      throw const MyNotesError(0);
    }
    if (res.statusCode != 200) throw MyNotesError(res.statusCode);
    final body = jsonDecode(utf8.decode(res.bodyBytes)) as Map;
    final items = (body['items'] ?? (body['data'] as Map?)?['items']) as List;
    return [
      for (final item in items)
        MyNoteSummary.fromJson(Map<String, dynamic>.from(item as Map)),
    ];
  }
}
