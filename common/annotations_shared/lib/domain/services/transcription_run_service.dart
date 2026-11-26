import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../../core/features.dart';
import '../../dal/remote/transcription_api_adapter.dart';
import '../models/transcription_session.dart';

final class LocalRecognitionResult {
  const LocalRecognitionResult({
    required this.document,
    required this.runtimeName,
    required this.runtimeVersion,
    required this.elapsedMilliseconds,
  });

  final Map<String, Object?> document;
  final String runtimeName;
  final String runtimeVersion;
  final int elapsedMilliseconds;
}

/// Runtime boundary. The release-specific recognizer is supplied only after a
/// reviewed model release exists. Tests use a deterministic fixture runtime.
abstract interface class TranscriptionRuntime {
  Future<LocalRecognitionResult> recognize({
    required File modelFile,
    required Map<String, Object?> selectedInkDocument,
    required String language,
    required void Function(String stage) onStage,
  });
}

abstract interface class PendingTranscriptionResults {
  Future<List<PendingTranscriptionResult>> loadAll();
  Future<void> save(PendingTranscriptionResult result);
  Future<void> remove(String accountId, String eventId);
}

abstract interface class PendingTranscriptionFeedbackStore {
  Future<List<PendingTranscriptionFeedback>> loadAll();
  Future<void> save(PendingTranscriptionFeedback event);
  Future<void> remove(String accountId, String runId, String eventId);
}

final class PendingTranscriptionResult {
  const PendingTranscriptionResult({
    required this.accountId,
    required this.runId,
    required this.eventId,
    required this.body,
  });

  final String accountId;
  final String runId;
  final String eventId;
  final Map<String, Object?> body;

  Map<String, Object?> toJson() => {
    'account_id': accountId,
    'run_id': runId,
    'event_id': eventId,
    'body': body,
  };

  factory PendingTranscriptionResult.fromJson(Map<String, dynamic> json) =>
      PendingTranscriptionResult(
        accountId: json['account_id'] as String,
        runId: json['run_id'] as String,
        eventId: json['event_id'] as String,
        body: Map<String, Object?>.from(json['body'] as Map),
      );
}

final class PendingTranscriptionFeedback {
  const PendingTranscriptionFeedback({
    required this.accountId,
    required this.runId,
    required this.eventId,
    required this.body,
  });

  final String accountId;
  final String runId;
  final String eventId;
  final Map<String, Object?> body;

  Map<String, Object?> toJson() => {
    'account_id': accountId,
    'run_id': runId,
    'event_id': eventId,
    'body': body,
  };

  factory PendingTranscriptionFeedback.fromJson(Map<String, dynamic> json) =>
      PendingTranscriptionFeedback(
        accountId: json['account_id'] as String,
        runId: json['run_id'] as String,
        eventId: json['event_id'] as String,
        body: Map<String, Object?>.from(json['body'] as Map),
      );
}

/// Local durable result queue. Stored results stay bound to the verified owner.
final class FilePendingTranscriptionResults
    implements PendingTranscriptionResults {
  FilePendingTranscriptionResults(this.file);

  final File file;
  Future<void> _tail = Future<void>.value();

  Future<T> _serial<T>(Future<T> Function() operation) {
    final result = Completer<T>();
    _tail = _tail.then((_) async {
      try {
        result.complete(await operation());
      } catch (error, stack) {
        result.completeError(error, stack);
      }
    });
    return result.future;
  }

  Future<List<PendingTranscriptionResult>> _read() async {
    if (!await file.exists()) return <PendingTranscriptionResult>[];
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! List) throw const FormatException('Invalid result queue.');
    return decoded
        .whereType<Map>()
        .map(
          (value) => PendingTranscriptionResult.fromJson(
            Map<String, dynamic>.from(value),
          ),
        )
        .toList(growable: true);
  }

  Future<void> _write(List<PendingTranscriptionResult> results) async {
    await file.parent.create(recursive: true);
    final temp = File('${file.path}.writing');
    await temp.writeAsString(
      jsonEncode([for (final result in results) result.toJson()]),
      flush: true,
    );
    if (await file.exists()) await file.delete();
    await temp.rename(file.path);
  }

  @override
  Future<List<PendingTranscriptionResult>> loadAll() => _serial(_read);

  @override
  Future<void> save(PendingTranscriptionResult result) => _serial(() async {
    final all = await _read();
    final same = all.indexWhere(
      (item) =>
          item.accountId == result.accountId && item.eventId == result.eventId,
    );
    if (same >= 0) {
      if (jsonEncode(all[same].toJson()) != jsonEncode(result.toJson())) {
        throw StateError('A transcription event id cannot change its body.');
      }
      return;
    }
    all.add(result);
    await _write(all);
  });

  @override
  Future<void> remove(String accountId, String eventId) => _serial(() async {
    final all = await _read()
      ..removeWhere(
        (item) => item.accountId == accountId && item.eventId == eventId,
      );
    await _write(all);
  });
}

