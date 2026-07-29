import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:http/http.dart' as http;

class GeminiService {
  GeminiService({
    String? apiKey,
    String? model,
  })  : _apiKey = _firstNonEmpty([
          apiKey,
          dotenv.isInitialized ? dotenv.env['GEMINI_API_KEY'] : null,
          const String.fromEnvironment('GEMINI_API_KEY'),
        ]),
        _model = _firstNonEmpty([
          model,
          dotenv.isInitialized ? dotenv.env['GEMINI_MODEL'] : null,
          const String.fromEnvironment('GEMINI_MODEL'),
          'gemini-2.5-flash',
        ]);

  final String _apiKey;
  final String _model;

  static const Duration _requestTimeout = Duration(seconds: 25);

  static String _firstNonEmpty(List<String?> values) {
    for (final value in values) {
      final normalized = _normalizeConfigValue(value);
      if (normalized.isNotEmpty) return normalized;
    }
    return '';
  }

  static String _normalizeConfigValue(String? value) {
    final trimmed = value?.trim() ?? '';
    if (trimmed.isEmpty) return '';
    if ((trimmed.startsWith('"') && trimmed.endsWith('"')) ||
        (trimmed.startsWith("'") && trimmed.endsWith("'"))) {
      return trimmed.substring(1, trimmed.length - 1).trim();
    }
    return trimmed;
  }

  bool get hasApiKey => _apiKey.isNotEmpty;

  static const String _systemInstruction = '''
You are DrishtiAI. Read signboards for a blind user.
Use OCR text and the image to infer the signboard's core meaning.
Respond in the preferred language if provided; otherwise match the dominant OCR script (Devanagari -> Hindi/Marathi, Tamil -> Tamil, Latin -> English).
Output ONE concise sentence (<= 25 words).
If emergency/danger/ambulance/fire/police appears, mention it first and include direction if present.
Include organization/place name, key services (emergency/admissions/parking), and phone numbers when present.
Do not only read the header; include key items from all lines if present.
Ignore ads, slogans, URLs, app/browser UI, search results, watermarks, legal disclaimers, repeated lines, and noise.
If nothing meaningful is found, return {"speak":"","action":null}.
Return ONLY strict JSON: {"speak":"...","action":null} or {"speak":"...","action":{"type":"call|maps","value":"..."}}.
''';

  static const String _conversationInstruction = '''
You are DrishtiAI. Your job is to answer the user's spoken question using OCR text + image context.
Always prioritize the question. Do not answer something unrelated or partial.
First identify the relevant info in the OCR (item names, prices, directions, availability). Then answer the question directly.
Reply with ONE short sentence (<= 25 words) that is the final answer (no filler, no restating the OCR).
If the answer is not visible or cannot be inferred, say: "I cannot see that."
If multiple options match, give the best single answer; if truly ambiguous, say you cannot see it.
Respond in the preferred language if provided; otherwise match the dominant OCR script.
Ignore ads, slogans, URLs, app/browser UI, search results, watermarks, legal disclaimers, repeated lines, and noise.
Return ONLY strict JSON: {"speak":"...","action":null} or {"speak":"...","action":{"type":"call|maps","value":"..."}}.
''';

  static const String _intentInstruction = '''
You are DrishtiAI. Determine if the signboard matches the user's intent.
Use the OCR text and image context. Consider synonyms (e.g., medical store/pharmacy/chemist).
Return strict JSON only: {"match":true,"category":"medical"} or {"match":false}.
If unclear, return {"match":false}.
''';

  Future<GeminiResult?> analyze({
    required String ocrText,
    required Uint8List jpegBytes,
    String? preferredLanguage,
  }) async {
    if (_apiKey.isEmpty) return null;

    final languageHint = (preferredLanguage == null || preferredLanguage.trim().isEmpty)
        ? 'Auto'
        : preferredLanguage.trim();

    final prompt = '''
OCR TEXT:
$ocrText

Preferred language: $languageHint

Return ONLY JSON (no markdown, no extra keys):
{"speak":"...","action":null}
or
{"speak":"...","action":{"type":"call","value":"..."}}
or
{"speak":"...","action":{"type":"maps","value":"..."}}
If nothing useful exists, return {"speak":"","action":null}.
''';

    final body = jsonEncode({
      'systemInstruction': {
        'parts': [
          {'text': _systemInstruction},
        ],
      },
      'contents': [
        {
          'role': 'user',
          'parts': [
            {'text': prompt},
            {
              'inline_data': {
                'mime_type': 'image/jpeg',
                'data': base64Encode(jpegBytes),
              },
            },
          ],
        },
      ],
      'generation_config': {
        'temperature': 0.1,
        'max_output_tokens': 120,
        'response_mime_type': 'application/json',
      },
    });

    final response = await _postWithFallback(body);
    if (response.statusCode != 200) {
      throw Exception(_httpErrorMessage(response));
    }

    final rawText = _extractPrimaryText(response.body);
    if (rawText.isEmpty) return null;

    final parsed = _parseJson(rawText);
    if (parsed != null) return parsed;

    // Fallback to plain text answer when model returns non-JSON text.
    return GeminiResult(speak: _fallbackSpeak(rawText), action: null);
  }

