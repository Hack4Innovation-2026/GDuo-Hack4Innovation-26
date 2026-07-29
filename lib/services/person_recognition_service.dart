import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:http/http.dart' as http;

class PersonRecognitionResult {
  const PersonRecognitionResult({
    required this.status,
    required this.message,
    required this.shouldAnnounce,
    required this.isKnown,
    this.name,
    this.distanceMeters,
    this.similarityDistance,
    this.gcsPath,
  });

  final String status;
  final String message;
  final bool shouldAnnounce;
  final bool isKnown;
  final String? name;
  final double? distanceMeters;
  final double? similarityDistance;
  final String? gcsPath;

  factory PersonRecognitionResult.fromJson(Map<String, dynamic> json) {
    return PersonRecognitionResult(
      status: json['status']?.toString() ?? 'no_person',
      message: json['message']?.toString() ?? '',
      shouldAnnounce: json['should_announce'] == true,
      isKnown: json['is_known'] == true,
      name: json['name']?.toString(),
      distanceMeters: (json['distance_meters'] as num?)?.toDouble(),
      similarityDistance: (json['similarity_distance'] as num?)?.toDouble(),
      gcsPath: json['gcs_path']?.toString(),
    );
  }
}

class PersonRegistrationResult {
  const PersonRegistrationResult({
    required this.success,
    required this.name,
    required this.recordsForPerson,
    required this.message,
    this.gcsPath,
  });

  final bool success;
  final String name;
  final int recordsForPerson;
  final String message;
  final String? gcsPath;

  factory PersonRegistrationResult.fromJson(Map<String, dynamic> json) {
    return PersonRegistrationResult(
      success: json['success'] == true,
      name: json['name']?.toString() ?? '',
      recordsForPerson: (json['records_for_person'] as num?)?.toInt() ?? 0,
      message: json['message']?.toString() ?? '',
      gcsPath: json['gcs_path']?.toString(),
    );
  }
}

class PersonRecognitionService {
  PersonRecognitionService({http.Client? client, String? baseUrl})
    : _client = client ?? http.Client(),
      _baseUrl = _resolveBaseUrl(baseUrl);

  final http.Client _client;
  final String _baseUrl;
  static const Duration _requestTimeout = Duration(seconds: 15);

  bool get isConfigured => _baseUrl.isNotEmpty;

  Future<void> ensureBackendHealthy() async {
    if (!isConfigured) {
      throw Exception('Person recognition backend is not configured.');
    }
    final uri = _buildUri('/health');
    try {
      final response = await _client.get(uri).timeout(_requestTimeout);
      if (response.statusCode == 200) return;
      throw Exception('Backend health check failed: HTTP ${response.statusCode}');
    } on TimeoutException {
      throw Exception('Person recognition backend health check timed out.');
    } on SocketException {
      throw Exception(
        'Unable to reach person recognition backend at $_baseUrl. Check server and phone network.',
      );
    } catch (e) {
      throw Exception('Backend health check failed: $e');
    }
  }

  Future<PersonRecognitionResult?> analyzeFrame({
    required Uint8List jpegBytes,
    required String language,
  }) async {
    if (!isConfigured) return null;
    final response = await _postJson(
      path: '/person-recognition/analyze',
      payload: {
        'image_base64': base64Encode(jpegBytes),
        'language': _normalizeLanguage(language),
      },
      fallbackMessage: 'Person recognition request timed out. Check backend connection.',
    );
    _throwIfNotOk(
      response,
      fallbackMessage: 'Person recognition HTTP ${response.statusCode}',
    );
    final decoded = jsonDecode(response.body) as Map<String, dynamic>;
    return PersonRecognitionResult.fromJson(decoded);
  }

  Future<PersonRegistrationResult> registerPerson({
    required String name,
    required Uint8List jpegBytes,
  }) async {
    if (!isConfigured) {
      throw Exception('Person recognition backend is not configured.');
    }
    final response = await _postJson(
      path: '/person-recognition/register',
      payload: {
        'name': name.trim(),
        'image_base64': base64Encode(jpegBytes),
      },
      fallbackMessage: 'Person registration timed out. Check backend connection.',
    );
    _throwIfNotOk(
      response,
      fallbackMessage: 'Person registration HTTP ${response.statusCode}',
    );
    final decoded = jsonDecode(response.body) as Map<String, dynamic>;
    return PersonRegistrationResult.fromJson(decoded);
  }

  void dispose() {
    _client.close();
  }

  Uri _buildUri(String path) {
    final normalizedBase =
        _baseUrl.endsWith('/')
            ? _baseUrl.substring(0, _baseUrl.length - 1)
            : _baseUrl;
    return Uri.parse('$normalizedBase$path');
  }

  Future<http.Response> _postJson({
    required String path,
    required Map<String, dynamic> payload,
    required String fallbackMessage,
  }) async {
    final uri = _buildUri(path);
    try {
      return await _client
          .post(
            uri,
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode(payload),
          )
          .timeout(_requestTimeout);
    } on TimeoutException {
      throw Exception(fallbackMessage);
    } on SocketException {
      throw Exception(
        'Unable to reach person recognition backend at $_baseUrl. Check server and phone network.',
      );
    } catch (e) {
      throw Exception('Person recognition request failed: $e');
    }
  }

  static String _normalizeLanguage(String language) {
    final trimmed = language.trim();
    if (trimmed == 'Hindi') return 'Hindi';
    if (trimmed == 'Marathi') return 'Marathi';
    return 'English';
  }

  static String _resolveBaseUrl(String? override) {
    for (final candidate in [
      override,
      const String.fromEnvironment('PERSON_RECOGNITION_API_BASE_URL'),
      dotenv.isInitialized
          ? dotenv.env['PERSON_RECOGNITION_API_BASE_URL']
          : null,
    ]) {
      final trimmed = (candidate ?? '').trim();
      if (_isUsableConfigValue(trimmed)) {
        return trimmed;
      }
    }
    return '';
  }

  static bool _isUsableConfigValue(String value) {
    if (value.isEmpty) return false;
    final normalized = value.toUpperCase();
    if (normalized.startsWith('YOUR_')) return false;
    if (normalized.contains('PLACEHOLDER')) return false;
    if (!(value.startsWith('http://') || value.startsWith('https://'))) return false;
    return true;
  }

  static void _throwIfNotOk(
    http.Response response, {
    required String fallbackMessage,
  }) {
    if (response.statusCode == 200) return;
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map<String, dynamic>) {
        final detail = decoded['detail']?.toString().trim();
        final message = decoded['message']?.toString().trim();
        final error = detail?.isNotEmpty == true ? detail! : message;
        if (error != null && error.isNotEmpty) {
          throw Exception(error);
        }
      }
    } catch (_) {
      // Fall through to the generic message if the backend body isn't JSON.
    }
    throw Exception(fallbackMessage);
  }
}