final class MemoryPendingTranscriptionResults
    implements PendingTranscriptionResults {
  final List<PendingTranscriptionResult> values = [];

  @override
  Future<List<PendingTranscriptionResult>> loadAll() async => [...values];

  @override
  Future<void> save(PendingTranscriptionResult result) async {
    final existing = values.where(
      (item) =>
          item.accountId == result.accountId && item.eventId == result.eventId,
    );
    if (existing.isNotEmpty) {
      if (jsonEncode(existing.first.toJson()) != jsonEncode(result.toJson())) {
        throw StateError('A transcription event id cannot change its body.');
      }
      return;
    }
    values.add(result);
  }

  @override
  Future<void> remove(String accountId, String eventId) async {
    values.removeWhere(
      (item) => item.accountId == accountId && item.eventId == eventId,
    );
  }
}

/// Durable feedback events stay bound to the verified owner and source run.
final class FilePendingTranscriptionFeedbackStore
    implements PendingTranscriptionFeedbackStore {
  FilePendingTranscriptionFeedbackStore(this.file);

  final File file;
  Future<void> _tail = Future<void>.value();

  Future<T> _serial<T>(Future<T> Function() operation) {
    final result = Completer<T>();
    _tail = _tail.then((_) async {
      try {
        result.complete(await operation());
      } catch (error, stack) {
        result.completeError(error, stack);
      }
    });
    return result.future;
  }

  Future<List<PendingTranscriptionFeedback>> _read() async {
    if (!await file.exists()) return <PendingTranscriptionFeedback>[];
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! List) {
      throw const FormatException('Invalid feedback queue.');
    }
    return decoded
        .whereType<Map>()
        .map(
          (value) => PendingTranscriptionFeedback.fromJson(
            Map<String, dynamic>.from(value),
          ),
        )
        .toList(growable: true);
  }

  Future<void> _write(List<PendingTranscriptionFeedback> events) async {
    await file.parent.create(recursive: true);
    final temp = File('${file.path}.writing');
    await temp.writeAsString(
      jsonEncode([for (final event in events) event.toJson()]),
      flush: true,
    );
    if (await file.exists()) await file.delete();
    await temp.rename(file.path);
  }

  @override
  Future<List<PendingTranscriptionFeedback>> loadAll() => _serial(_read);

  @override
  Future<void> save(PendingTranscriptionFeedback event) => _serial(() async {
    final all = await _read();
    final same = all.indexWhere(
      (item) =>
          item.accountId == event.accountId &&
          item.runId == event.runId &&
          item.eventId == event.eventId,
    );
    if (same >= 0) {
      if (jsonEncode(all[same].toJson()) != jsonEncode(event.toJson())) {
        throw StateError('A feedback event id cannot change its body.');
      }
      return;
    }
    all.add(event);
    await _write(all);
  });

  @override
  Future<void> remove(String accountId, String runId, String eventId) =>
      _serial(() async {
        final all = await _read()
          ..removeWhere(
            (item) =>
                item.accountId == accountId &&
                item.runId == runId &&
                item.eventId == eventId,
          );
        await _write(all);
      });
}

final class MemoryPendingTranscriptionFeedbackStore
    implements PendingTranscriptionFeedbackStore {
  final List<PendingTranscriptionFeedback> values = [];

  @override
  Future<List<PendingTranscriptionFeedback>> loadAll() async => [...values];

  @override
  Future<void> save(PendingTranscriptionFeedback event) async {
    final existing = values.where(
      (item) =>
          item.accountId == event.accountId &&
          item.runId == event.runId &&
          item.eventId == event.eventId,
    );
    if (existing.isNotEmpty) {
      if (jsonEncode(existing.first.toJson()) != jsonEncode(event.toJson())) {
        throw StateError('A feedback event id cannot change its body.');
      }
      return;
    }
    values.add(event);
  }

  @override
  Future<void> remove(String accountId, String runId, String eventId) async {
    values.removeWhere(
      (item) =>
          item.accountId == accountId &&
          item.runId == runId &&
          item.eventId == eventId,
    );
  }
}

