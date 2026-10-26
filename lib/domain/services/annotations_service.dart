import '../../dal/remote/api_adapter.dart';
import '../models/content.dart';

class AnnotationsService {
  final ApiAdapter api;
  AnnotationsService({ApiAdapter? api}) : api = api ?? ApiAdapter();
  Future<Data> catalog() => api.request('/catalog');
  Future<Data> posts({
    String query = '',
    String topic = '',
    String channel = '',
    int offset = 0,
  }) => api.request(
    '/posts',
    query: {
      'q': query,
      'topic': topic,
      'channel': channel,
      'offset': '$offset',
    },
  );
  Future<Data> article(
    String slug, {
    String language = '',
    String channel = '',
  }) => api.request(
    '/posts/${Uri.encodeComponent(slug)}',
    query: {
      if (language.isNotEmpty) 'lang': language,
      if (channel.isNotEmpty) 'channel': channel,
    },
  );
  Future<Data> preview(String url) =>
      api.request('/links/preview', query: {'url': url});
  Future<Data> waitlist(String email, String message) => api.request(
    '/waitlist',
    method: 'POST',
    body: {'email': email, 'message': message},
  );
  Future<Data> room(String code, {bool create = false}) => api.request(
    '/instant/${Uri.encodeComponent(code)}',
    method: create ? 'PUT' : 'GET',
  );
  Future<Data> edit(
    String code,
    String text, {
    String? id,
    int? revision,
    String kind = 'text',
  }) => api.request(
    '/instant/${Uri.encodeComponent(code)}/items',
    method: 'POST',
    body: {
      'kind': kind,
      'text': text,
      'id': ?id,
      'revision': ?revision,
    },
  );
}
