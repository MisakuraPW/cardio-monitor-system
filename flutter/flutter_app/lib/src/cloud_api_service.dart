import 'dart:convert';

import 'package:http/http.dart' as http;

import 'models.dart';

class CloudApiService {
  CloudApiService({
    required this.baseUrl,
    http.Client? client,
  }) : _client = client ?? http.Client();

  final http.Client _client;
  String baseUrl;

  Uri _uri(String path) {
    final normalized = normalizeCloudApiBaseUrl(baseUrl);
    final sanitized = normalized.endsWith('/')
        ? normalized.substring(0, normalized.length - 1)
        : normalized;
    return Uri.parse('$sanitized$path');
  }

  Future<SessionRecord> getSession(String sessionId) async {
    final response = await _client.get(_uri('/api/v1/sessions/$sessionId'));
    _ensureOk(response);
    final decoded = jsonDecode(response.body) as Map<String, dynamic>;
    return SessionRecord.fromJson(decoded['session'] as Map<String, dynamic>);
  }

  Future<SessionRecord> createSession(SessionRecord session) async {
    final response = await _client.post(
      _uri('/api/v1/sessions'),
      headers: const <String, String>{'Content-Type': 'application/json'},
      body: jsonEncode(
        <String, dynamic>{
          'deviceId': session.deviceId,
          'sourceMode': session.sourceMode,
          'channelKeys': session.channelKeys,
          'startedAt': session.startedAt,
          if (session.userId != null && session.userId!.isNotEmpty)
            'userId': session.userId,
          'userName': session.userName,
          'metadata': session.metadata,
        },
      ),
    );
    _ensureOk(response);
    return SessionRecord.fromJson(jsonDecode(response.body) as Map<String, dynamic>);
  }

  Future<UploadTask> uploadSessionData({
    required String sessionId,
    required Map<String, dynamic> summary,
    required Map<String, dynamic> excerpts,
  }) async {
    final response = await _client.post(
      _uri('/api/v1/sessions/$sessionId/uploads'),
      headers: const <String, String>{'Content-Type': 'application/json'},
      body: jsonEncode(
        <String, dynamic>{
          'summary': summary,
          'excerpts': excerpts,
        },
      ),
    );
    _ensureOk(response);
    return UploadTask.fromJson(jsonDecode(response.body) as Map<String, dynamic>);
  }

  Future<SegmentRecord> uploadSegment(SegmentUploadPayload payload) async {
    final response = await _client.post(
      _uri('/api/v1/sessions/${payload.sessionId}/segments'),
      headers: const <String, String>{'Content-Type': 'application/json'},
      body: jsonEncode(payload.toJson()),
    );
    _ensureOk(response);
    return SegmentRecord.fromJson(jsonDecode(response.body) as Map<String, dynamic>);
  }

  Future<AnalysisJob> createAnalysisJob(String sessionId) async {
    final response = await _client.post(
      _uri('/api/v1/analysis/jobs'),
      headers: const <String, String>{'Content-Type': 'application/json'},
      body: jsonEncode(<String, dynamic>{'sessionId': sessionId}),
    );
    _ensureOk(response);
    return AnalysisJob.fromJson(jsonDecode(response.body) as Map<String, dynamic>);
  }

  Future<AnalysisJob> getAnalysisJob(String jobId) async {
    final response = await _client.get(_uri('/api/v1/analysis/jobs/$jobId'));
    _ensureOk(response);
    return AnalysisJob.fromJson(jsonDecode(response.body) as Map<String, dynamic>);
  }

  Future<MedicalReport> getReport(String sessionId) async {
    final response = await _client.get(_uri('/api/v1/reports/$sessionId'));
    _ensureOk(response);
    return MedicalReport.fromJson(jsonDecode(response.body) as Map<String, dynamic>);
  }

  Future<MedicalReport> analyzeSegment({
    required String sessionId,
    required String segmentId,
  }) async {
    final response = await _client.post(
      _uri('/api/v1/sessions/$sessionId/segments/$segmentId/analyze'),
      headers: const <String, String>{'Content-Type': 'application/json'},
    );
    _ensureOk(response);
    final decoded = jsonDecode(response.body) as Map<String, dynamic>;
    return MedicalReport.fromJson(decoded['report'] as Map<String, dynamic>);
  }

  Future<MedicalReport> getSegmentReport({
    required String sessionId,
    required String segmentId,
  }) async {
    final response = await _client.get(
      _uri('/api/v1/sessions/$sessionId/segments/$segmentId/report'),
    );
    _ensureOk(response);
    return MedicalReport.fromJson(jsonDecode(response.body) as Map<String, dynamic>);
  }

  void dispose() {
    _client.close();
  }

  void _ensureOk(http.Response response) {
    if (response.statusCode >= 200 && response.statusCode < 300) {
      return;
    }
    throw Exception(
      'Cloud API request failed: ${response.statusCode} ${response.body}',
    );
  }
}

String normalizeCloudApiBaseUrl(String value) {
  final trimmed = value.trim();
  final candidate = trimmed.isEmpty ? 'http://182.254.220.56:8000' : trimmed;
  final uri = Uri.tryParse(candidate);
  if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
    return candidate;
  }
  if (uri.port == 8080) {
    return uri.replace(port: 8000).toString();
  }
  return candidate.endsWith('/') ? candidate.substring(0, candidate.length - 1) : candidate;
}