final class TranscriptionRunService {
  TranscriptionRunService({
    required this.api,
    required this.sessionProvider,
    required this.pendingResults,
    required this.pendingFeedback,
    this.enabled = FeatureSwitches.transcription,
    String Function()? newEventId,
  }) : _newEventId = newEventId ?? _randomEventId;

  final TranscriptionApiAdapter api;
  final TranscriptionSessionProvider sessionProvider;
  final PendingTranscriptionResults pendingResults;
  final PendingTranscriptionFeedbackStore pendingFeedback;
  final bool enabled;
  final String Function() _newEventId;

  Future<TranscriptionRun> register({
    required String downloadId,
    required String modelVersion,
    required String language,
    required String mode,
    String? sourceRevisionId,
    String? sourceHash,
    Map<String, Object?>? selectedInkDocument,
    int? schemaVersion,
    List<String> fileRefs = const [],
  }) async {
    _validateRegistration(
      mode: mode,
      sourceRevisionId: sourceRevisionId,
      sourceHash: sourceHash,
      selectedInkDocument: selectedInkDocument,
      fileRefs: fileRefs,
    );
    final session = await _requireSession();
    return _registerWithSession(
      session,
      downloadId: downloadId,
      modelVersion: modelVersion,
      language: language,
      mode: mode,
      sourceRevisionId: sourceRevisionId,
      sourceHash: sourceHash,
      selectedInkDocument: selectedInkDocument,
      schemaVersion: schemaVersion,
      fileRefs: fileRefs,
    );
  }

  Future<TranscriptionRun> _registerWithSession(
    TranscriptionSession session, {
    required String downloadId,
    required String modelVersion,
    required String language,
    required String mode,
    String? sourceRevisionId,
    String? sourceHash,
    Map<String, Object?>? selectedInkDocument,
    int? schemaVersion,
    List<String> fileRefs = const [],
  }) async {
    final body = <String, Object?>{
      'download_id': downloadId,
      'model_version': modelVersion,
      'language': language,
      'mode': mode,
      'source_revision_id': ?sourceRevisionId,
      'source_hash': ?sourceHash,
      if (selectedInkDocument != null)
        'ink': {
          'schema_version': ?schemaVersion,
          'document': selectedInkDocument,
        },
      if (fileRefs.isNotEmpty) 'file_refs': fileRefs,
    };
    session.requireCurrent();
    final run = await api.createRun(session, body);
    session.requireCurrent();
    return run;
  }

  void _validateRegistration({
    required String mode,
    String? sourceRevisionId,
    String? sourceHash,
    Map<String, Object?>? selectedInkDocument,
    List<String> fileRefs = const [],
  }) {
    _requireEnabled();
    if ((sourceRevisionId == null) == (sourceHash == null)) {
      throw ArgumentError(
        'Provide exactly one source revision id or source hash.',
      );
    }
    if (selectedInkDocument == null && fileRefs.isEmpty) {
      throw ArgumentError(
        'Provide selected ink or authorized file references.',
      );
    }
    if (mode != 'local' && mode != 'cloud') {
      throw ArgumentError.value(mode, 'mode');
    }
  }

