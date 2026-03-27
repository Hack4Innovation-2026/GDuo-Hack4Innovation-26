import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

class GeminiService {
  GeminiService({
    String? apiKey,
    String? model,
  })  : _apiKey = apiKey ?? const String.fromEnvironment('GEMINI_API_KEY'),
        _model = model ??
            const String.fromEnvironment(
              'GEMINI_MODEL',
              defaultValue: 'gemini-1.5-flash',
            );

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

  Future<GeminiResult?> analyze({
    required String ocrText,
    required Uint8List jpegBytes,
    String? preferredLanguage,
  }) async {
    if (_apiKey.isEmpty) {
      // Avoid spamming logs on every frame.
      return null;
    }

    final uri = Uri.parse(
      'https://generativelanguage.googleapis.com/v1beta/models/$_model:generateContent?key=$_apiKey',
    );

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

    final response = await http.post(
      uri,
      headers: {
        'Content-Type': 'application/json',
      },
      body: body,
    );

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
