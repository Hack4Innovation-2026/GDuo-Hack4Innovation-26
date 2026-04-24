import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:http/http.dart' as http;

import '../config/config.dart';

class GeminiService {
  GeminiService({
    String? apiKey,
    String? model,
  })  : _apiKey = apiKey ??
            (const String.fromEnvironment('GEMINI_API_KEY').isNotEmpty
                ? const String.fromEnvironment('GEMINI_API_KEY')
                : (dotenv.isInitialized &&
                        (dotenv.env['GEMINI_API_KEY'] ?? '').isNotEmpty
                    ? dotenv.env['GEMINI_API_KEY']!
                    : '')),
        _model = model ??
            (const String.fromEnvironment('GEMINI_MODEL').isNotEmpty
                ? const String.fromEnvironment('GEMINI_MODEL')
                : (dotenv.isInitialized &&
                        (dotenv.env['GEMINI_MODEL'] ?? '').isNotEmpty
                    ? dotenv.env['GEMINI_MODEL']!
                    : 'gemini-2.5-flash'));

  final String _apiKey;
  final String _model;

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
    if (_apiKey.isEmpty) {
      // Avoid spamming logs on every frame.
      return null;
    }

    final languageHint = (preferredLanguage == null || preferredLanguage!.trim().isEmpty)
        ? 'Auto'
        : preferredLanguage!.trim();
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
      },
    });

    final response = await _postWithFallback(body);

    if (response.statusCode != 200) {
      throw Exception('Gemini HTTP ${response.statusCode}');
    }

    final decoded = jsonDecode(response.body) as Map<String, dynamic>;
    final candidates = decoded['candidates'] as List<dynamic>?;
    if (candidates == null || candidates.isEmpty) {
      return null;
    }
    final content = candidates.first['content'] as Map<String, dynamic>?;
    final parts = content?['parts'] as List<dynamic>?;
    if (parts == null || parts.isEmpty) {
      return null;
    }
    final rawText = parts.first['text']?.toString() ?? '';
    if (rawText.isEmpty) {
      return null;
    }

    final parsed = _parseJson(rawText);
    if (parsed == null) {
      throw Exception('Unable to parse Gemini JSON response.');
    }
    return parsed;
  }

  Future<GeminiResult?> analyzeConversation({
    required String question,
    required String ocrText,
    required Uint8List jpegBytes,
    String? preferredLanguage,
  }) async {
    if (_apiKey.isEmpty) {
      return null;
    }

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

    final body = jsonEncode({
      'systemInstruction': {
        'parts': [
          {'text': _conversationInstruction},
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
        'temperature': 0.2,
        'max_output_tokens': 140,
      },
    });

    final response = await _postWithFallback(body);

    if (response.statusCode != 200) {
      throw Exception('Gemini HTTP ${response.statusCode}');
    }

    final decoded = jsonDecode(response.body) as Map<String, dynamic>;
    final candidates = decoded['candidates'] as List<dynamic>?;
    if (candidates == null || candidates.isEmpty) {
      return null;
    }
    final content = candidates.first['content'] as Map<String, dynamic>?;
    final parts = content?['parts'] as List<dynamic>?;
    if (parts == null || parts.isEmpty) {
      return null;
    }
    final rawText = parts.first['text']?.toString() ?? '';
    if (rawText.isEmpty) {
      return null;
    }

    final parsed = _parseJson(rawText);
    if (parsed == null) {
      throw Exception('Unable to parse Gemini JSON response.');
    }
    return parsed;
  }

  Future<IntentMatch?> analyzeIntent({
    required String intent,
    required String ocrText,
    required Uint8List jpegBytes,
  }) async {
    if (_apiKey.isEmpty) {
      return null;
    }

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
      },
    });

    final response = await _postWithFallback(body);

    if (response.statusCode != 200) {
      throw Exception('Gemini HTTP ${response.statusCode}');
    }

    final decoded = jsonDecode(response.body) as Map<String, dynamic>;
    final candidates = decoded['candidates'] as List<dynamic>?;
    if (candidates == null || candidates.isEmpty) {
      return null;
    }
    final content = candidates.first['content'] as Map<String, dynamic>?;
    final parts = content?['parts'] as List<dynamic>?;
    if (parts == null || parts.isEmpty) {
      return null;
    }
    final rawText = parts.first['text']?.toString() ?? '';
    if (rawText.isEmpty) {
      return null;
    }

    final parsed = _parseIntentJson(rawText);
    if (parsed == null) {
      throw Exception('Unable to parse Gemini intent JSON response.');
    }
    return parsed;
  }

  Future<http.Response> _postWithFallback(Object body) async {
    final candidates = <String>[
      _model,
      'gemini-2.5-flash',
      'gemini-2.5-flash-latest',
      'gemini-2.5-pro',
      'gemini-2.5-pro-latest',
      'gemini-2.5-flash-lite',
    ];
    http.Response? lastResponse;
    final seen = <String>{};
    for (final model in candidates) {
      final trimmed = model.trim();
      if (trimmed.isEmpty) continue;
      if (!seen.add(trimmed)) continue;
      final uri = Uri.parse(
        'https://generativelanguage.googleapis.com/v1beta/models/$trimmed:generateContent?key=$_apiKey',
      );
      final response = await http.post(
        uri,
        headers: {
          'Content-Type': 'application/json',
        },
        body: body,
      );
      lastResponse = response;
      if (response.statusCode == 200) {
        return response;
      }
      if (response.statusCode != 404) {
        return response;
      }
    }
    if (lastResponse != null) {
      return lastResponse;
    }
    throw Exception('Gemini HTTP 404');
  }

  GeminiResult? _parseJson(String rawText) {
    final start = rawText.indexOf('{');
    final end = rawText.lastIndexOf('}');
    if (start == -1 || end == -1 || end <= start) {
      return null;
    }
    final jsonText = rawText.substring(start, end + 1);
    final decoded = jsonDecode(jsonText);
    if (decoded is! Map<String, dynamic>) return null;
    final speak = decoded['speak']?.toString() ?? '';
    final action = decoded['action'];
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
    final start = rawText.indexOf('{');
    final end = rawText.lastIndexOf('}');
    if (start == -1 || end == -1 || end <= start) {
      return null;
    }
    final jsonText = rawText.substring(start, end + 1);
    final decoded = jsonDecode(jsonText);
    if (decoded is! Map<String, dynamic>) return null;
    final match = decoded['match'];
    if (match is! bool) return null;
    final category = decoded['category']?.toString();
    return IntentMatch(match: match, category: category);
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
