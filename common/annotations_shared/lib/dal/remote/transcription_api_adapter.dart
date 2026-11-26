import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../domain/models/transcription_session.dart';
import 'api_adapter.dart';

final class ModelArtifactManifest {
  const ModelArtifactManifest({
    required this.platform,
    required this.size,
    required this.sha256,
  });

  final String platform;
  final int size;
  final String sha256;

  factory ModelArtifactManifest.fromJson(Map<String, dynamic> json) {
    final platform = json['platform'];
    final size = json['size'];
    final hash = json['sha256'];
    if (platform is! String ||
        !_platforms.contains(platform) ||
        size is! int ||
        size <= 0 ||
        hash is! String ||
        !_sha256.hasMatch(hash)) {
      throw const FormatException('Invalid model artifact manifest.');
    }
    return ModelArtifactManifest(platform: platform, size: size, sha256: hash);
  }
}

final class ModelReleaseManifest {
  const ModelReleaseManifest({
    required this.version,
    required this.status,
    required this.isDefault,
    required this.createdAt,
    required this.artifacts,
    required this.languages,
    required this.capabilities,
  });

  final String version;
  final String status;
  final bool isDefault;
  final int createdAt;
  final List<ModelArtifactManifest> artifacts;
  final List<String> languages;
  final List<String> capabilities;

  ModelArtifactManifest? artifactFor(String platform) {
    for (final artifact in artifacts) {
      if (artifact.platform == platform) return artifact;
    }
    return null;
  }

  factory ModelReleaseManifest.fromJson(Map<String, dynamic> json) {
    final version = json['version'];
    final status = json['status'];
    final createdAt = json['created_at'];
    final rawArtifacts = json['artifacts'];
    final rawLanguages = json['languages'];
    final rawCapabilities = json['capabilities'];
    if (version is! String ||
        !_token.hasMatch(version) ||
        status is! String ||
        createdAt is! int ||
        rawArtifacts is! List ||
        rawLanguages is! List ||
        rawCapabilities is! List ||
        json['is_default'] is! bool) {
      throw const FormatException('Invalid model release manifest.');
    }
    final artifacts = rawArtifacts
        .whereType<Map>()
        .map(
          (value) =>
              ModelArtifactManifest.fromJson(Map<String, dynamic>.from(value)),
        )
        .toList(growable: false);
    if (artifacts.length != rawArtifacts.length ||
        artifacts.isEmpty ||
        artifacts.map((item) => item.platform).toSet().length !=
            artifacts.length) {
      throw const FormatException('Invalid model release artifacts.');
    }
    final languages = rawLanguages.whereType<String>().toList(growable: false);
    final capabilities = rawCapabilities.whereType<String>().toList(
      growable: false,
    );
    if (languages.length != rawLanguages.length ||
        capabilities.length != rawCapabilities.length ||
        languages.isEmpty ||
        languages.any((value) => !_languages.contains(value))) {
      throw const FormatException('Invalid model release capabilities.');
    }
    return ModelReleaseManifest(
      version: version,
      status: status,
      isDefault: json['is_default'] as bool,
      createdAt: createdAt,
      artifacts: artifacts,
      languages: languages,
      capabilities: capabilities,
    );
  }
}

final class ModelListing {
  const ModelListing({required this.defaultVersion, required this.models});

  final String? defaultVersion;
  final List<ModelReleaseManifest> models;

  factory ModelListing.fromJson(Map<String, dynamic> json) {
    final raw = json['models'];
    if (raw is! List) throw const FormatException('Invalid model listing.');
    final models = raw
        .whereType<Map>()
        .map(
          (value) =>
              ModelReleaseManifest.fromJson(Map<String, dynamic>.from(value)),
        )
        .toList(growable: false);
    if (models.length != raw.length) {
      throw const FormatException('Invalid model listing.');
    }
    final defaultVersion = json['default_version'];
    if (defaultVersion != null && defaultVersion is! String) {
      throw const FormatException('Invalid default model version.');
    }
    return ModelListing(
      defaultVersion: defaultVersion as String?,
      models: models,
    );
  }
}

final class ModelDownloadGrant {
  const ModelDownloadGrant({
    required this.downloadId,
    required this.modelVersion,
    required this.platform,
    required this.size,
    required this.sha256,
    required this.modelStatus,
    required this.createdAt,
  });

  final String downloadId;
  final String modelVersion;
  final String platform;
  final int size;
  final String sha256;
  final String modelStatus;
  final int createdAt;