  Future<GeminiResult?> analyzeConversation({
    required String question,
    required String ocrText,
    Uint8List? jpegBytes,
    String? preferredLanguage,
  }) async {
    if (_apiKey.isEmpty) return null;

    final languageHint = (preferredLanguage == null || preferredLanguage.trim().isEmpty)
        ? 'Auto'
        : preferredLanguage.trim();

    final prompt = '''
USER QUESTION:
$question

OCR TEXT:
$ocrText

Preferred language: $languageHint

Return ONLY JSON (no markdown, no extra keys):
{"speak":"...","action":null}
or
{"speak":"...","action":{"type":"call","value":"..."}}
or
{"speak":"...","action":{"type":"maps","value":"..."}}
If nothing useful exists, return {"speak":"","action":null}.
''';

    final parts = <Map<String, dynamic>>[
      {'text': prompt},
    ];
    if (jpegBytes != null && jpegBytes.isNotEmpty) {
      parts.add({
        'inline_data': {
          'mime_type': 'image/jpeg',
          'data': base64Encode(jpegBytes),
        },
      });
    }

    final body = jsonEncode({
      'systemInstruction': {
        'parts': [
          {'text': _conversationInstruction},
        ],
      },
      'contents': [
        {
          'role': 'user',
          'parts': parts,
        },
      ],
      'generation_config': {
        'temperature': 0.2,
        'max_output_tokens': 140,
        'response_mime_type': 'application/json',
      },
    });

    final response = await _postWithFallback(body);
    if (response.statusCode != 200) {
      throw Exception(_httpErrorMessage(response));
    }

    final rawText = _extractPrimaryText(response.body);
    if (rawText.isEmpty) return null;

    final parsed = _parseJson(rawText);
    if (parsed != null) return parsed;
    return GeminiResult(speak: _fallbackSpeak(rawText), action: null);
  }

  Future<IntentMatch?> analyzeIntent({
    required String intent,
    required String ocrText,
    required Uint8List jpegBytes,
  }) async {
    if (_apiKey.isEmpty) return null;

    final prompt = '''
USER INTENT:
$intent

OCR TEXT:
$ocrText

Return ONLY JSON:
{"match":true,"category":"..."}
or
{"match":false}
''';

    final body = jsonEncode({
      'systemInstruction': {
        'parts': [
          {'text': _intentInstruction},
        ],
      },
      'contents': [
        {
          'role': 'user',
          'parts': [
            {'text': prompt},
            {
              'inline_data': {
                'mime_type': 'image/jpeg',
                'data': base64Encode(jpegBytes),
              },
            },
          ],
        },
      ],
      'generation_config': {
        'temperature': 0.1,
        'max_output_tokens': 60,
        'response_mime_type': 'application/json',
      },
    });

    final response = await _postWithFallback(body);
    if (response.statusCode != 200) {
      throw Exception(_httpErrorMessage(response));
    }

    final rawText = _extractPrimaryText(response.body);
    if (rawText.isEmpty) return null;

    final parsed = _parseIntentJson(rawText);
    if (parsed != null) return parsed;
    return _fallbackIntent(rawText);
  }

  Future<http.Response> _postWithFallback(Object body) async {
    final candidates = <String>[
      _model,
      'gemini-2.5-flash',
      'gemini-2.0-flash',
      'gemini-2.5-flash-latest',
      'gemini-2.5-pro',
      'gemini-2.5-pro-latest',
      'gemini-2.5-flash-lite',
      'gemini-1.5-flash',
      'gemini-1.5-flash-latest',
    ];
    const apiVersions = <String>['v1', 'v1beta'];
    http.Response? lastResponse;
    final seen = <String>{};
    for (final apiVersion in apiVersions) {
      for (final model in candidates) {
        final trimmed = model.trim();
        if (trimmed.isEmpty || !seen.add('$apiVersion::$trimmed')) continue;

        final uri = Uri.parse(
          'https://generativelanguage.googleapis.com/$apiVersion/models/$trimmed:generateContent?key=$_apiKey',
        );
        final response = await http
            .post(
              uri,
              headers: {
                'Content-Type': 'application/json',
              },
              body: body,
            )
            .timeout(_requestTimeout);

        lastResponse = response;
        if (response.statusCode == 200) return response;
        // 404 = model not found, 403 = model not accessible/permission issue - try next.
        if (response.statusCode != 404 && response.statusCode != 403) return response;
      }
    }

    if (lastResponse != null) return lastResponse;
    throw Exception('Gemini HTTP 404');
  }