  /// Registers before local recognition, then persists the result before sending
  /// it. A retry uses the same event id and body, so the server can replay it.
  Future<PendingTranscriptionResult> runLocal({
    required String downloadId,
    required String modelVersion,
    required String language,
    required String sourceRevisionId,
    required Map<String, Object?> selectedInkDocument,
    required int schemaVersion,
    required File modelFile,
    required TranscriptionRuntime runtime,
    required void Function(String stage) onStage,
  }) async {
    _validateRegistration(
      mode: 'local',
      sourceRevisionId: sourceRevisionId,
      selectedInkDocument: selectedInkDocument,
    );
    final session = await _requireSession();
    final run = await _registerWithSession(
      session,
      downloadId: downloadId,
      modelVersion: modelVersion,
      language: language,
      mode: 'local',
      sourceRevisionId: sourceRevisionId,
      selectedInkDocument: selectedInkDocument,
      schemaVersion: schemaVersion,
    );
    session.requireCurrent();
    if (run.mode != 'local' || run.status != 'registered') {
      throw const TranscriptionRunStateException();
    }
    if (run.downloadId != downloadId || run.modelVersion != modelVersion) {
      throw const TranscriptionRunStateException();
    }
    final result = await runtime.recognize(
      modelFile: modelFile,
      selectedInkDocument: selectedInkDocument,
      language: language,
      onStage: onStage,
    );
    session.requireCurrent();
    final eventId = _newEventId();
    final body = <String, Object?>{
      'event_id': eventId,
      'source_revision_id': sourceRevisionId,
      'schema_version': schemaVersion,
      'document': result.document,
      'runtime': {
        'name': result.runtimeName,
        'version': result.runtimeVersion,
        'elapsed_ms': result.elapsedMilliseconds,
      },
    };
    final pending = PendingTranscriptionResult(
      accountId: session.accountId,
      runId: run.runId,
      eventId: eventId,
      body: body,
    );
    await pendingResults.save(pending);
    await _sendPending(session, pending);
    return pending;
  }

  Future<int> retryPendingResults() async {
    _requireEnabled();
    final session = await _session();
    if (session == null) return 0;
    var delivered = 0;
    for (final pending in await pendingResults.loadAll()) {
      if (pending.accountId != session.accountId) continue;
      session.requireCurrent();
      await _sendPending(session, pending);
      delivered++;
    }
    return delivered;
  }

  /// Stores feedback before sending it. Event IDs and bodies remain unchanged
  /// across retries so the server can safely acknowledge an earlier delivery.
  Future<void> submitFeedback({
    required String runId,
    required List<Map<String, Object?>> events,
  }) async {
    _requireEnabled();
    if (events.isEmpty) return;
    final session = await _requireSession();
    final pending = <PendingTranscriptionFeedback>[];
    final ids = <String>{};
    for (final event in events) {
      final eventId = _validateFeedbackEvent(event);
      if (!ids.add(eventId)) {
        throw ArgumentError('Feedback event ids must be unique per request.');
      }
      final frozen = Map<String, Object?>.from(
        jsonDecode(jsonEncode(event)) as Map,
      );
      final requestBytes = utf8
          .encode(
            jsonEncode({
              'schema_version': 1,
              'events': [frozen],
            }),
          )
          .length;
      if (requestBytes > _maxFeedbackRequestBytes) {
        throw ArgumentError.value(
          eventId,
          'event_id',
          'Feedback is too large.',
        );
      }
      pending.add(
        PendingTranscriptionFeedback(
          accountId: session.accountId,
          runId: runId,
          eventId: eventId,
          body: Map<String, Object?>.unmodifiable(frozen),
        ),
      );
    }
    for (final event in pending) {
      session.requireCurrent();
      await pendingFeedback.save(event);
    }
    for (final event in pending) {
      session.requireCurrent();
      await _sendPendingFeedback(session, event);
    }
  }

  Future<int> retryPendingFeedback() async {
    _requireEnabled();
    final session = await _session();
    if (session == null) return 0;
    var delivered = 0;
    for (final event in await pendingFeedback.loadAll()) {
      if (event.accountId != session.accountId) continue;
      session.requireCurrent();
      await _sendPendingFeedback(session, event);
      delivered++;
    }
    return delivered;
  }

  Future<TranscriptionRun> startCloud({
    required String downloadId,
    required String modelVersion,
    required String language,
    required String sourceRevisionId,
    required Map<String, Object?> selectedInkDocument,
    required int schemaVersion,
  }) => register(
    downloadId: downloadId,
    modelVersion: modelVersion,
    language: language,
    mode: 'cloud',
    sourceRevisionId: sourceRevisionId,
    selectedInkDocument: selectedInkDocument,
    schemaVersion: schemaVersion,
  );

  Future<TranscriptionRun> waitForCloudResult(
    String runId, {
    required void Function(TranscriptionEvent event) onEvent,
  }) async {
    _requireEnabled();
    final session = await _requireSession();
    var run = await api.getRun(session, runId);
    var cursor = run.lastEventId;
    while (run.status == 'registered') {
      final events = await api.events(session, runId, after: cursor);
      for (final event in events) {
        if (event.id > cursor) cursor = event.id;
        onEvent(event);
      }
      session.requireCurrent();
      run = await api.getRun(session, runId);
      if (events.isEmpty && run.status == 'registered') {
        throw const TranscriptionEventsEndedEarlyException();
      }
    }
    if (run.mode != 'cloud') throw const TranscriptionRunStateException();
    return run;
  }