  factory ModelDownloadGrant.fromJson(Map<String, dynamic> json) {
    final id = json['download_id'];
    final version = json['model_version'];
    final platform = json['platform'];
    final size = json['size'];
    final hash = json['sha256'];
    final status = json['model_status'];
    final createdAt = json['created_at'];
    if (id is! String ||
        !_visible.hasMatch(id) ||
        version is! String ||
        !_token.hasMatch(version) ||
        platform is! String ||
        !_platforms.contains(platform) ||
        size is! int ||
        size <= 0 ||
        hash is! String ||
        !_sha256.hasMatch(hash) ||
        status is! String ||
        createdAt is! int) {
      throw const FormatException('Invalid model download response.');
    }
    return ModelDownloadGrant(
      downloadId: id,
      modelVersion: version,
      platform: platform,
      size: size,
      sha256: hash,
      modelStatus: status,
      createdAt: createdAt,
    );
  }
}

final class TranscriptionRun {
  const TranscriptionRun({
    required this.runId,
    required this.downloadId,
    required this.modelVersion,
    required this.platform,
    required this.language,
    required this.mode,
    required this.status,
    required this.sourceStale,
    required this.lastEventId,
    required this.result,
    required this.sourceNoteId,
    required this.sourceRevisionId,
    required this.sourceHash,
  });

  final String runId;
  final String downloadId;
  final String modelVersion;
  final String platform;
  final String language;
  final String mode;
  final String status;
  final bool sourceStale;
  final int lastEventId;
  final Map<String, dynamic>? result;
  final String? sourceNoteId;
  final String? sourceRevisionId;
  final String? sourceHash;

  factory TranscriptionRun.fromJson(Map<String, dynamic> json) {
    final result = json['result'];
    if (json['run_id'] is! String ||
        json['download_id'] is! String ||
        json['model_version'] is! String ||
        json['platform'] is! String ||
        json['language'] is! String ||
        json['mode'] is! String ||
        json['status'] is! String ||
        json['source_stale'] is! bool ||
        json['last_event_id'] is! int ||
        (result != null && result is! Map)) {
      throw const FormatException('Invalid transcription run response.');
    }
    return TranscriptionRun(
      runId: json['run_id'] as String,
      downloadId: json['download_id'] as String,
      modelVersion: json['model_version'] as String,
      platform: json['platform'] as String,
      language: json['language'] as String,
      mode: json['mode'] as String,
      status: json['status'] as String,
      sourceStale: json['source_stale'] as bool,
      lastEventId: json['last_event_id'] as int,
      result: result == null ? null : Map<String, dynamic>.from(result as Map),
      sourceNoteId: json['source_note_id'] as String?,
      sourceRevisionId: json['source_revision_id'] as String?,
      sourceHash: json['source_hash'] as String?,
    );
  }
}

final class TranscriptionEvent {
  const TranscriptionEvent({
    required this.id,
    required this.stage,
    required this.data,
  });

  final int id;
  final String stage;
  final Map<String, dynamic> data;
}

/// Client for the closed annotations_api model, transcription and feedback routes.
/// The caller supplies short-lived gateway headers from a verified account.
final class TranscriptionApiAdapter {
  TranscriptionApiAdapter(this.api);

  final ApiAdapter api;

  Future<ModelListing> listModels(
    TranscriptionSession session, {
    required String platform,
    String? language,
  }) async {
    session.requireCurrent();
    return ModelListing.fromJson(
      await api.request(
        '/models',
        query: {'platform': platform, 'language': ?language},
        headers: session.headers(mutation: false),
      ),
    );
  }

  Future<ModelReleaseManifest> getModel(
    TranscriptionSession session,
    String version,
  ) async {
    _requireToken(version, 'model version');
    session.requireCurrent();
    return ModelReleaseManifest.fromJson(
      await api.request(
        '/models/${Uri.encodeComponent(version)}',
        headers: session.headers(mutation: false),
      ),
    );
  }

  Future<ModelDownloadGrant> createDownload(
    TranscriptionSession session, {
    required String modelVersion,
    required String platform,
  }) async {
    _requireToken(modelVersion, 'model version');
    if (!_platforms.contains(platform)) {
      throw ArgumentError.value(platform, 'platform');
    }
    session.requireCurrent();
    return ModelDownloadGrant.fromJson(
      await api.request(
        '/me/model_downloads',
        method: 'POST',
        body: {'model_version': modelVersion, 'platform': platform},
        headers: session.headers(mutation: true),
      ),
    );
  }

  Future<ModelDownloadGrant> getDownload(
    TranscriptionSession session,
    String downloadId,
  ) async {
    _requireVisible(downloadId, 'download id');
    session.requireCurrent();
    return ModelDownloadGrant.fromJson(
      await api.request(
        '/me/model_downloads/${Uri.encodeComponent(downloadId)}',
        headers: session.headers(mutation: false),
      ),
    );
  }

