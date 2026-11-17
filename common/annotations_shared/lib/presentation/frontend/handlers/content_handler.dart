import '../../../domain/models/content.dart';
import '../../../domain/services/annotations_service.dart';

class ContentHandler {
  final AnnotationsService service;
  ContentHandler(this.service);
  Future<Data> catalog() => service.catalog();
  Future<Data> articles({
    String query = '',
    String topic = '',
    String channel = '',
    int offset = 0,
  }) => service.posts(
    query: query,
    topic: topic,
    channel: channel,
    offset: offset,
  );
  Future<Data> article(
    String slug, {
    String language = '',
    String channel = '',
  }) => service.article(slug, language: language, channel: channel);
  Future<Data> preview(String url) => service.preview(url);
}
