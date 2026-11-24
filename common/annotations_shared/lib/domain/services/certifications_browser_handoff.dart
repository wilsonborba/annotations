import 'dart:convert';

import 'package:http/http.dart' as http;

import 'native_auth_service.dart';

/// A one-use browser continuation created for an already prepared study.
/// The gateway returns a launch URL containing only its opaque handoff id.
final class CertificationsBrowserHandoff {
  final Uri launchUri;
  final String handoffId;
  final DateTime expiresAt;

  const CertificationsBrowserHandoff({
    required this.launchUri,
    required this.handoffId,
    required this.expiresAt,
  });
}

final class CertificationsHandoffException implements Exception {
  final int statusCode;
  final String? code;
  final String message;

  const CertificationsHandoffException({
    required this.statusCode,
    required this.message,
    this.code,
  });

  @override
  String toString() => message;
}

/// Creates or cancels the accepted api_for_apps browser continuation.
/// Study creation and source authorization stay with the Notes/Certifications
/// APIs; this adapter only transfers an opaque prepared-study reference.
final class CertificationsBrowserHandoffService {
  final http.Client client;
  final String gatewayBaseUrl;

  CertificationsBrowserHandoffService({
    http.Client? client,
    this.gatewayBaseUrl = 'https://api.asodya.com',
  }) : client = client ?? http.Client();

  Future<CertificationsBrowserHandoff> create({
    required NativeSession session,
    required String studyId,
  }) async {
    if (studyId.trim().isEmpty) {
      throw const CertificationsHandoffException(
        statusCode: 400,
        message: 'A prepared study is required.',
      );
    }
    final value = await _post(session, {
      'action': 'create_browser_handoff',
      'target_app': 'certifications',
      'study_id': studyId,
    });
    final data = value['data'];
    if (data is! Map<String, dynamic>) {
      throw const CertificationsHandoffException(
        statusCode: 502,
        message: 'The gateway returned an invalid continuation.',
      );
    }
    final launchText = data['launch_url'];
    final expiresSeconds = data['expires_at'];
    if (launchText is! String || expiresSeconds is! int) {
      throw const CertificationsHandoffException(
        statusCode: 502,
        message: 'The gateway returned an invalid continuation.',
      );
    }
    final launchUri = Uri.tryParse(launchText);
    final handoffId = launchUri?.queryParameters['handoff_id'];
    if (launchUri == null ||
        !{'https', 'http'}.contains(launchUri.scheme) ||
        launchUri.userInfo.isNotEmpty ||
        launchUri.fragment.isNotEmpty ||
        launchUri.path != '/continue' ||
        launchUri.queryParameters.length != 1 ||
        handoffId == null ||
        !_isOpaque(handoffId)) {
      throw const CertificationsHandoffException(
        statusCode: 502,
        message: 'The gateway returned an invalid continuation.',
      );
    }
    return CertificationsBrowserHandoff(
      launchUri: launchUri,
      handoffId: handoffId,
      expiresAt: DateTime.fromMillisecondsSinceEpoch(
        expiresSeconds * 1000,
        isUtc: true,
      ),
    );
  }

  Future<void> cancel({
    required NativeSession session,
    required String handoffId,
  }) async {
    if (!_isOpaque(handoffId)) {
      throw const CertificationsHandoffException(
        statusCode: 400,
        message: 'Invalid continuation.',
      );
    }
    await _post(session, {
      'action': 'cancel_browser_handoff',
      'handoff_id': handoffId,
    });
  }

  Future<Map<String, dynamic>> _post(
    NativeSession session,
    Map<String, Object> body,
  ) async {
    final response = await client.post(
      Uri.parse('$gatewayBaseUrl/apps/api/v1/exchange'),
      headers: {
        'content-type': 'application/json',
        ...session.authHeaders(isMutation: true),
      },
      body: jsonEncode(body),
    );
    Map<String, dynamic> value;
    try {
      value = jsonDecode(response.body) as Map<String, dynamic>;
    } catch (_) {
      throw CertificationsHandoffException(
        statusCode: response.statusCode,
        message: 'The gateway returned an unreadable response.',
      );
    }
    if (response.statusCode >= 400) {
      final data = value['data'];
      final code = data is Map<String, dynamic>
          ? data['code'] as String?
          : null;
      throw CertificationsHandoffException(
        statusCode: response.statusCode,
        code: code,
        message: (value['message'] as String?) ?? 'Continuation failed.',
      );
    }
    return value;
  }

  static bool _isOpaque(String value) =>
      value.isNotEmpty &&
      value.length <= 128 &&
      value.codeUnits.every(
        (code) =>
            (code >= 48 && code <= 57) ||
            (code >= 65 && code <= 90) ||
            (code >= 97 && code <= 122) ||
            code == 45 ||
            code == 95,
      );
}