  Future<http.StreamedResponse> downloadContent(
    TranscriptionSession session,
    String downloadId, {
    int offset = 0,
  }) async {
    _requireVisible(downloadId, 'download id');
    if (offset < 0) throw ArgumentError.value(offset, 'offset');
    session.requireCurrent();
    final request = http.Request(
      'GET',
      Uri.parse(
        '${api.base}/me/model_downloads/${Uri.encodeComponent(downloadId)}/content',
      ),
    )..headers.addAll(session.headers(mutation: false));
    request.headers['accept'] = 'application/octet-stream';
    if (offset > 0) request.headers['range'] = 'bytes=$offset-';
    final response = await api.client.send(request);
    if (response.statusCode >= 400 && response.statusCode != 416) {
      final buffered = await http.Response.fromStream(response);
      var message = 'Model download failed.';
      try {
        final body = jsonDecode(buffered.body) as Map;
        message = '${body['error'] ?? body['message'] ?? message}';
      } catch (_) {}
      throw ApiError(buffered.statusCode, message);
    }
    return response;
  }

  Future<TranscriptionRun> createRun(
    TranscriptionSession session,
    Map<String, Object?> request,
  ) async {
    session.requireCurrent();
    return TranscriptionRun.fromJson(
      await api.request(
        '/me/transcriptions',
        method: 'POST',
        body: request,
        headers: session.headers(mutation: true),
      ),
    );
  }

  Future<TranscriptionRun> getRun(
    TranscriptionSession session,
    String runId,
  ) async {
    _requireVisible(runId, 'run id');
    session.requireCurrent();
    return TranscriptionRun.fromJson(
      await api.request(
        '/me/transcriptions/${Uri.encodeComponent(runId)}',
        headers: session.headers(mutation: false),
      ),
    );
  }

  Stream<TranscriptionEvent> events(
    TranscriptionSession session,
    String runId, {
    int after = 0,
  }) async* {
    _requireVisible(runId, 'run id');
    if (after < 0) throw ArgumentError.value(after, 'after');
    session.requireCurrent();
    final request = http.Request(
      'GET',
      Uri.parse(
        '${api.base}/me/transcriptions/${Uri.encodeComponent(runId)}/events',
      ).replace(queryParameters: {'after': '$after'}),
    )..headers.addAll(session.headers(mutation: false));
    request.headers['accept'] = 'text/event-stream';
    final response = await api.client.send(request);
    session.requireCurrent();
    if (response.statusCode >= 400) {
      final body = await response.stream.bytesToString();
      session.requireCurrent();
      throw ApiError(response.statusCode, _errorMessage(body));
    }

    const maxEventCharacters = 64 * 1024;
    int? id;
    String? stage;
    final data = <String>[];
    var frameCharacters = 0;

    TranscriptionEvent? flush() {
      final eventId = id;
      final eventStage = stage;
      final hasContent =
          eventId != null || eventStage != null || data.isNotEmpty;
      if (!hasContent) return null;
      if (eventId == null || eventStage == null || data.isEmpty) {
        throw const FormatException('Invalid transcription event frame.');
      }
      final decoded = jsonDecode(data.join('\n'));
      if (decoded is! Map) {
        throw const FormatException('Invalid transcription event data.');
      }
      return TranscriptionEvent(
        id: eventId,
        stage: eventStage,
        data: Map<String, dynamic>.from(decoded),
      );
    }

    TranscriptionEvent? consumeLine(String line) {
      frameCharacters += line.length + 1;
      if (frameCharacters > maxEventCharacters) {
        throw const FormatException('Transcription event frame is too large.');
      }
      if (line.isEmpty) {
        final event = flush();
        id = null;
        stage = null;
        data.clear();
        frameCharacters = 0;
        return event;
      }
      if (line.startsWith(':')) return null;
      if (line.startsWith('id:')) {
        id = int.tryParse(line.substring(3).trim());
      } else if (line.startsWith('event:')) {
        stage = line.substring(6).trim();
      } else if (line.startsWith('data:')) {
        data.add(line.substring(5).trim());
      }
      return null;
    }

    var pendingLine = '';
    await for (final chunk in response.stream.transform(utf8.decoder)) {
      session.requireCurrent();
      final text = pendingLine + chunk;
      var lineStart = 0;
      for (var i = 0; i < text.length; i++) {
        final code = text.codeUnitAt(i);
        if (code != 10 && code != 13) continue;
        // A CR at the end of a chunk may be the first half of CRLF. Keep it
        // until the next chunk so it cannot become a false blank event line.
        if (code == 13 && i == text.length - 1) break;
        final event = consumeLine(text.substring(lineStart, i));
        if (event != null) {
          session.requireCurrent();
          yield event;
        }
        if (code == 13 && text.codeUnitAt(i + 1) == 10) i++;
        lineStart = i + 1;
      }
      pendingLine = text.substring(lineStart);
      if (pendingLine.length > maxEventCharacters) {
        throw const FormatException('Transcription event line is too large.');
      }
    }
    if (pendingLine.endsWith('\r')) {
      final event = consumeLine(
        pendingLine.substring(0, pendingLine.length - 1),
      );
      if (event != null) {
        session.requireCurrent();
        yield event;
      }
      final finalEvent = consumeLine('');
      if (finalEvent != null) {
        session.requireCurrent();
        yield finalEvent;
      }
    } else if (pendingLine.isNotEmpty) {
      final event = consumeLine(pendingLine);
      if (event != null) {
        session.requireCurrent();
        yield event;
      }
    }
    session.requireCurrent();
    final finalEvent = flush();
    if (finalEvent != null) {
      session.requireCurrent();
      yield finalEvent;
    }
  }

