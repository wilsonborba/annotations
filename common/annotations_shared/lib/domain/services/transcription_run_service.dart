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
    if (!await file.exists()) return const [];
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

final class TranscriptionRunService {
  TranscriptionRunService({
    required this.api,
    required this.sessionProvider,
    required this.pendingResults,
    this.enabled = FeatureSwitches.transcription,
    String Function()? newEventId,
  }) : _newEventId = newEventId ?? _randomEventId;

  final TranscriptionApiAdapter api;
  final TranscriptionSessionProvider sessionProvider;
  final PendingTranscriptionResults pendingResults;
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
    final session = await _requireSession();
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
    return api.createRun(session, body);
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
    final run = await register(
      downloadId: downloadId,
      modelVersion: modelVersion,
      language: language,
      mode: 'local',
      sourceRevisionId: sourceRevisionId,
      selectedInkDocument: selectedInkDocument,
      schemaVersion: schemaVersion,
    );
    if (run.mode != 'local' || run.status != 'registered') {
      throw const TranscriptionRunStateException();
    }
    final session = await _requireSession();
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
    if (acceptedId != pending.eventId) {
      throw const TranscriptionResultNotConfirmedException();
    }
    await pendingResults.remove(pending.accountId, pending.eventId);
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

final class TranscriptionEventsEndedEarlyException implements Exception {
  const TranscriptionEventsEndedEarlyException();
}