  Future<TranscriptionRun> cancel(String runId) async {
    _requireEnabled();
    final session = await _requireSession();
    return api.cancelRun(session, runId);
  }

  Future<void> _sendPending(
    TranscriptionSession session,
    PendingTranscriptionResult pending,
  ) async {
    session.requireCurrent();
    final run = await api.submitLocalResult(
      session,
      pending.runId,
      pending.body,
    );
    final acceptedId = run.result?['event_id'];
    if (run.status != 'completed' || acceptedId != pending.eventId) {
      throw const TranscriptionResultNotConfirmedException();
    }
    session.requireCurrent();
    await pendingResults.remove(pending.accountId, pending.eventId);
  }

  Future<void> _sendPendingFeedback(
    TranscriptionSession session,
    PendingTranscriptionFeedback event,
  ) async {
    session.requireCurrent();
    final accepted = await api.submitFeedback(session, event.runId, [
      event.body,
    ]);
    if (accepted.length != 1 || !accepted.contains(event.eventId)) {
      throw const TranscriptionFeedbackNotConfirmedException();
    }
    session.requireCurrent();
    await pendingFeedback.remove(event.accountId, event.runId, event.eventId);
  }

  Future<TranscriptionSession?> _session() async {
    if (!enabled) throw const TranscriptionFeatureDisabledException();
    final session = await sessionProvider();
    if (session != null) session.requireCurrent();
    return session;
  }

  Future<TranscriptionSession> _requireSession() async =>
      await _session() ?? (throw const TranscriptionSignInRequiredException());

  void _requireEnabled() {
    if (!enabled) throw const TranscriptionFeatureDisabledException();
  }
}

final _feedbackId = RegExp(r'^[A-Za-z0-9_-]{1,128}$');
const _maxFeedbackRequestBytes = 2000000;
const _feedbackFields = {
  'event_id',
  'segment_id',
  'source_item_ids',
  'strokes',
  'suggestion',
  'correction',
  'stage',
  'language',
  'model_version',
};

String _validateFeedbackEvent(Map<String, Object?> event) {
  if (event.keys.any((key) => !_feedbackFields.contains(key))) {
    throw ArgumentError('Feedback contains an unsupported field.');
  }
  final eventId = event['event_id'];
  if (eventId is! String || !_feedbackId.hasMatch(eventId)) {
    throw ArgumentError.value(eventId, 'event_id');
  }
  for (final key in const ['segment_id', 'language', 'model_version']) {
    if (event[key] is! String || (event[key] as String).isEmpty) {
      throw ArgumentError.value(event[key], key);
    }
  }
  for (final key in const ['suggestion', 'correction']) {
    if (event[key] is! String) throw ArgumentError.value(event[key], key);
  }
  if (event['stage'] != 'intermediate' && event['stage'] != 'accepted') {
    throw ArgumentError.value(event['stage'], 'stage');
  }
  final sourceItemIds = event['source_item_ids'];
  if (sourceItemIds != null &&
      (sourceItemIds is! List ||
          sourceItemIds.any((item) => item is! String))) {
    throw ArgumentError.value(sourceItemIds, 'source_item_ids');
  }
  final strokes = event['strokes'];
  if (strokes != null && strokes is! List) {
    throw ArgumentError.value(strokes, 'strokes');
  }
  return eventId;
}

String _randomEventId() {
  final random = Random.secure();
  return List<String>.generate(
    16,
    (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
}

final class TranscriptionFeatureDisabledException implements Exception {
  const TranscriptionFeatureDisabledException();
}

final class TranscriptionRunStateException implements Exception {
  const TranscriptionRunStateException();
}

final class TranscriptionResultNotConfirmedException implements Exception {
  const TranscriptionResultNotConfirmedException();
}

final class TranscriptionFeedbackNotConfirmedException implements Exception {
  const TranscriptionFeedbackNotConfirmedException();
}

final class TranscriptionEventsEndedEarlyException implements Exception {
  const TranscriptionEventsEndedEarlyException();
}
