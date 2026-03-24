import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:permission_handler/permission_handler.dart';

import '../services/voice_assistant_service.dart';

enum HomeState { idle, permission, scanning }

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  HomeState _currentState = HomeState.idle;
  bool _soundEnabled = true;
  String _selectedLanguage = 'English';

  CameraController? _cameraController;
  bool _cameraReady = false;
  bool _isInitializingCamera = false;
  bool _isStreaming = false;
  String? _cameraError;

  late final VoiceAssistantService _voiceAssistant;
  late final AnimationController _micPulseController;
  late final Animation<double> _micPulseAnimation;
  late final VoidCallback _micListeningListener;

  late final TextRecognizer _latinTextRecognizer;
  late final TextRecognizer _devanagariTextRecognizer;
  late final TextRecognizer _tamilTextRecognizer;

  bool _isProcessingFrame = false;
  DateTime _lastAnalysisTime = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastEmitTime = DateTime.fromMillisecondsSinceEpoch(0);
  String _lastEmittedText = '';
  String _latestOcrText = '';

  static const Duration _analysisInterval = Duration(milliseconds: 800);
  static const Duration _emitCooldown = Duration(milliseconds: 1500);

  static const Map<DeviceOrientation, int> _deviceRotation = {
    DeviceOrientation.portraitUp: 0,
    DeviceOrientation.landscapeLeft: 90,
    DeviceOrientation.portraitDown: 180,
    DeviceOrientation.landscapeRight: 270,
  };

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _latinTextRecognizer = TextRecognizer(script: _scriptByName('latin'));
    _devanagariTextRecognizer = TextRecognizer(script: _scriptByName('devanagari'));
    _tamilTextRecognizer = TextRecognizer(script: _scriptByName('tamil'));

    _voiceAssistant = VoiceAssistantService();
    unawaited(_voiceAssistant.initialize(localeId: 'en_IN'));

    _micPulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
    _micPulseAnimation = Tween<double>(begin: 1.0, end: 1.15).animate(
      CurvedAnimation(parent: _micPulseController, curve: Curves.easeInOut),
    );
    _micListeningListener = () {
      if (_voiceAssistant.isListening.value) {
        if (!_micPulseController.isAnimating) {
          _micPulseController.repeat(reverse: true);
        }
      } else {
        _micPulseController.stop();
        _micPulseController.value = 0;
      }
    };
    _voiceAssistant.isListening.addListener(_micListeningListener);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stopCamera();
    _latinTextRecognizer.close();
    _devanagariTextRecognizer.close();
    _tamilTextRecognizer.close();
    _voiceAssistant.isListening.removeListener(_micListeningListener);
    _micPulseController.dispose();
    unawaited(_voiceAssistant.dispose());
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_currentState != HomeState.scanning) return;
    if (state == AppLifecycleState.paused || state == AppLifecycleState.inactive) {
      _stopCamera();
      return;
    }
    if (state == AppLifecycleState.resumed && _cameraController == null) {
      _initializeCamera();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Stack(
          children: [
            _buildMainContent(),
            _buildTopRightSettings(),
            _buildBottomRightSOS(),
          ],
        ),
      ),
    );
  }

  Widget _buildMainContent() {
    switch (_currentState) {
      case HomeState.idle:
        return _buildIdleState();
      case HomeState.permission:
        return _buildPermissionState();
      case HomeState.scanning:
        return _buildScanningState();
    }
  }

  Widget _buildIdleState() {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        // Typically check permission here. For now, go to permission.
        setState(() => _currentState = HomeState.permission);
      },
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              'Tap anywhere to start',
              style: GoogleFonts.outfit(
                fontSize: 32,
                fontWeight: FontWeight.w700,
                color: const Color(0xFF1A1A1A), // High contrast dark text
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            Text(
              'DrishtiAI is ready.',
              style: GoogleFonts.outfit(
                fontSize: 24,
                fontWeight: FontWeight.w500,
                color: const Color(0xFF4A4A4A),
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPermissionState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Card(
          elevation: 4,
          color: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 32.0, horizontal: 24.0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.camera_alt_rounded, size: 48, color: Color(0xFF1A56DB)),
                const SizedBox(height: 16),
                Text(
                  'Camera & Microphone Access',
                  style: GoogleFonts.outfit(fontSize: 24, fontWeight: FontWeight.bold, color: const Color(0xFF1A1A1A)),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 12),
                Text(
                  'DrishtiAI needs access to your camera and microphone to assist you.',
                  style: GoogleFonts.outfit(fontSize: 18, color: const Color(0xFF4A4A4A)),
                  textAlign: TextAlign.center,
                ),
                if (_cameraError != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    _cameraError!,
                    style: GoogleFonts.outfit(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: const Color(0xFFCC0000),
                    ),
                    textAlign: TextAlign.center,
                  ),
                ],
                const SizedBox(height: 32),
                ElevatedButton(
                  onPressed: _startOcrPipeline,
                  child: const Text('Grant Access', style: TextStyle(fontSize: 20)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildScanningState() {
    final statusText = _cameraError != null
        ? 'Camera error'
        : !_cameraReady
            ? 'Starting camera...'
            : 'Reading signboards...';

    return Stack(
      fit: StackFit.expand,
      children: [
        _buildCameraPreview(),
        Positioned(
          bottom: 100,
          left: 24,
          right: 24,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildVoiceOverlay(),
              if (_latestOcrText.isNotEmpty) ...[
                const SizedBox(height: 12),
                _buildOcrOverlay(),
              ],
            ],
          ),
        ),
        // Status Pill
        Positioned(
          bottom: 24,
          left: 24,
          right: 24,
          child: Center(
            child: Container(
              height: 64, // max 80dp
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.7),
                borderRadius: BorderRadius.circular(32),
              ),
              child: Center(
                child: Text(
                  statusText,
                  style: GoogleFonts.outfit(
                    fontSize: 20,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildCameraPreview() {
    final controller = _cameraController;
    if (controller == null || !controller.value.isInitialized) {
      return Container(
        color: Colors.black,
        child: const Center(
          child: Icon(Icons.camera, color: Colors.white54, size: 64),
        ),
      );
    }
    return CameraPreview(controller);
  }

  Widget _buildOcrOverlay() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Text(
        _latestOcrText,
        maxLines: 4,
        overflow: TextOverflow.ellipsis,
        style: GoogleFonts.outfit(
          fontSize: 16,
          fontWeight: FontWeight.w600,
          color: Colors.white,
        ),
      ),
    );
  }

  Widget _buildVoiceOverlay() {
    return ValueListenableBuilder<bool>(
      valueListenable: _voiceAssistant.isListening,
      builder: (context, isListening, _) {
        return ValueListenableBuilder<String>(
          valueListenable: _voiceAssistant.liveTranscript,
          builder: (context, transcript, __) {
            return ValueListenableBuilder<String?>(
              valueListenable: _voiceAssistant.lastError,
              builder: (context, error, ___) {
                if (!isListening && transcript.isEmpty && (error == null || error.isEmpty)) {
                  return const SizedBox.shrink();
                }
                final displayText = transcript.isEmpty
                    ? (isListening ? 'Listening...' : 'Voice ready')
                    : transcript;
                return Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.75),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          AnimatedBuilder(
                            animation: _micPulseAnimation,
                            builder: (context, child) {
                              final scale = isListening ? _micPulseAnimation.value : 1.0;
                              return Transform.scale(scale: scale, child: child);
                            },
                            child: const Icon(Icons.mic, color: Colors.white, size: 28),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              displayText,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: GoogleFonts.outfit(
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                                color: Colors.white,
                              ),
                            ),
                          ),
                        ],
                      ),
                      if (error != null && error.isNotEmpty && !isListening) ...[
                        const SizedBox(height: 6),
                        Text(
                          error,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: GoogleFonts.outfit(
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                            color: const Color(0xFFFFC8C8),
                          ),
                        ),
                      ],
                    ],
                  ),
                );
              },
            );
          },
        );
      },
    );
  }

  Widget _buildTopRightSettings() {
    return Positioned(
      top: 16,
      right: 16,
      child: IconButton(
        icon: const Icon(Icons.settings, size: 32),
        color: _currentState == HomeState.scanning ? Colors.white : const Color(0xFF1A1A1A),
        tooltip: 'Settings',
        onPressed: _showSettingsBottomSheet,
        constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
      ),
    );
  }

  Widget _buildBottomRightSOS() {
    return Positioned(
      bottom: 24,
      right: 24,
      child: InkWell(
        onTap: () {
          // Trigger SOS action
        },
        borderRadius: BorderRadius.circular(32),
        child: Container(
          width: 64,
          height: 64,
          decoration: const BoxDecoration(
            color: Color(0xFFCC0000),
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(color: Colors.black26, blurRadius: 8, offset: Offset(0, 4)),
            ],
          ),
          child: const Center(
            child: Icon(Icons.emergency_rounded, color: Colors.white, size: 36),
          ),
        ),
      ),
    );
  }

  Future<void> _startOcrPipeline() async {
    setState(() {
      _cameraError = null;
      _currentState = HomeState.scanning;
      _latestOcrText = '';
    });

    final cameraPermission = await Permission.camera.request();
    if (!cameraPermission.isGranted) {
      final message = cameraPermission.isPermanentlyDenied
          ? 'Camera permission denied. Please enable it in Settings.'
          : 'Camera permission denied. Tap Grant Access to try again.';
      if (!mounted) return;
      setState(() {
        _cameraError = message;
        _currentState = HomeState.permission;
      });
      return;
    }

    final micPermission = await Permission.microphone.request();
    if (!micPermission.isGranted) {
      final message = micPermission.isPermanentlyDenied
          ? 'Microphone permission denied. Please enable it in Settings.'
          : 'Microphone permission denied. Tap Grant Access to try again.';
      if (!mounted) return;
      setState(() {
        _cameraError = message;
        _currentState = HomeState.permission;
      });
      return;
    }

    if (Platform.isIOS) {
      final speechPermission = await Permission.speech.request();
      if (!speechPermission.isGranted) {
        final message = speechPermission.isPermanentlyDenied
            ? 'Speech recognition permission denied. Please enable it in Settings.'
            : 'Speech recognition permission denied. Tap Grant Access to try again.';
        if (!mounted) return;
        setState(() {
          _cameraError = message;
          _currentState = HomeState.permission;
        });
        return;
      }
    }

    await _initializeCamera();
  }

  Future<void> _initializeCamera() async {
    if (_isInitializingCamera) return;
    _isInitializingCamera = true;
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        throw Exception('No cameras available on this device.');
      }
      final selectedCamera = cameras.firstWhere(
        (camera) => camera.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );
      final controller = CameraController(
        selectedCamera,
        ResolutionPreset.medium,
        enableAudio: false,
        imageFormatGroup: Platform.isIOS ? ImageFormatGroup.bgra8888 : ImageFormatGroup.yuv420,
      );
      _cameraController = controller;
      await controller.initialize();
      if (!mounted) return;
      setState(() {
        _cameraReady = true;
        _cameraError = null;
      });
      if (!_isStreaming) {
        _isStreaming = true;
        await controller.startImageStream(_processCameraImage);
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _cameraReady = false;
        _cameraError = 'Unable to start camera. ${error.toString()}';
      });
    } finally {
      _isInitializingCamera = false;
    }
  }

  void _stopCamera() {
    final controller = _cameraController;
    _cameraController = null;
    _cameraReady = false;
    _isStreaming = false;
    if (controller == null) return;
    unawaited(controller.stopImageStream().catchError((_) {}));
    unawaited(controller.dispose().catchError((_) {}));
  }

  Future<void> _processCameraImage(CameraImage image) async {
    if (_isProcessingFrame) return;
    final now = DateTime.now();
    if (now.difference(_lastAnalysisTime) < _analysisInterval) return;
    _isProcessingFrame = true;
    _lastAnalysisTime = now;
    try {
      final inputImage = _inputImageFromCameraImage(image);
      if (inputImage == null) return;
      final results = await Future.wait([
        _latinTextRecognizer.processImage(inputImage),
        _devanagariTextRecognizer.processImage(inputImage),
        _tamilTextRecognizer.processImage(inputImage),
      ]);
      final mergedText = _mergeRecognizedText(results);
      _maybeEmitText(mergedText);
    } catch (error) {
      debugPrint('OCR error: $error');
    } finally {
      _isProcessingFrame = false;
    }
  }

  InputImage? _inputImageFromCameraImage(CameraImage image) {
    final controller = _cameraController;
    if (controller == null) return null;
    final rotation = _rotationForImage(controller.description, controller.value.deviceOrientation);
    final format = InputImageFormatValue.fromRawValue(image.format.raw);
    if (format == null) return null;
    if (Platform.isAndroid && format != InputImageFormat.yuv420) return null;
    if (Platform.isIOS && format != InputImageFormat.bgra8888) return null;

    final bytes = _concatenatePlanes(image.planes);
    final size = Size(image.width.toDouble(), image.height.toDouble());
    final metadata = InputImageMetadata(
      size: size,
      rotation: rotation,
      format: format,
      bytesPerRow: image.planes.first.bytesPerRow,
    );
    return InputImage.fromBytes(bytes: bytes, metadata: metadata);
  }

  InputImageRotation _rotationForImage(
    CameraDescription description,
    DeviceOrientation deviceOrientation,
  ) {
    final rotation = _deviceRotation[deviceOrientation] ?? 0;
    int rotationCompensation;
    if (Platform.isIOS) {
      rotationCompensation = rotation;
    } else {
      if (description.lensDirection == CameraLensDirection.front) {
        rotationCompensation = (description.sensorOrientation + rotation) % 360;
      } else {
        rotationCompensation = (description.sensorOrientation - rotation + 360) % 360;
      }
    }
    return InputImageRotationValue.fromRawValue(rotationCompensation) ??
        InputImageRotation.rotation0deg;
  }

  Uint8List _concatenatePlanes(List<Plane> planes) {
    final buffer = WriteBuffer();
    for (final plane in planes) {
      buffer.putUint8List(plane.bytes);
    }
    return buffer.done().buffer.asUint8List();
  }

  String _mergeRecognizedText(List<RecognizedText> results) {
    final seen = <String>{};
    final merged = <String>[];
    for (final result in results) {
      final text = result.text.trim();
      if (text.isEmpty) continue;
      final normalized = _normalizeText(text);
      if (seen.add(normalized)) {
        merged.add(text);
      }
    }
    return merged.join('\n').trim();
  }

  void _maybeEmitText(String text) {
    final cleaned = text.trim();
    if (cleaned.isEmpty) return;
    final normalized = _normalizeText(cleaned);
    if (normalized.length < 3) return;

    final now = DateTime.now();
    if (normalized == _lastEmittedText && now.difference(_lastEmitTime) < _emitCooldown) {
      return;
    }

    if (_lastEmittedText.isNotEmpty) {
      final similarity = _jaccardSimilarity(normalized, _lastEmittedText);
      if (similarity >= 0.9 && now.difference(_lastEmitTime) < const Duration(seconds: 4)) {
        return;
      }
    }

    _lastEmittedText = normalized;
    _lastEmitTime = now;
    if (mounted) {
      setState(() => _latestOcrText = cleaned);
    }
    debugPrint('OCR: $cleaned');
    if (_soundEnabled) {
      unawaited(
        _voiceAssistant.onSignboardDetected(
          cleaned,
          onUserResponse: _handleUserResponse,
        ),
      );
    }
  }

  TextRecognitionScript _scriptByName(String name) {
    for (final script in TextRecognitionScript.values) {
      if (script.name == name) {
        return script;
      }
    }
    return TextRecognitionScript.latin;
  }

  String _normalizeText(String text) {
    return text.toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  double _jaccardSimilarity(String a, String b) {
    final aTokens = a.split(' ').where((token) => token.isNotEmpty).toSet();
    final bTokens = b.split(' ').where((token) => token.isNotEmpty).toSet();
    if (aTokens.isEmpty || bTokens.isEmpty) return 0;
    final intersection = aTokens.intersection(bTokens).length;
    final union = aTokens.union(bTokens).length;
    return union == 0 ? 0 : intersection / union;
  }

  Future<void> _handleUserResponse(String text) async {
    if (!_soundEnabled) return;
    final normalized = text.toLowerCase();
    if (normalized.contains('yes') ||
        normalized.contains('haan') ||
        normalized.contains('help') ||
        normalized.contains('haanji')) {
      await _voiceAssistant.speak(
        'Okay. Tell me what you need, and I will help you.',
      );
      return;
    }
    if (normalized.contains('no') || normalized.contains('nah') || normalized.contains('nahi')) {
      await _voiceAssistant.speak(
        'Alright. I am here if you need anything else.',
      );
      return;
    }
    await _voiceAssistant.speak(
      'Thanks. I heard: $text. I will try to assist.',
    );
  }

  void _showSettingsBottomSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (bottomSheetContext) {
        return StatefulBuilder(
          builder: (BuildContext context, StateSetter setModalState) {
            return Padding(
              padding: EdgeInsets.only(
                bottom: MediaQuery.of(context).viewInsets.bottom,
                top: 24, left: 24, right: 24,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('Settings', style: GoogleFonts.outfit(fontSize: 28, fontWeight: FontWeight.bold, color: const Color(0xFF1A1A1A))),
                      IconButton(
                        icon: const Icon(Icons.close, size: 32, color: Color(0xFF1A1A1A)),
                        onPressed: () => Navigator.pop(context),
                        constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),
                  // Language Selector
                  Text('Language', style: GoogleFonts.outfit(fontSize: 18, fontWeight: FontWeight.w600, color: const Color(0xFF1A1A1A))),
                  const SizedBox(height: 8),
                  DropdownButtonFormField<String>(
                    value: _selectedLanguage,
                    items: ['English', 'Hindi'].map((lang) {
                      return DropdownMenuItem(value: lang, child: Text(lang, style: const TextStyle(fontSize: 18)));
                    }).toList(),
                    onChanged: (val) {
                      if (val == null) return;
                      setModalState(() => _selectedLanguage = val);
                      setState(() => _selectedLanguage = val);
                      final localeId = _selectedLanguage == 'Hindi' ? 'hi_IN' : 'en_IN';
                      unawaited(_voiceAssistant.setLocale(localeId));
                    },
                  ),
                  const SizedBox(height: 24),
                  // Emergency Contact
                  Text('Emergency Contact', style: GoogleFonts.outfit(fontSize: 18, fontWeight: FontWeight.w600, color: const Color(0xFF1A1A1A))),
                  const SizedBox(height: 8),
                  TextFormField(
                    decoration: const InputDecoration(labelText: 'Name', hintText: 'e.g. John Doe'),
                    style: const TextStyle(fontSize: 18, color: Color(0xFF1A1A1A)),
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    decoration: const InputDecoration(labelText: 'Phone Number', hintText: 'e.g. +1234567890'),
                    keyboardType: TextInputType.phone,
                    style: const TextStyle(fontSize: 18, color: Color(0xFF1A1A1A)),
                  ),
                  const SizedBox(height: 24),
                  // Sound Toggle
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text('Audio Feedback', style: GoogleFonts.outfit(fontSize: 18, fontWeight: FontWeight.w600, color: const Color(0xFF1A1A1A))),
                    value: _soundEnabled,
                    onChanged: (val) {
                      setModalState(() => _soundEnabled = val);
                      setState(() => _soundEnabled = val); // Update parent too
                      if (!val) {
                        unawaited(_voiceAssistant.stop());
                      }
                    },
                    activeColor: const Color(0xFF1A56DB),
                  ),
                  const SizedBox(height: 32),
                ],
              ),
            );
          },
        );
      },
    );
  }
}
