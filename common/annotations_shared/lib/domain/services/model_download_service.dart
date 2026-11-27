import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;

import '../../core/features.dart';
import '../../dal/remote/transcription_api_adapter.dart';
import '../models/transcription_session.dart';

final class DownloadedModel {
  const DownloadedModel({
    required this.grant,
    required this.file,
    required this.manifest,
  });

  final ModelDownloadGrant grant;
  final File file;
  final ModelReleaseManifest manifest;
}

abstract interface class ModelArtifactStore {
  Future<int> partialSize(String downloadId);
  Future<void> clearPartial(String downloadId);
  Future<void> appendPartial(String downloadId, Stream<List<int>> bytes);
  Future<bool> hasValidArtifact({
    required String version,
    required String platform,
    required int size,
    required String sha256,
  });
  Future<String?> partialSha256(String downloadId);
  Future<void> installPartial({
    required String downloadId,
    required String version,
    required String platform,
    required String sha256,
  });
  Future<File> artifactFile({
    required String version,
    required String platform,
    required String sha256,
  });
}

/// Stores official model artifacts and resumable partial files in app support.
/// The owner supplies the app's private support directory at construction.
final class DirectoryModelArtifactStore implements ModelArtifactStore {
  DirectoryModelArtifactStore(this.directory);

  final Directory directory;

  File _partial(String downloadId) {
    _safe(downloadId);
    return File('${directory.path}/$downloadId.partial');
  }

  File _artifact(String version, String platform, String hash) {
    _safe(version);
    _safe(platform);
    if (!_sha256.hasMatch(hash)) throw ArgumentError.value(hash, 'sha256');
    return File('${directory.path}/${version}_${platform}_$hash.model');
  }

  void _safe(String value) {
    if (!_token.hasMatch(value)) throw ArgumentError.value(value);
  }

  Future<void> _ensureDirectory() => directory.create(recursive: true);

  @override
  Future<int> partialSize(String downloadId) async {
    final file = _partial(downloadId);
    return await file.exists() ? file.length() : 0;
  }

  @override
  Future<void> clearPartial(String downloadId) async {
    final file = _partial(downloadId);
    if (await file.exists()) await file.delete();
  }

  @override
  Future<void> appendPartial(String downloadId, Stream<List<int>> bytes) async {
    await _ensureDirectory();
    final handle = await _partial(downloadId).open(mode: FileMode.append);
    try {
      await for (final chunk in bytes) {
        await handle.writeFrom(chunk);
      }
      await handle.flush();
    } finally {
      await handle.close();
    }
  }

  @override
  Future<String?> partialSha256(String downloadId) async {
    final file = _partial(downloadId);
    if (!await file.exists()) return null;
    return (await crypto.sha256.bind(file.openRead()).first).toString();
  }

  @override
  Future<bool> hasValidArtifact({
    required String version,
    required String platform,
    required int size,
    required String sha256,
  }) async {
    final file = _artifact(version, platform, sha256);
    if (!await file.exists() || await file.length() != size) return false;
    return (await crypto.sha256.bind(file.openRead()).first).toString() ==
        sha256;
  }

  @override
  Future<void> installPartial({
    required String downloadId,
    required String version,
    required String platform,
    required String sha256,
  }) async {
    await _ensureDirectory();
    final source = _partial(downloadId);
    final target = _artifact(version, platform, sha256);
    if (await target.exists()) await target.delete();
    await source.rename(target.path);
  }

  @override
  Future<File> artifactFile({
    required String version,
    required String platform,
    required String sha256,
  }) async => _artifact(version, platform, sha256);
}

/// Downloads a verified manifest artifact with server-granted account access.
/// Partial files are keyed by the server's logical download id; completed model
/// bytes are shared locally by version/platform/checksum and are reverified.
final class ModelDownloadService {
  ModelDownloadService({
    required this.api,
    required this.store,
    required this.sessionProvider,
    this.enabled = FeatureSwitches.transcription,
  });

  final TranscriptionApiAdapter api;
  final ModelArtifactStore store;
  final TranscriptionSessionProvider sessionProvider;
  final bool enabled;

  Future<DownloadedModel> download({
    required String version,
    required String platform,
  }) async {
    if (!enabled) throw const TranscriptionFeatureDisabledException();
    final session = await sessionProvider();
    if (session == null) throw const TranscriptionSignInRequiredException();
    session.requireCurrent();

    final manifest = await api.getModel(session, version);
    final artifact = manifest.artifactFor(platform);
    if (artifact == null) throw const ModelArtifactUnavailableException();
    final grant = await api.createDownload(
      session,
      modelVersion: version,
      platform: platform,
    );
    if (grant.modelVersion != manifest.version ||
        grant.platform != artifact.platform ||
        grant.size != artifact.size ||
        grant.sha256 != artifact.sha256) {
      throw const ModelManifestChangedException();
    }
    session.requireCurrent();

    if (!await store.hasValidArtifact(
      version: version,
      platform: platform,
      size: artifact.size,
      sha256: artifact.sha256,
    )) {
      await _finishDownload(session, grant, artifact);
    }
    session.requireCurrent();
    return DownloadedModel(
      grant: grant,
      file: await store.artifactFile(
        version: version,
        platform: platform,
        sha256: artifact.sha256,
      ),
      manifest: manifest,
    );
  }

