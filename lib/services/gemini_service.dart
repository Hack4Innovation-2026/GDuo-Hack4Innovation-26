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
ROLE: You are DrishtiAI, a smart reading assistant for a blind user.
TASK: From OCR text and the image, speak ONE helpful sentence (<= 35 words) that conveys the signboard's core meaning.
LANGUAGE: Respond in the preferred language if provided; otherwise match the dominant script of OCR (Devanagari -> Hindi/Marathi, Tamil -> Tamil, Latin -> English). If unsure, use English.
PRIORITY: (1) Emergency / danger / hospital warnings and their directions, (2) organization or place name, (3) key services like emergency/admissions/parking, (4) important numbers (phone/price).
EMERGENCY RULE: If emergency/casualty/ambulance/fire/police/danger appears, mention it first and include direction if present.
RULES: Ignore ads, slogans, decorative text, URLs, app names, web search results, legal disclaimers, repeated lines, and background UI text.
If the sign lists multiple key items, merge them into one sentence separated by commas or semicolons.
If nothing useful is found, return an empty speak string.
OUTPUT: Return ONLY strict JSON with two fields: speak (string) and action (null or {type: call|maps, value}).
EXAMPLES:
OCR: Springs Memorial Hospital
EMERGENCY left
Admissions
Visitor Parking -> {"speak":"Springs Memorial Hospital ? emergency left; admissions, visitor parking.","action":null}
OCR: Patel Medicals
Call 9876543210
Open 24x7 -> {"speak":"Patel Medicals. Call 9876543210. Open 24x7.","action":{"type":"call","value":"9876543210"}}
OCR: ?????? ???????
??????? ?????
??????
???????? -> {"speak":"??????? ?????; ?????? ?? ????????. ?????? ???????.","action":null}
OCR: ??? ????????
??? ??????????
24x7 ???? -> {"speak":"??? ????????. ??? 9876543210. 24x7 ????.","action":{"type":"call","value":"9876543210"}}
OCR: ???????????
?????? ????
????????
??????????? ?????????? -> {"speak":"??????????? ? ?????? ????; ????????, ??????????? ??????????.","action":null}
OCR: ?????????
????
??????
???????? -> {"speak":"????????? ????; ?????? ??? ????????.","action":null}
OCR: SALE 50% OFF
www.example.com -> {"speak":"","action":null}
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

Return ONLY valid JSON in this exact shape (no markdown, no extra keys):
{"speak":"...","action":null}
or
{"speak":"...","action":{"type":"call","value":"..."}}
or
{"speak":"...","action":{"type":"maps","value":"..."}}
If nothing useful exists, return {"speak":"","action":null}.

Examples:
OCR: "Springs Memorial Hospital
EMERGENCY left
Admissions
Visitor Parking"
Output: {"speak":"Springs Memorial Hospital ? emergency left; admissions, visitor parking.","action":null}

OCR: "SALE 50% OFF
www.example.com"
Output: {"speak":"","action":null}

Focus on signboard content and directions. Keep it to one sentence with commas if needed.
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
        'temperature': 0.2,
        'max_output_tokens': 200,
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
