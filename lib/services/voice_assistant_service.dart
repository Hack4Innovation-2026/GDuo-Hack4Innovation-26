import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

class VoiceAssistantService {
  VoiceAssistantService({
    FlutterTts? tts,
    stt.SpeechToText? speechToText,
    bool enableSpeech = true,
  })  : _tts = tts ?? FlutterTts(),
        _speech = speechToText ?? stt.SpeechToText(),
        _speechEnabled = enableSpeech;

  final FlutterTts _tts;
  final stt.SpeechToText _speech;

  final ValueNotifier<bool> isListening = ValueNotifier<bool>(false);
  final ValueNotifier<String> liveTranscript = ValueNotifier<String>('');
  final ValueNotifier<String?> lastError = ValueNotifier<String?>(null);

  bool _initialized = false;
  bool _isBusy = false;
  bool _speechAvailable = false;
  String _localeId = 'en_IN';
  String _ttsLanguage = 'en-IN';
  final bool _speechEnabled;

  Future<void> Function(String text)? _pendingUserResponse;
  Completer<void>? _listenCompleter;
  String _finalResult = '';

  Future<void> initialize({String localeId = 'en_IN'}) async {
    if (_initialized) return;
    _localeId = localeId;
    _ttsLanguage = _languageForTts(localeId);
    await _configureTts();
    if (_speechEnabled) {
      _speechAvailable = await _speech.initialize(
        onError: _handleSpeechError,
        onStatus: _handleSpeechStatus,
      );
    } else {
      _speechAvailable = false;
    }
    _initialized = true;
  }

  Future<void> dispose() async {
    isListening.dispose();
    liveTranscript.dispose();
    lastError.dispose();
    await _speech.stop();
    await _speech.cancel();
    await _tts.stop();
  }

  Future<void> stop() async {
    _pendingUserResponse = null;
    _listenCompleter?.complete();
    _listenCompleter = null;
    _isBusy = false;
    isListening.value = false;
    liveTranscript.value = '';
    await _speech.stop();
    await _speech.cancel();
    await _tts.stop();
  }

  Future<void> setLocale(String localeId) async {
    _localeId = localeId;
    _ttsLanguage = _languageForTts(localeId);
    await _tts.setLanguage(_ttsLanguage);
  }

  Future<void> speak(String text) async {
    if (text.trim().isEmpty) return;
    if (!_initialized) {
      await initialize(localeId: _localeId);
    }
    lastError.value = null;
    await _tts.stop();
    await _tts.speak(text);
  }

  Future<void> onSignboardDetected(
    String label, {
    required Future<void> Function(String text) onUserResponse,
  }) async {
    if (_isBusy) return;
    if (!_initialized) {
      await initialize(localeId: _localeId);
    }
    _isBusy = true;
    lastError.value = null;
    liveTranscript.value = '';
    _pendingUserResponse = onUserResponse;

    final prompt = 'I see a $label sign. Do you need help?';
    final result = await _tts.speak(prompt);
    if ((result is int && result == 0) || (result is bool && result == false)) {
      _isBusy = false;
      _pendingUserResponse = null;
      lastError.value = 'Unable to start speech synthesis.';
    }
  }

  Future<void> _configureTts() async {
    try {
      await _tts.setEngine('com.google.android.tts');
    } catch (_) {
      // Best-effort: if Google engine isn't available, keep default.
    }
    try {
      await _tts.awaitSpeakCompletion(true);
    } catch (_) {
      // Some platforms do not support awaitSpeakCompletion.
    }
    await _tts.setLanguage(_ttsLanguage);
    await _tts.setSpeechRate(0.5);
    await _tts.setPitch(1.0);
    _tts.setCompletionHandler(_handleTtsComplete);
    _tts.setErrorHandler((message) {
      lastError.value = 'TTS error: $message';
      _pendingUserResponse = null;
      _isBusy = false;
    });
  }

  void _handleTtsComplete() {
    final pendingResponse = _pendingUserResponse;
    if (pendingResponse == null) {
      _isBusy = false;
      return;
    }
    _pendingUserResponse = null;
    unawaited(_startListening(pendingResponse));
  }

  Future<void> _startListening(Future<void> Function(String text) onUserResponse) async {
    if (!_speechEnabled) {
      lastError.value = 'Speech recognition is disabled.';
      _isBusy = false;
      return;
    }
    final hasMicPermission = await _ensureMicrophonePermission();
    if (!hasMicPermission) {
      _isBusy = false;
      return;
    }
    if (!_speechAvailable) {
      _speechAvailable = await _speech.initialize(
        onError: _handleSpeechError,
        onStatus: _handleSpeechStatus,
      );
    }
    if (!_speechAvailable) {
      lastError.value = 'Speech recognition unavailable on this device.';
      _isBusy = false;
      return;
    }

    _finalResult = '';
    lastError.value = null;
    liveTranscript.value = '';
    isListening.value = true;
    _listenCompleter = Completer<void>();

    try {
      await _speech.listen(
        onResult: (result) {
          liveTranscript.value = result.recognizedWords;
          if (result.finalResult) {
            _finalResult = result.recognizedWords;
          }
        },
        listenMode: stt.ListenMode.confirmation,
        localeId: _localeId,
        partialResults: true,
        onDevice: false,
        cancelOnError: true,
        listenFor: const Duration(seconds: 8),
        pauseFor: const Duration(seconds: 2),
      );

      await _listenCompleter?.future;
    } catch (_) {
      lastError.value = 'Unable to start listening.';
      _isBusy = false;
      return;
    } finally {
      isListening.value = false;
    }

    final finalText = _finalResult.trim();
    if (finalText.isEmpty) {
      lastError.value = 'No speech detected.';
      _isBusy = false;
      return;
    }
    await onUserResponse(finalText);
    liveTranscript.value = '';
    _isBusy = false;
  }

  Future<bool> _ensureMicrophonePermission() async {
    final micPermission = await Permission.microphone.request();
    if (micPermission.isGranted) {
      return true;
    }
    lastError.value = micPermission.isPermanentlyDenied
        ? 'Microphone permission denied. Enable it in Settings.'
        : 'Microphone permission denied.';
    return false;
  }

  void _handleSpeechStatus(String status) {
    if (status == 'listening') {
      isListening.value = true;
    }
    if (status == 'notListening' || status == 'done') {
      if (!(_listenCompleter?.isCompleted ?? true)) {
        _listenCompleter?.complete();
      }
      _listenCompleter = null;
    }
  }

  void _handleSpeechError(dynamic error) {
    final message = _extractSpeechErrorMessage(error);
    lastError.value = message ?? 'Speech recognition error.';
    if (!(_listenCompleter?.isCompleted ?? true)) {
      _listenCompleter?.complete();
    }
    _listenCompleter = null;
    isListening.value = false;
    _isBusy = false;
  }

  String _languageForTts(String localeId) {
    return localeId.replaceAll('_', '-');
  }

  String? _extractSpeechErrorMessage(dynamic error) {
    if (error == null) return null;
    try {
      final dynamic message = error.errorMsg ?? error.message;
      if (message != null) return message.toString();
    } catch (_) {}
    if (error is Map) {
      final message = error['errorMsg'] ?? error['message'];
      if (message != null) return message.toString();
    }
    return error.toString();
  }
}