  static List<TranscriptionEvent> parseEvents(String body) =>
      _parseEvents(body);

  Future<TranscriptionRun> submitLocalResult(
    TranscriptionSession session,
    String runId,
    Map<String, Object?> result,
  ) async {
    _requireVisible(runId, 'run id');
    session.requireCurrent();
    return TranscriptionRun.fromJson(
      await api.request(
        '/me/transcriptions/${Uri.encodeComponent(runId)}/result',
        method: 'PUT',
        body: result,
        headers: session.headers(mutation: true),
      ),
    );
  }

  Future<Set<String>> submitFeedback(
    TranscriptionSession session,
    String runId,
    List<Map<String, Object?>> events,
  ) async {
    _requireVisible(runId, 'run id');
    if (events.isEmpty) return const {};
    session.requireCurrent();
    final result = await api.request(
      '/me/transcriptions/${Uri.encodeComponent(runId)}/feedback',
      method: 'POST',
      body: {'schema_version': 1, 'events': events},
      headers: session.headers(mutation: true),
    );
    final returnedEvents = result['events'];
    if (result['run_id'] != runId || returnedEvents is! List) {
      throw const FormatException('Invalid training feedback response.');
    }
    final eventIds = <String>{};
    for (final value in returnedEvents) {
      if (value is! Map || value['event_id'] is! String) {
        throw const FormatException('Invalid training feedback response.');
      }
      if (!eventIds.add(value['event_id'] as String)) {
        throw const FormatException('Duplicate feedback acknowledgement.');
      }
    }
    return eventIds;
  }

  Future<TranscriptionRun> cancelRun(
    TranscriptionSession session,
    String runId,
  ) async {
    _requireVisible(runId, 'run id');
    session.requireCurrent();
    return TranscriptionRun.fromJson(
      await api.request(
        '/me/transcriptions/${Uri.encodeComponent(runId)}/execution',
        method: 'DELETE',
        headers: session.headers(mutation: true),
      ),
    );
  }
}

List<TranscriptionEvent> _parseEvents(String body) {
  final events = <TranscriptionEvent>[];
  int? id;
  String? stage;
  final data = <String>[];
  void flush() {
    final eventId = id;
    final eventStage = stage;
    if (eventId != null && eventStage != null && data.isNotEmpty) {
      final decoded = jsonDecode(data.join('\n'));
      if (decoded is Map) {
        events.add(
          TranscriptionEvent(
            id: eventId,
            stage: eventStage,
            data: Map<String, dynamic>.from(decoded),
          ),
        );
      }
    }
    id = null;
    stage = null;
    data.clear();
  }

  for (final line in const LineSplitter().convert(body)) {
    if (line.isEmpty) {
      flush();
    } else if (line.startsWith('id:')) {
      id = int.tryParse(line.substring(3).trim());
    } else if (line.startsWith('event:')) {
      stage = line.substring(6).trim();
    } else if (line.startsWith('data:')) {
      data.add(line.substring(5).trim());
    }
  }
  flush();
  return List.unmodifiable(events);
}

String _errorMessage(String body) {
  try {
    final value = jsonDecode(body) as Map;
    return '${value['error'] ?? value['message'] ?? 'Request failed'}';
  } catch (_) {
    return 'Request failed.';
  }
}

void _requireToken(String value, String label) {
  if (!_token.hasMatch(value)) throw ArgumentError.value(value, label);
}

void _requireVisible(String value, String label) {
  if (!_visible.hasMatch(value)) throw ArgumentError.value(value, label);
}

const _platforms = {'android', 'ios', 'macos', 'linux'};
const _languages = {'en', 'pt-BR', 'th'};
final _token = RegExp(r'^[A-Za-z0-9._-]{1,128}$');
final _visible = RegExp(r'^[\x21-\x7e]{1,128}$');
final _sha256 = RegExp(r'^[a-f0-9]{64}$');