  String _extractPrimaryText(String responseBody) {
    final decoded = jsonDecode(responseBody) as Map<String, dynamic>;
    final candidates = decoded['candidates'] as List<dynamic>?;
    if (candidates == null || candidates.isEmpty) return '';

    final content = candidates.first['content'] as Map<String, dynamic>?;
    final parts = content?['parts'] as List<dynamic>?;
    if (parts == null || parts.isEmpty) return '';

    final buffer = StringBuffer();
    for (final part in parts) {
      if (part is Map<String, dynamic>) {
        final text = part['text']?.toString() ?? '';
        if (text.isNotEmpty) {
          if (buffer.isNotEmpty) buffer.write('\n');
          buffer.write(text);
        }
      }
    }
    return buffer.toString().trim();
  }

  String _fallbackSpeak(String rawText) {
    final cleaned = rawText
        .replaceAll('```json', '')
        .replaceAll('```', '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (cleaned.isEmpty) return '';
    if (cleaned.length <= 140) return cleaned;
    return '${cleaned.substring(0, 140).trimRight()}...';
  }

  String _httpErrorMessage(http.Response response) {
    final status = response.statusCode;
    final body = response.body;
    if (body.isEmpty) return 'Gemini HTTP $status';
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic>) {
        final error = decoded['error'];
        if (error is Map<String, dynamic>) {
          final message = error['message']?.toString().trim() ?? '';
          if (message.isNotEmpty) {
            return 'Gemini HTTP $status: $message';
          }
        }
      }
    } catch (_) {}
    final snippet = body.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (snippet.isEmpty) return 'Gemini HTTP $status';
    final short = snippet.length <= 160 ? snippet : '${snippet.substring(0, 160)}...';
    return 'Gemini HTTP $status: $short';
  }

  GeminiResult? _parseJson(String rawText) {
    final map = _extractJsonMap(rawText);
    if (map == null) return null;

    final speak = map['speak']?.toString() ?? '';
    final action = map['action'];

    GeminiAction? parsedAction;
    if (action is Map<String, dynamic>) {
      final type = action['type']?.toString();
      final value = action['value']?.toString();
      if (type != null && value != null && value.isNotEmpty) {
        parsedAction = GeminiAction(type: type, value: value);
      }
    }
    return GeminiResult(speak: speak, action: parsedAction);
  }

  IntentMatch? _parseIntentJson(String rawText) {
    final map = _extractJsonMap(rawText);
    if (map == null) return null;

    final match = map['match'];
    if (match is! bool) return null;
    final category = map['category']?.toString();
    return IntentMatch(match: match, category: category);
  }

  Map<String, dynamic>? _extractJsonMap(String rawText) {
    // Fast path: full text is JSON.
    try {
      final direct = jsonDecode(rawText);
      if (direct is Map<String, dynamic>) return direct;
    } catch (_) {}

    // Remove code fences and retry.
    final cleaned = rawText.replaceAll('```json', '').replaceAll('```', '').trim();
    try {
      final decoded = jsonDecode(cleaned);
      if (decoded is Map<String, dynamic>) return decoded;
    } catch (_) {}

    // Brace-balanced extraction fallback.
    final start = cleaned.indexOf('{');
    if (start < 0) return null;
    var depth = 0;
    for (var i = start; i < cleaned.length; i++) {
      final ch = cleaned[i];
      if (ch == '{') depth++;
      if (ch == '}') {
        depth--;
        if (depth == 0) {
          final candidate = cleaned.substring(start, i + 1);
          try {
            final decoded = jsonDecode(candidate);
            if (decoded is Map<String, dynamic>) return decoded;
          } catch (_) {
            return null;
          }
        }
      }
    }
    return null;
  }

  IntentMatch _fallbackIntent(String rawText) {
    final lower = rawText.toLowerCase();
    final matched = lower.contains('"match":true') ||
        lower.contains('"match": true') ||
        lower.contains('match true') ||
        lower.contains('yes');
    return IntentMatch(match: matched, category: null);
  }
}

class GeminiResult {
  GeminiResult({required this.speak, required this.action});

  final String speak;
  final GeminiAction? action;
}

class GeminiAction {
  GeminiAction({required this.type, required this.value});

  final String type;
  final String value;
}

class IntentMatch {
  IntentMatch({required this.match, this.category});

  final bool match;
  final String? category;
}