  /// Reuses a saved logical grant and verified artifact on run reopen. This
  /// does not create a second download identity.
  Future<DownloadedModel> resume({
    required String downloadId,
    required String version,
    required String platform,
    TranscriptionSession? expectedSession,
  }) async {
    if (!enabled) throw const TranscriptionFeatureDisabledException();
    expectedSession?.requireCurrent();
    final session = await sessionProvider();
    if (session == null) throw const TranscriptionSignInRequiredException();
    expectedSession?.requireCurrent();
    if (expectedSession != null &&
        session.accountId != expectedSession.accountId) {
      throw const TranscriptionSessionChangedException();
    }
    session.requireCurrent();
    final manifest = await api.getModel(session, version);
    final artifact = manifest.artifactFor(platform);
    if (manifest.version != version || artifact == null) {
      throw const ModelArtifactUnavailableException();
    }
    final grant = await api.getDownload(session, downloadId);
    if (grant.modelVersion != manifest.version ||
        grant.platform != artifact.platform ||
        grant.size != artifact.size ||
        grant.sha256 != artifact.sha256) {
      throw const ModelManifestChangedException();
    }
    session.requireCurrent();
    if (!await store.hasValidArtifact(
      version: version,
      platform: platform,
      size: artifact.size,
      sha256: artifact.sha256,
    )) {
      await _finishDownload(session, grant, artifact);
    }
    session.requireCurrent();
    if (!await store.hasValidArtifact(
      version: version,
      platform: platform,
      size: artifact.size,
      sha256: artifact.sha256,
    )) {
      throw const ModelChecksumMismatchException();
    }
    return DownloadedModel(
      grant: grant,
      file: await store.artifactFile(
        version: version,
        platform: platform,
        sha256: artifact.sha256,
      ),
      manifest: manifest,
    );
  }

  Future<void> _finishDownload(
    TranscriptionSession session,
    ModelDownloadGrant grant,
    ModelArtifactManifest artifact,
  ) async {
    var restartedFromZero = false;
    while (true) {
      var offset = await store.partialSize(grant.downloadId);
      if (offset > artifact.size) {
        await store.clearPartial(grant.downloadId);
        offset = 0;
      }
      if (offset == artifact.size) {
        final digest = await store.partialSha256(grant.downloadId);
        if (digest == artifact.sha256) {
          await store.installPartial(
            downloadId: grant.downloadId,
            version: grant.modelVersion,
            platform: grant.platform,
            sha256: grant.sha256,
          );
          return;
        }
        await store.clearPartial(grant.downloadId);
        throw const ModelChecksumMismatchException();
      }

      final response = await api.downloadContent(
        session,
        grant.downloadId,
        offset: offset,
      );
      if (response.statusCode == 416) {
        if (!restartedFromZero) {
          await store.clearPartial(grant.downloadId);
          restartedFromZero = true;
          continue;
        }
        throw const ModelRangeResponseException();
      }

      var appendOffset = offset;
      var expectedBodyLength = artifact.size;
      if (response.statusCode == 206) {
        final range = _parseContentRange(response.headers['content-range']);
        if (range == null ||
            range.start != offset ||
            range.total != artifact.size ||
            range.end < range.start) {
          await response.stream.drain<void>();
          throw const ModelRangeResponseException();
        }
        expectedBodyLength = range.end - range.start + 1;
      } else if (response.statusCode == 200) {
        if (offset > 0) await store.clearPartial(grant.downloadId);
        appendOffset = 0;
        expectedBodyLength = artifact.size;
      } else {
        await response.stream.drain<void>();
        throw const ModelRangeResponseException();
      }

      final etag = response.headers['etag']?.replaceAll('"', '').trim();
      if (etag != null && etag.isNotEmpty && etag != artifact.sha256) {
        await response.stream.drain<void>();
        await store.clearPartial(grant.downloadId);
        throw const ModelManifestChangedException();
      }

      await store.appendPartial(grant.downloadId, response.stream);
      session.requireCurrent();
      final nextOffset = await store.partialSize(grant.downloadId);
      if (nextOffset - appendOffset > expectedBodyLength ||
          nextOffset > artifact.size) {
        await store.clearPartial(grant.downloadId);
        throw const ModelRangeResponseException();
      }
      if (nextOffset - appendOffset < expectedBodyLength) {
        throw const ModelIncompleteDownloadException();
      }
      if (nextOffset < artifact.size) continue;

      final digest = await store.partialSha256(grant.downloadId);
      if (digest != artifact.sha256) {
        await store.clearPartial(grant.downloadId);
        throw const ModelChecksumMismatchException();
      }
      await store.installPartial(
        downloadId: grant.downloadId,
        version: grant.modelVersion,
        platform: grant.platform,
        sha256: grant.sha256,
      );
      return;
    }
  }

  static ({int start, int end, int total})? _parseContentRange(String? value) {
    if (value == null) return null;
    final match = RegExp(r'^bytes (\d+)-(\d+)/(\d+)$').firstMatch(value);
    if (match == null) return null;
    final start = int.tryParse(match.group(1)!);
    final end = int.tryParse(match.group(2)!);
    final total = int.tryParse(match.group(3)!);
    if (start == null ||
        end == null ||
        total == null ||
        total <= 0 ||
        end >= total) {
      return null;
    }
    return (start: start, end: end, total: total);
  }
}

final class TranscriptionFeatureDisabledException implements Exception {
  const TranscriptionFeatureDisabledException();
}

final class ModelArtifactUnavailableException implements Exception {
  const ModelArtifactUnavailableException();
}

final class ModelManifestChangedException implements Exception {
  const ModelManifestChangedException();
}

final class ModelChecksumMismatchException implements Exception {
  const ModelChecksumMismatchException();
}

final class ModelRangeResponseException implements Exception {
  const ModelRangeResponseException();
}

final class ModelIncompleteDownloadException implements Exception {
  const ModelIncompleteDownloadException();
}

final _token = RegExp(r'^[A-Za-z0-9._-]{1,128}$');
final _sha256 = RegExp(r'^[a-f0-9]{64}$');
