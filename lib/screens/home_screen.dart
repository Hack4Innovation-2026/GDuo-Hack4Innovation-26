import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:image/image.dart' as img;
import 'package:permission_handler/permission_handler.dart';

import '../config/config.dart';
import '../services/voice_assistant_service.dart';
import '../services/gemini_service.dart';
import '../services/yolo_detector_service.dart';

enum HomeState { idle, permission, scanning }

class _OcrLine {
  const _OcrLine(this.text, this.rect);

  final String text;
  final Rect rect;
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  HomeState _currentState = HomeState.permission;
  bool _soundEnabled = true;
  String _selectedLanguage = 'English';

  CameraController? _cameraController;
  bool _cameraReady = false;
  bool _isInitializingCamera = false;
  bool _isStreaming = false;
  String? _cameraError;

  late final VoiceAssistantService _voiceAssistant;
  late final GeminiService _geminiService;
  late final AnimationController _micPulseController;
  late final Animation<double> _micPulseAnimation;
  late final VoidCallback _micListeningListener;

  late final TextRecognizer _latinTextRecognizer;
  late final TextRecognizer _devanagariTextRecognizer;
  late final TextRecognizer _tamilTextRecognizer;
  late final YoloDetectorService _yoloDetector;
  late final YoloDetectorService _indoorDetector;

  bool _isProcessingFrame = false;
  bool _yoloReady = false;
  bool _yoloInFlight = false;
  String? _yoloError;
  List<YoloDetection> _latestDetections = [];
  bool _indoorReady = false;
  bool _indoorInFlight = false;
  String? _indoorError;
  List<YoloDetection> _latestIndoorDetections = [];
  DateTime _lastAnalysisTime = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastYoloTime = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastIndoorTime = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastEmitTime = DateTime.fromMillisecondsSinceEpoch(0);
  String _lastEmittedText = '';
  String _latestOcrText = '';
  String _latestSmartText = '';
  String? _latestGeminiError;
  DateTime _lastSpokenTime = DateTime.fromMillisecondsSinceEpoch(0);
  String _lastSpokenText = '';
  DateTime _lastGeminiCall = DateTime.fromMillisecondsSinceEpoch(0);
  String _lastGeminiText = '';
  bool _geminiInFlight = false;
  bool _latestSmartEmpty = false;
  bool _isCapturing = false;
  bool _conversationModeEnabled = false;
  bool _conversationInFlight = false;
  String? _pendingConversationQuestion;
  bool _intentModeEnabled = false;
  bool _intentInFlight = false;
  String? _pendingIntentQuery;
  String? _activeIntentQuery;
  DateTime _lastIntentCall = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastIntentSpokenTime = DateTime.fromMillisecondsSinceEpoch(0);
  String _lastIntentKey = '';
  DateTime _lastCaptureTime = DateTime.fromMillisecondsSinceEpoch(0);
  Rect? _lastFocusRect;
  DateTime _focusStableSince = DateTime.fromMillisecondsSinceEpoch(0);
  bool _detectedAnnounced = false;
  DateTime _lastGuidanceTime = DateTime.fromMillisecondsSinceEpoch(0);
  String _lastGuidanceText = '';
  String _currentGuidanceText = '';
  bool _holdAnnounced = false;
  Size? _lastFrameSize;
  DateTime _lastAlertSpokenAt = DateTime.fromMillisecondsSinceEpoch(0);
  String _lastAlertKey = '';

  static const Duration _analysisInterval = Duration(milliseconds: 650);
  static const Duration _emitCooldown = Duration(milliseconds: 1500);
  static const Duration _speechCooldown = Duration(seconds: 4);
  static const Duration _alertSpeakCooldown = Duration(seconds: 4);
  static const Duration _geminiCooldown = Duration(seconds: 6);
  static const Duration _captureHoldDuration = Duration(milliseconds: 1100);
  static const Duration _captureCooldown = Duration(seconds: 5);
  static const Duration _guidanceCooldown = Duration(seconds: 2);
  static const double _centerTolerance = 0.10;
  static const Duration _yoloInterval = Duration(milliseconds: 900);
  static const Duration _conversationRearmDelay = Duration(milliseconds: 600);
  static const Duration _intentCooldown = Duration(seconds: 6);
  static const Duration _intentScanInterval = Duration(seconds: 2);
  static const Map<String, List<String>> _intentKeywordHints = {
    'medical': ['medical', 'pharmacy', 'chemist', 'drug', 'drugs', 'medicine', 'pharma'],
    'hospital': ['hospital', 'clinic', 'emergency', 'er', 'casualty'],
    'restaurant': ['restaurant', 'cafe', 'café', 'dhaba', 'eatery', 'food', 'tiffin', 'hotel'],
    'grocery': ['grocery', 'supermarket', 'mart', 'store', 'kirana', 'provisions'],
    'bank': ['bank', 'atm', 'cash', 'finance'],
    'hotel': ['hotel', 'lodge', 'inn', 'resort', 'guest house', 'guesthouse'],
    'school': ['school', 'academy', 'vidyalaya', 'college', 'university', 'institute'],
    'temple': ['temple', 'mandir'],
    'mosque': ['mosque', 'masjid'],
    'church': ['church', 'chapel'],
    'police': ['police', 'station', 'ps'],
    'fuel': ['fuel', 'petrol', 'diesel', 'gas', 'pump', 'filling'],
  };
  static const int _yoloFrameStride = 4;
  static const int _indoorFrameStride = 4;
  static const int _indoorFrameOffset = 2;
  int _frameIndex = 0;

  static const Set<String> _roadAlertLabels = {
    'car',
    'truck',
    'bus',
    'motorcycle',
    'bicycle',
    'person',
    'pothole',
    'speedbump',
    'bump',
    'barricade',
    'barrier',
    'construction',
    'cone',
    'pole',
    'electricpole',
    'powerpole',
    'streetlight',
    'stair',
    'stairs',
    'road',
    'rickshaw',
    'autorickshaw',
    'scooter',
  };

  static const Set<String> _indoorAlertLabels = {
    'door',
    'openeddoor',
    'cabinetdoor',
    'refrigeratordoor',
    'window',
    'pole',
    'stair',
    'stairs',
  };

  static const Map<String, String> _alertSpokenLabels = {
    'openeddoor': 'open door',
    'cabinetdoor': 'cabinet door',
    'refrigeratordoor': 'refrigerator door',
    'electricpole': 'electric pole',
    'powerpole': 'electric pole',
    'streetlight': 'street light',
    'autorickshaw': 'auto rickshaw',
    'rickshaw': 'rickshaw',
    'speedbump': 'speed bump',
  };

  static const Map<String, String> _alertGuidance = {
    'car': 'Keep left.',
    'truck': 'Keep left.',
    'bus': 'Keep left.',
    'motorcycle': 'Keep left.',
    'bicycle': 'Keep left.',
    'autorickshaw': 'Keep left.',
    'rickshaw': 'Keep left.',
    'scooter': 'Keep left.',
    'pothole': 'Watch your step.',
    'speedbump': 'Slow down.',
    'bump': 'Slow down.',
    'barricade': 'Change lane carefully.',
    'barrier': 'Change lane carefully.',
    'construction': 'Change lane carefully.',
    'cone': 'Change lane carefully.',
    'stair': 'Step carefully.',
    'stairs': 'Step carefully.',
    'door': 'Mind the doorway.',
    'openeddoor': 'Mind the doorway.',
    'cabinetdoor': 'Mind the doorway.',
    'refrigeratordoor': 'Mind the doorway.',
    'pole': 'Obstacle ahead.',
    'electricpole': 'Obstacle ahead.',
    'powerpole': 'Obstacle ahead.',
    'streetlight': 'Obstacle ahead.',
  };

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

    _voiceAssistant = VoiceAssistantService(enableSpeech: true);
    _geminiService = GeminiService();
    unawaited(_voiceAssistant.initialize(localeId: 'en_IN'));
    _yoloDetector = YoloDetectorService(
      modelAsset: YOLO_MODEL_ASSET,
      labelsAsset: COCO_LABELS_ASSET,
      inputSize: 640,
    );
    unawaited(_initializeYolo());
    _indoorDetector = YoloDetectorService(
      modelAsset: INDOOR_YOLO_MODEL_ASSET,
      labelsAsset: INDOOR_LABELS_ASSET,
      inputSize: 640,
    );
    unawaited(_initializeIndoorYolo());

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
    unawaited(_yoloDetector.dispose());
    unawaited(_indoorDetector.dispose());
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
            _buildDetectionOverlay(),
            _buildTopRightSettings(),
            _buildBottomRightIntent(),
            _buildBottomRightConversation(),
            _buildBottomRightSOS(),
          ],
        ),
      ),
    );
  }

  Widget _buildMainContent() {
    switch (_currentState) {
      case HomeState.idle:
        return _buildPermissionState();
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
                  'Camera Access',
                  style: GoogleFonts.outfit(fontSize: 24, fontWeight: FontWeight.bold, color: const Color(0xFF1A1A1A)),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 12),
                Text(
                  'DrishtiAI needs access to your camera to read signboards.',
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
              if (_currentGuidanceText.isNotEmpty) ...[
                _buildGuidanceOverlay(),
                const SizedBox(height: 12),
              ],
              _buildVoiceOverlay(),
              if (_latestGeminiError != null || _latestSmartText.isNotEmpty || _latestOcrText.isNotEmpty) ...[
                const SizedBox(height: 12),
                _buildSmartOverlay(),
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

  Widget _buildGuidanceOverlay() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.8),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: const Color(0xFFB3D4FF).withValues(alpha: 0.9),
          width: 1,
        ),
      ),
      child: Row(
        children: [
          const Icon(Icons.center_focus_strong, color: Color(0xFFB3D4FF), size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _currentGuidanceText,
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

  Widget _buildBottomRightConversation() {
    if (_currentState != HomeState.scanning) {
      return const SizedBox.shrink();
    }
    final isActive = _conversationModeEnabled;
    return Positioned(
      bottom: 104,
      right: 28,
      child: InkWell(
        onTap: _toggleConversationMode,
        borderRadius: BorderRadius.circular(24),
        child: Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            color: isActive ? const Color(0xFF1A56DB) : Colors.white,
            shape: BoxShape.circle,
            border: Border.all(
              color: isActive ? const Color(0xFF1A56DB) : const Color(0xFFB3D4FF),
              width: 2,
            ),
            boxShadow: const [
              BoxShadow(color: Colors.black26, blurRadius: 6, offset: Offset(0, 3)),
            ],
          ),
          child: Icon(
            isActive ? Icons.mark_chat_read_rounded : Icons.mark_chat_unread_rounded,
            color: isActive ? Colors.white : const Color(0xFF1A56DB),
            size: 26,
          ),
        ),
      ),
    );
  }

  Widget _buildBottomRightIntent() {
    if (_currentState != HomeState.scanning) {
      return const SizedBox.shrink();
    }
    final isActive = _intentModeEnabled;
    return Positioned(
      bottom: 160,
      right: 28,
      child: InkWell(
        onTap: () {
          if (_intentModeEnabled) {
            unawaited(_requestIntentQuery(initialPrompt: false));
          } else {
            unawaited(_toggleIntentMode());
          }
        },
        onLongPress: () {
          if (_intentModeEnabled) {
            unawaited(_toggleIntentMode());
          }
        },
        borderRadius: BorderRadius.circular(24),
        child: Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            color: isActive ? const Color(0xFF2F9E44) : Colors.white,
            shape: BoxShape.circle,
            border: Border.all(
              color: isActive ? const Color(0xFF2F9E44) : const Color(0xFFB3D4FF),
              width: 2,
            ),
            boxShadow: const [
              BoxShadow(color: Colors.black26, blurRadius: 6, offset: Offset(0, 3)),
            ],
          ),
          child: Icon(
            isActive ? Icons.search_rounded : Icons.search_outlined,
            color: isActive ? Colors.white : const Color(0xFF1A56DB),
            size: 26,
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

    await _initializeCamera();
  }

  Future<void> _initializeCamera() async {
    if (_isInitializingCamera) return;
    _isInitializingCamera = true;
    try {
      final existingController = _cameraController;
      if (existingController != null) {
        if (existingController.value.isInitialized) {
          return;
        }
        await _disposeController(existingController);
        _cameraController = null;
      }
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        throw Exception('No cameras available on this device.');
      }
      final selectedCamera = cameras.firstWhere(
        (camera) => camera.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );
      CameraController controller;
      try {
        controller = CameraController(
          selectedCamera,
          ResolutionPreset.high,
          enableAudio: false,
          imageFormatGroup: Platform.isIOS ? ImageFormatGroup.bgra8888 : ImageFormatGroup.yuv420,
        );
        await controller.initialize();
      } catch (_) {
        controller = CameraController(
          selectedCamera,
          ResolutionPreset.medium,
          enableAudio: false,
          imageFormatGroup: Platform.isIOS ? ImageFormatGroup.bgra8888 : ImageFormatGroup.yuv420,
        );
        await controller.initialize();
      }
      _cameraController = controller;
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

  Future<void> _initializeYolo() async {
    if (kIsWeb) {
      if (mounted) {
        setState(() {
          _yoloError = 'On-device detection is not available on web.';
        });
      }
      return;
    }
    try {
      await _yoloDetector.initialize();
      if (!mounted) return;
      setState(() {
        _yoloReady = true;
        _yoloError = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _yoloReady = false;
        _yoloError = 'Detector init failed: ${error.toString()}';
      });
    }
  }

  Future<void> _initializeIndoorYolo() async {
    if (kIsWeb) {
      if (mounted) {
        setState(() {
          _indoorError = 'On-device detection is not available on web.';
        });
      }
      return;
    }
    try {
      await _indoorDetector.initialize();
      if (!mounted) return;
      setState(() {
        _indoorReady = true;
        _indoorError = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _indoorReady = false;
        _indoorError = 'Indoor detector init failed: ${error.toString()}';
      });
    }
  }

  void _stopCamera() {
    final controller = _cameraController;
    if (controller == null) return;
    if (mounted) {
      setState(() {
        _cameraController = null;
        _cameraReady = false;
        _isStreaming = false;
        _isCapturing = false;
        _latestOcrText = '';
        _latestSmartText = '';
        _latestSmartEmpty = false;
        _latestGeminiError = null;
        _lastFocusRect = null;
        _focusStableSince = DateTime.fromMillisecondsSinceEpoch(0);
        _detectedAnnounced = false;
        _lastGuidanceTime = DateTime.fromMillisecondsSinceEpoch(0);
        _lastGuidanceText = '';
        _currentGuidanceText = '';
        _holdAnnounced = false;
        _conversationModeEnabled = false;
        _conversationInFlight = false;
        _pendingConversationQuestion = null;
        _intentModeEnabled = false;
        _intentInFlight = false;
        _pendingIntentQuery = null;
        _activeIntentQuery = null;
        _lastIntentCall = DateTime.fromMillisecondsSinceEpoch(0);
        _lastIntentSpokenTime = DateTime.fromMillisecondsSinceEpoch(0);
        _lastIntentKey = '';
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        unawaited(_disposeController(controller));
      });
      return;
    }
    _cameraController = null;
    _cameraReady = false;
    _isStreaming = false;
    unawaited(_disposeController(controller));
  }

  Future<void> _toggleConversationMode() async {
    final enable = !_conversationModeEnabled;
    if (mounted) {
      setState(() {
        _conversationModeEnabled = enable;
        if (enable) {
          _intentModeEnabled = false;
          _intentInFlight = false;
          _pendingIntentQuery = null;
          _activeIntentQuery = null;
        }
      });
    }
    if (!enable) {
      _pendingConversationQuestion = null;
      _conversationInFlight = false;
      await _voiceAssistant.stop();
      return;
    }
    if (_intentModeEnabled) {
      _intentModeEnabled = false;
      _activeIntentQuery = null;
    }
    await _requestConversationQuestion(initialPrompt: true);
  }

  Future<void> _toggleIntentMode() async {
    final enable = !_intentModeEnabled;
    if (mounted) {
      setState(() {
        _intentModeEnabled = enable;
        if (enable) {
          _conversationModeEnabled = false;
          _conversationInFlight = false;
          _pendingConversationQuestion = null;
        }
      });
    }
    if (!enable) {
      _pendingIntentQuery = null;
      _activeIntentQuery = null;
      _intentInFlight = false;
      await _voiceAssistant.stop();
      return;
    }
    if (_conversationModeEnabled) {
      _conversationModeEnabled = false;
    }
    await _requestIntentQuery(initialPrompt: true);
  }

  Future<void> _requestConversationQuestion({required bool initialPrompt}) async {
    if (!_cameraReady) {
      if (_soundEnabled) {
        await _voiceAssistant.speak('Camera is not ready yet.');
      }
      return;
    }
    final prompt = initialPrompt
        ? 'Conversation mode on. Ask your question.'
        : 'Ask another question.';
    await _voiceAssistant.requestUserQuery(
      prompt: _soundEnabled ? prompt : null,
      onUserResponse: (text) async {
        final trimmed = text.trim();
        if (trimmed.isEmpty) return;
        _pendingConversationQuestion = trimmed;
      },
    );
  }

  Future<void> _requestIntentQuery({required bool initialPrompt}) async {
    if (!_cameraReady) {
      if (_soundEnabled) {
        await _voiceAssistant.speak('Camera is not ready yet.');
      }
      return;
    }
    final prompt = initialPrompt
        ? 'Intent search on. What are you looking for?'
        : 'What should I look for?';
    await _voiceAssistant.requestUserQuery(
      prompt: _soundEnabled ? prompt : null,
      onUserResponse: (text) async {
        final trimmed = text.trim();
        if (trimmed.isEmpty) return;
        _pendingIntentQuery = trimmed;
        _activeIntentQuery = trimmed;
      },
    );
  }

  Widget _buildSmartOverlay() {
    final hasError = _latestGeminiError != null && _latestGeminiError!.isNotEmpty;
    final hasSmart = _latestSmartText.isNotEmpty;

    String title;
    String body;
    Color accentColor;

    if (hasError) {
      title = 'Smart reading unavailable';
      body = _latestGeminiError!;
      accentColor = const Color(0xFFFFA3A3);
    } else if (hasSmart) {
      title = 'Smart reading';
      body = _latestSmartText;
      accentColor = const Color(0xFFB6F3C2);
    } else if (_latestSmartEmpty) {
      title = 'No useful text found yet';
      body = 'Try moving closer or centering the signboard.';
      accentColor = const Color(0xFFFFE4A3);
    } else {
      title = 'Analyzing signboard...';
      body = _latestOcrText.isNotEmpty
          ? _truncateText(_latestOcrText, maxChars: 140)
          : 'Point your camera at a signboard.';
      accentColor = const Color(0xFFB3D4FF);
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.75),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: accentColor.withValues(alpha: 0.9), width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(
                hasError ? Icons.error_outline : Icons.auto_awesome,
                color: accentColor,
                size: 20,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  style: GoogleFonts.outfit(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: accentColor,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            body,
            maxLines: 4,
            overflow: TextOverflow.ellipsis,
            style: GoogleFonts.outfit(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: Colors.white,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDetectionCard({
    required String title,
    required String body,
    required Color accentColor,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.75),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: accentColor.withValues(alpha: 0.9), width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            title,
            style: GoogleFonts.outfit(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: accentColor,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            body,
            style: GoogleFonts.outfit(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: Colors.white,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDetectionOverlay() {
    if (_currentState != HomeState.scanning) {
      return const SizedBox.shrink();
    }
    final roadAlerts = _filterAlertDetections(_latestDetections, _roadAlertLabels);
    final indoorAlerts =
        _filterAlertDetections(_latestIndoorDetections, _indoorAlertLabels);
    String roadTitle;
    String roadBody;
    Color roadAccentColor;

    if (_yoloError != null) {
      roadTitle = 'Object detection unavailable';
      roadBody = _yoloError!;
      roadAccentColor = const Color(0xFFFFA3A3);
    } else if (!_yoloReady) {
      roadTitle = 'Loading detector...';
      roadBody = 'Preparing road model.';
      roadAccentColor = const Color(0xFFB3D4FF);
    } else if (roadAlerts.isEmpty) {
      roadTitle = 'No road alerts';
      roadBody = 'No nearby hazards detected.';
      roadAccentColor = const Color(0xFFFFE4A3);
    } else {
      final top = roadAlerts.first;
      final distanceText = top.distanceMeters == null
          ? ''
          : ' • ${top.distanceMeters!.toStringAsFixed(1)}m';
      roadTitle = 'Road alert';
      roadBody =
          '${top.label} • ${top.proximity}$distanceText • ${(top.score * 100).toStringAsFixed(1)}%';
      roadAccentColor = const Color(0xFFB6F3C2);
    }

    String indoorTitle;
    String indoorBody;
    Color indoorAccentColor;

    if (_indoorError != null) {
      indoorTitle = 'Indoor detection unavailable';
      indoorBody = _indoorError!;
      indoorAccentColor = const Color(0xFFFFA3A3);
    } else if (!_indoorReady) {
      indoorTitle = 'Loading indoor detector...';
      indoorBody = 'Preparing indoor model.';
      indoorAccentColor = const Color(0xFFB3D4FF);
    } else if (indoorAlerts.isEmpty) {
      indoorTitle = 'No indoor alerts';
      indoorBody = 'No nearby hazards detected.';
      indoorAccentColor = const Color(0xFFFFE4A3);
    } else {
      final top = indoorAlerts.first;
      final distanceText = top.distanceMeters == null
          ? ''
          : ' • ${top.distanceMeters!.toStringAsFixed(1)}m';
      indoorTitle = 'Indoor alert';
      indoorBody =
          '${top.label} • ${top.proximity}$distanceText • ${(top.score * 100).toStringAsFixed(1)}%';
      indoorAccentColor = const Color(0xFFB6F3C2);
    }

    return Positioned(
      left: 16,
      top: 16,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildDetectionCard(
            title: roadTitle,
            body: roadBody,
            accentColor: roadAccentColor,
          ),
          const SizedBox(height: 8),
          _buildDetectionCard(
            title: indoorTitle,
            body: indoorBody,
            accentColor: indoorAccentColor,
          ),
        ],
      ),
    );
  }

  List<YoloDetection> _filterAlertDetections(
    List<YoloDetection> detections,
    Set<String> allowedLabels,
  ) {
    if (detections.isEmpty) return const [];
    final alerts = detections.where((d) {
      final normalized = _normalizeLabelForAlert(d.label);
      if (!allowedLabels.contains(normalized)) return false;
      if (d.distanceMeters != null) {
        return d.distanceMeters! <= 10.0;
      }
      return d.proximity != 'far';
    }).toList();
    alerts.sort((a, b) {
      final da = a.distanceMeters;
      final db = b.distanceMeters;
      if (da != null && db != null) {
        return da.compareTo(db);
      }
      if (da != null) return -1;
      if (db != null) return 1;
      return b.score.compareTo(a.score);
    });
    return alerts;
  }

  String _normalizeLabelForAlert(String label) {
    final lowered = label.trim().toLowerCase();
    return lowered.replaceAll(RegExp(r'[^a-z0-9]+'), '');
  }

  int _urgencyRank(YoloDetection detection) {
    final distance = detection.distanceMeters;
    if (distance != null) {
      if (distance <= 3.0) return 0;
      if (distance <= 6.0) return 1;
      if (distance <= 10.0) return 2;
      return 3;
    }
    switch (detection.proximity) {
      case 'urgent':
        return 0;
      case 'near':
        return 1;
      case 'mid':
        return 2;
      default:
        return 3;
    }
  }

  YoloDetection? _pickMostUrgentAlert(
    List<YoloDetection> roadAlerts,
    List<YoloDetection> indoorAlerts,
  ) {
    final combined = <YoloDetection>[
      ...roadAlerts,
      ...indoorAlerts,
    ];
    if (combined.isEmpty) return null;
    combined.sort((a, b) {
      final rankDiff = _urgencyRank(a).compareTo(_urgencyRank(b));
      if (rankDiff != 0) return rankDiff;
      final da = a.distanceMeters;
      final db = b.distanceMeters;
      if (da != null && db != null && da != db) {
        return da.compareTo(db);
      }
      return b.score.compareTo(a.score);
    });
    return combined.first;
  }

  String _directionForRect(Rect rect) {
    final frame = _lastFrameSize;
    if (frame == null || frame.width <= 0) return 'ahead';
    final centerX = rect.center.dx / frame.width;
    if (centerX < 0.35) return 'left';
    if (centerX > 0.65) return 'right';
    return 'ahead';
  }

  String _distanceDescriptor(YoloDetection detection) {
    final distance = detection.distanceMeters;
    if (distance != null) {
      if (distance <= 3.0) return 'very close';
      if (distance <= 6.0) return 'nearby';
      if (distance <= 10.0) return 'ahead';
      return 'far';
    }
    switch (detection.proximity) {
      case 'urgent':
        return 'very close';
      case 'near':
        return 'nearby';
      case 'mid':
        return 'ahead';
      default:
        return 'far';
    }
  }

  String _humanizeLabel(String label) {
    final withSpaces = label
        .replaceAll(RegExp(r'[_/]+'), ' ')
        .replaceAllMapped(RegExp(r'([a-z])([A-Z])'), (m) => '${m[1]} ${m[2]}');
    return withSpaces.trim().toLowerCase();
  }

  String _capitalize(String text) {
    if (text.isEmpty) return text;
    return text[0].toUpperCase() + text.substring(1);
  }

  String _buildAlertMessage(YoloDetection detection) {
    final normalized = _normalizeLabelForAlert(detection.label);
    final spokenLabel = _alertSpokenLabels[normalized] ?? _humanizeLabel(detection.label);
    final direction = _directionForRect(detection.rect);
    var distanceWord = _distanceDescriptor(detection);
    if (direction != 'ahead' && distanceWord == 'ahead') {
      distanceWord = 'nearby';
    }
    final directionPhrase = direction == 'ahead' ? 'ahead' : 'on your $direction';
    final guidance = _alertGuidance[normalized];
    final base = '${_capitalize(spokenLabel)} $distanceWord $directionPhrase.';
    if (guidance == null) return base;
    return '$base $guidance';
  }

  String _alertKey(YoloDetection detection) {
    final normalized = _normalizeLabelForAlert(detection.label);
    final direction = _directionForRect(detection.rect);
    return '$normalized:${detection.proximity}:$direction';
  }

  Future<void> _maybeSpeakAlerts() async {
    if (!_soundEnabled) return;
    if (_voiceAssistant.isListening.value || _voiceAssistant.isSpeaking.value) return;
    final now = DateTime.now();
    if (now.difference(_lastAlertSpokenAt) < _alertSpeakCooldown) return;

    final roadAlerts = _filterAlertDetections(_latestDetections, _roadAlertLabels);
    final indoorAlerts = _filterAlertDetections(_latestIndoorDetections, _indoorAlertLabels);
    final candidate = _pickMostUrgentAlert(roadAlerts, indoorAlerts);
    if (candidate == null) return;

    final message = _buildAlertMessage(candidate);
    if (message.trim().isEmpty) return;

    final key = _alertKey(candidate);
    if (key == _lastAlertKey && now.difference(_lastAlertSpokenAt) < const Duration(seconds: 8)) {
      return;
    }

    _lastAlertKey = key;
    _lastAlertSpokenAt = now;
    await _voiceAssistant.speak(message);
  }

  Future<void> _disposeController(CameraController controller) async {
    try {
      if (controller.value.isStreamingImages) {
        await controller.stopImageStream();
      }
    } catch (_) {}
    try {
      await controller.dispose();
    } catch (_) {}
  }

  Future<void> _processCameraImage(CameraImage image) async {
    if (_isProcessingFrame) return;
    if (!mounted || _currentState != HomeState.scanning) return;
    final now = DateTime.now();
    if (now.difference(_lastAnalysisTime) < _analysisInterval) return;
    _isProcessingFrame = true;
    _lastAnalysisTime = now;
    _lastFrameSize = Size(image.width.toDouble(), image.height.toDouble());
    _frameIndex++;
    try {
      final inputImage = _inputImageFromCameraImage(image);
      if (inputImage == null) return;
      final recognizers = _activeRecognizers();
      if (recognizers.isEmpty) return;
      final results = await Future.wait(
        recognizers.map((recognizer) => recognizer.processImage(inputImage)),
      );
      final mergedRect = _mergeBoundingBoxes(results);
      final mergedText = _mergeRecognizedText(
        results,
        focusRect: mergedRect,
        imageSize: _lastFrameSize,
      );
      if (_pendingConversationQuestion != null && !_conversationInFlight) {
        final question = _pendingConversationQuestion!;
        _pendingConversationQuestion = null;
        unawaited(_answerConversation(question, mergedText, image));
      }
      if (_intentModeEnabled &&
          _activeIntentQuery != null &&
          !_intentInFlight &&
          !_conversationInFlight &&
          _pendingConversationQuestion == null) {
        final query = _activeIntentQuery!;
        unawaited(_checkIntentMatch(query, mergedText, image, mergedRect));
      }
      _handleOcrResult(mergedText, image, mergedRect);

      final bool shouldRunRoad = _yoloReady &&
          !_yoloInFlight &&
          _frameIndex % _yoloFrameStride == 0 &&
          now.difference(_lastYoloTime) > _yoloInterval;
      final bool shouldRunIndoor = _indoorReady &&
          !_indoorInFlight &&
          _frameIndex % _indoorFrameStride == _indoorFrameOffset &&
          now.difference(_lastIndoorTime) > _yoloInterval;
      if (shouldRunRoad) {
        _yoloInFlight = true;
        _lastYoloTime = now;
      }
      if (shouldRunIndoor) {
        _indoorInFlight = true;
        _lastIndoorTime = now;
      }
      bool shouldSpeakAlerts = false;
      if (shouldRunRoad || shouldRunIndoor) {
        final rgbImage = _buildRgbImageForYolo(image);
        if (rgbImage != null) {
          if (shouldRunRoad) {
            final detections = await _yoloDetector.detect(rgbImage);
            if (mounted) {
              setState(() {
                _latestDetections = detections;
              });
            }
            shouldSpeakAlerts = true;
          }
          if (shouldRunIndoor) {
            final detections = await _indoorDetector.detect(
              rgbImage,
              confThreshold: 0.25,
            );
            if (mounted) {
              setState(() {
                _latestIndoorDetections = detections;
              });
            }
            shouldSpeakAlerts = true;
          }
        }
        if (shouldRunRoad) {
          _yoloInFlight = false;
        }
        if (shouldRunIndoor) {
          _indoorInFlight = false;
        }
        if (shouldSpeakAlerts) {
          unawaited(_maybeSpeakAlerts());
        }
      }
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
    final size = Size(image.width.toDouble(), image.height.toDouble());

    if (Platform.isAndroid) {
      final nv21 = _convertToNv21(image);
      final metadata = InputImageMetadata(
        size: size,
        rotation: rotation,
        format: InputImageFormat.nv21,
        bytesPerRow: image.width,
      );
      return InputImage.fromBytes(bytes: nv21, metadata: metadata);
    }

    final format = InputImageFormatValue.fromRawValue(image.format.raw);
    if (format == null) {
      debugPrint('Unsupported camera format: ${image.format.raw}');
      return null;
    }
    final bytes = _concatenatePlanes(image.planes);
    final metadata = InputImageMetadata(
      size: size,
      rotation: rotation,
      format: format,
      bytesPerRow: image.planes.first.bytesPerRow,
    );
    return InputImage.fromBytes(bytes: bytes, metadata: metadata);
  }

  Uint8List _convertToNv21(CameraImage image) {
    final width = image.width;
    final height = image.height;
    final yPlane = image.planes[0];
    final uPlane = image.planes[1];
    final vPlane = image.planes[2];

    final nv21 = Uint8List(width * height + (width * height ~/ 2));

    // Copy Y plane.
    int yIndex = 0;
    for (int row = 0; row < height; row++) {
      final int rowStart = row * yPlane.bytesPerRow;
      final int rowEnd = rowStart + width;
      if (rowEnd > yPlane.bytes.length) {
        break;
      }
      nv21.setRange(yIndex, yIndex + width, yPlane.bytes, rowStart);
      yIndex += width;
    }

    // Interleave V and U for NV21.
    int uvIndex = width * height;
    final int uvRowStride = uPlane.bytesPerRow;
    final int uvPixelStride = uPlane.bytesPerPixel ?? 1;
    for (int row = 0; row < height ~/ 2; row++) {
      final int uvRowStart = row * uvRowStride;
      for (int col = 0; col < width ~/ 2; col++) {
        final int uvOffset = uvRowStart + col * uvPixelStride;
        if (uvOffset >= uPlane.bytes.length || uvOffset >= vPlane.bytes.length) {
          continue;
        }
        nv21[uvIndex++] = vPlane.bytes[uvOffset];
        nv21[uvIndex++] = uPlane.bytes[uvOffset];
      }
    }

    return nv21;
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

  List<TextRecognizer> _activeRecognizers() {
    switch (_selectedLanguage) {
      case 'Hindi':
        return [_latinTextRecognizer, _devanagariTextRecognizer];
      case 'Tamil':
        return [_latinTextRecognizer, _tamilTextRecognizer];
      default:
        return [_latinTextRecognizer];
    }
  }

  String _mergeRecognizedText(
    List<RecognizedText> results, {
    Rect? focusRect,
    Size? imageSize,
  }) {
    final lines = <_OcrLine>[];
    for (final result in results) {
      for (final block in result.blocks) {
        if (block.lines.isEmpty) {
          final text = block.text.trim();
          if (text.isNotEmpty) {
            lines.add(_OcrLine(text, block.boundingBox));
          }
          continue;
        }
        for (final line in block.lines) {
          final text = line.text.trim();
          if (text.isNotEmpty) {
            lines.add(_OcrLine(text, line.boundingBox));
          }
        }
      }
    }

    if (lines.isEmpty) return '';

    final filtered = <_OcrLine>[];
    final seen = <String>{};

    final double? minHeight =
        imageSize == null ? null : imageSize.height * 0.012;
    final double? minWidth =
        imageSize == null ? null : imageSize.width * 0.06;
    final bool restrictToFocus = focusRect != null &&
        imageSize != null &&
        (focusRect.width * focusRect.height) /
                (imageSize.width * imageSize.height) >=
            0.02;

    for (final line in lines) {
      final text = line.text.trim();
      if (text.isEmpty) continue;
      if (_isNoiseLine(text)) continue;

      if (minHeight != null && minWidth != null) {
        if (line.rect.height < minHeight && line.rect.width < minWidth) {
          continue;
        }
      }

      if (restrictToFocus && focusRect != null) {
        final overlap = _rectIntersectionRatio(line.rect, focusRect);
        if (overlap < 0.35) {
          continue;
        }
      }

      final normalized = _normalizeText(text);
      if (normalized.isEmpty) continue;
      if (!seen.add(normalized)) continue;
      filtered.add(line);
    }

    if (filtered.isEmpty) return '';

    filtered.sort((a, b) {
      final dy = a.rect.top - b.rect.top;
      if (dy.abs() > (a.rect.height + b.rect.height) * 0.25) {
        return dy.sign.toInt();
      }
      return (a.rect.left - b.rect.left).sign.toInt();
    });

    return filtered.map((line) => line.text).join('\n').trim();
  }

  Rect? _mergeBoundingBoxes(List<RecognizedText> results) {
    Rect? merged;
    for (final result in results) {
      for (final block in result.blocks) {
        if (block.lines.isEmpty) {
          merged = _mergeRect(merged, block.boundingBox);
        } else {
          for (final line in block.lines) {
            merged = _mergeRect(merged, line.boundingBox);
          }
        }
      }
    }
    return merged;
  }

  bool _isCentered(Rect rect, Size frameSize) {
    if (frameSize.width <= 0 || frameSize.height <= 0) return false;
    final dx = rect.center.dx / frameSize.width - 0.5;
    final dy = rect.center.dy / frameSize.height - 0.5;
    return dx.abs() <= _centerTolerance && dy.abs() <= _centerTolerance;
  }

  String _directionGuidance(Rect rect, Size frameSize) {
    final dx = rect.center.dx / frameSize.width - 0.5;
    final dy = rect.center.dy / frameSize.height - 0.5;
    if (dx.abs() >= dy.abs()) {
      return dx < 0 ? 'Move left' : 'Move right';
    }
    return dy < 0 ? 'Move up' : 'Move down';
  }

  void _maybeProvideGuidance({
    required Rect? focusRect,
    required Size frameSize,
    required bool hasText,
    required double areaRatio,
    required bool isCentered,
    required bool isStable,
  }) {
    String message;
    if (focusRect == null || !hasText) {
      message = 'Point at a signboard.';
    } else if (areaRatio < 0.02) {
      message = 'Move closer to fill the signboard.';
    } else if (!isCentered) {
      message = _directionGuidance(focusRect, frameSize);
    } else if (!isStable) {
      message = 'Hold steady...';
    } else {
      message = 'Signboard detected.';
    }

    if (mounted) {
      setState(() {
        _currentGuidanceText = message;
      });
    }

    if (message != 'Hold steady...') {
      _holdAnnounced = false;
    }
    if (message != 'Signboard detected.') {
      _detectedAnnounced = false;
    }

    if (!_soundEnabled) return;
    if (message == 'Signboard detected.') return;
    if (_voiceAssistant.isListening.value || _voiceAssistant.isSpeaking.value) return;

    final now = DateTime.now();
    if (message == _lastGuidanceText && now.difference(_lastGuidanceTime) < _guidanceCooldown) {
      return;
    }
    if (message == 'Hold steady...' && _holdAnnounced) {
      return;
    }

    _lastGuidanceText = message;
    _lastGuidanceTime = now;
    if (message == 'Hold steady...') {
      _holdAnnounced = true;
    }
    unawaited(_voiceAssistant.speak(message));
  }

  bool _updateFocusStability(Rect rect) {
    final now = DateTime.now();
    final lastRect = _lastFocusRect;
    if (lastRect == null) {
      _lastFocusRect = rect;
      _focusStableSince = now;
      _holdAnnounced = false;
      return false;
    }
    final iou = _rectIoU(lastRect, rect);
    _lastFocusRect = rect;
    if (iou >= 0.65) {
      if (_focusStableSince.millisecondsSinceEpoch == 0) {
        _focusStableSince = now;
      }
    } else {
      _focusStableSince = now;
      _holdAnnounced = false;
    }
    return now.difference(_focusStableSince) >= _captureHoldDuration;
  }

  void _resetFocusStability() {
    _lastFocusRect = null;
    _focusStableSince = DateTime.fromMillisecondsSinceEpoch(0);
    _holdAnnounced = false;
    _detectedAnnounced = false;
  }

  double _rectIoU(Rect a, Rect b) {
    final left = a.left > b.left ? a.left : b.left;
    final top = a.top > b.top ? a.top : b.top;
    final right = a.right < b.right ? a.right : b.right;
    final bottom = a.bottom < b.bottom ? a.bottom : b.bottom;
    final overlapWidth = right - left;
    final overlapHeight = bottom - top;
    if (overlapWidth <= 0 || overlapHeight <= 0) return 0;
    final intersection = overlapWidth * overlapHeight;
    final union = a.width * a.height + b.width * b.height - intersection;
    return union <= 0 ? 0 : intersection / union;
  }

  Rect? _mergeRect(Rect? merged, Rect rect) {
    if (merged == null) return rect;
    final left = merged.left < rect.left ? merged.left : rect.left;
    final top = merged.top < rect.top ? merged.top : rect.top;
    final right = merged.right > rect.right ? merged.right : rect.right;
    final bottom = merged.bottom > rect.bottom ? merged.bottom : rect.bottom;
    return Rect.fromLTRB(left, top, right, bottom);
  }

  double _rectIntersectionRatio(Rect a, Rect b) {
    final left = a.left > b.left ? a.left : b.left;
    final top = a.top > b.top ? a.top : b.top;
    final right = a.right < b.right ? a.right : b.right;
    final bottom = a.bottom < b.bottom ? a.bottom : b.bottom;
    final overlapWidth = right - left;
    final overlapHeight = bottom - top;
    if (overlapWidth <= 0 || overlapHeight <= 0) return 0;
    final intersection = overlapWidth * overlapHeight;
    final area = a.width * a.height;
    if (area <= 0) return 0;
    return intersection / area;
  }

  Future<void> _announceAndCaptureFromFrame(
    CameraImage image,
    Rect focusRect,
    String text,
  ) async {
    if (_isCapturing) return;
    _isCapturing = true;
    _lastCaptureTime = DateTime.now();

    if (mounted) {
      setState(() {
        _currentGuidanceText = 'Signboard detected.';
      });
    }

    try {
      if (_soundEnabled &&
          !_detectedAnnounced &&
          !_voiceAssistant.isListening.value &&
          !_voiceAssistant.isSpeaking.value) {
        _detectedAnnounced = true;
        await _voiceAssistant.speak('Signboard detected.');
      }
      await _captureFromFrame(image, focusRect, text);
    } finally {
      _isCapturing = false;
    }
  }

  Future<void> _captureFromFrame(
    CameraImage image,
    Rect focusRect,
    String text,
  ) async {
    final filteredText = _filterOcrText(text);
    if (filteredText.isEmpty) {
      if (mounted) {
        setState(() {
          _latestSmartText = '';
          _latestSmartEmpty = true;
          _latestGeminiError = null;
        });
      }
      return;
    }

    final jpegBytes = _buildGeminiImage(image, cropRect: focusRect);
    if (jpegBytes == null) {
      if (mounted) {
        setState(() {
          _latestGeminiError = 'Unable to prepare camera image for Gemini.';
          _latestSmartText = '';
          _latestSmartEmpty = false;
        });
      }
      return;
    }

    await _maybeSendToGemini(filteredText, jpegBytes);
  }

  Future<void> _answerConversation(
    String question,
    String ocrText,
    CameraImage image,
  ) async {
    if (_conversationInFlight || _geminiInFlight) return;
    _conversationInFlight = true;
    _geminiInFlight = true;

    if (mounted) {
      setState(() {
        _latestSmartText = 'Thinking...';
        _latestSmartEmpty = false;
        _latestGeminiError = null;
      });
    }

    final cleaned = ocrText.trim();
    if (cleaned.isEmpty) {
      if (_soundEnabled) {
        await _voiceAssistant.speak('I cannot see any text to answer that.');
      }
      _conversationInFlight = false;
      _geminiInFlight = false;
      await _maybeContinueConversation();
      return;
    }

    final filteredText = _filterOcrTextForConversation(cleaned);
    final textForGemini = filteredText.isNotEmpty ? filteredText : cleaned;
    final jpegBytes = _buildGeminiImage(image);
    if (jpegBytes == null) {
      if (mounted) {
        setState(() {
          _latestGeminiError = 'Unable to prepare camera image for Gemini.';
          _latestSmartText = '';
          _latestSmartEmpty = false;
        });
      }
      _conversationInFlight = false;
      _geminiInFlight = false;
      await _maybeContinueConversation();
      return;
    }

    try {
      final result = await _geminiService.analyzeConversation(
        question: question,
        ocrText: textForGemini,
        jpegBytes: jpegBytes,
        preferredLanguage: _selectedLanguage,
      );
      if (result == null) {
        if (mounted) {
          setState(() {
            _latestGeminiError = 'No response from Gemini.';
            _latestSmartText = '';
            _latestSmartEmpty = false;
          });
        }
        _conversationInFlight = false;
        _geminiInFlight = false;
        await _maybeContinueConversation();
        return;
      }
      final speak = result.speak.trim();
      if (mounted) {
        setState(() {
          _latestSmartText = speak;
          _latestSmartEmpty = speak.isEmpty;
          _latestGeminiError = null;
        });
      }
      if (_soundEnabled && speak.isNotEmpty) {
        await _speakGeminiText(speak);
      } else if (_soundEnabled && speak.isEmpty) {
        await _voiceAssistant.speak('I cannot see that answer right now.');
      }
    } catch (error) {
      debugPrint('Conversation error: $error');
      if (mounted) {
        setState(() {
          _latestGeminiError = 'Gemini error: ${error.toString()}';
          _latestSmartText = '';
          _latestSmartEmpty = false;
        });
      }
    } finally {
      _conversationInFlight = false;
      _geminiInFlight = false;
    }

    await _maybeContinueConversation();
  }

  Future<void> _maybeContinueConversation() async {
    if (!_conversationModeEnabled) return;
    if (_voiceAssistant.isListening.value || _voiceAssistant.isSpeaking.value) return;
    await Future<void>.delayed(_conversationRearmDelay);
    if (!_conversationModeEnabled) return;
    await _requestConversationQuestion(initialPrompt: false);
  }

  Future<void> _checkIntentMatch(
    String intent,
    String ocrText,
    CameraImage image,
    Rect? focusRect,
  ) async {
    if (_intentInFlight || _geminiInFlight) return;
    final now = DateTime.now();
    if (now.difference(_lastIntentCall) < _intentScanInterval) return;
    _lastIntentCall = now;

    final cleaned = ocrText.trim();
    if (cleaned.isEmpty) return;

    final filteredText = _filterOcrTextForConversation(cleaned);
    final textForGemini = filteredText.isNotEmpty ? filteredText : cleaned;
    if (_matchesIntentWithOcr(intent, textForGemini)) {
      await _announceIntentMatch(_activeIntentQuery ?? intent, focusRect);
      return;
    }

    final jpegBytes = _buildGeminiImage(image, cropRect: focusRect);
    if (jpegBytes == null) return;

    _intentInFlight = true;
    _geminiInFlight = true;

    try {
      final result = await _geminiService.analyzeIntent(
        intent: intent,
        ocrText: textForGemini,
        jpegBytes: jpegBytes,
      );
      if (result == null || !result.match) {
        return;
      }
      await _announceIntentMatch(_activeIntentQuery ?? (result.category ?? intent), focusRect);
    } catch (error) {
      debugPrint('Intent error: $error');
    } finally {
      _intentInFlight = false;
      _geminiInFlight = false;
    }
  }

  Future<void> _announceIntentMatch(String intentName, Rect? focusRect) async {
    final now = DateTime.now();
    final direction = focusRect != null ? _directionForRect(focusRect) : 'ahead';
    var canonical = _canonicalIntentName(intentName).toUpperCase();
    if (!canonical.contains('STORE')) {
      canonical = '$canonical STORE';
    }
    final directionPhrase =
        direction == 'ahead' ? 'AHEAD' : 'ON YOUR ${direction.toUpperCase()}';
    final message = '$canonical DETECTED $directionPhrase';
    final key = '${_normalizeText(canonical)}:$direction';

    if (key == _lastIntentKey && now.difference(_lastIntentSpokenTime) < _intentCooldown) {
      return;
    }

    _lastIntentKey = key;
    _lastIntentSpokenTime = now;
    if (mounted) {
      setState(() {
        _latestSmartText = message;
        _latestSmartEmpty = false;
        _latestGeminiError = null;
      });
    }
    if (_soundEnabled && !_voiceAssistant.isListening.value && !_voiceAssistant.isSpeaking.value) {
      await _voiceAssistant.speak(message);
    }
  }

  void _handleOcrResult(String text, CameraImage image, Rect? focusRect) {
    if (_isCapturing) return;
    final cleaned = text.trim();
    final normalized = _normalizeText(cleaned);
    final now = DateTime.now();
    final frameSize = Size(image.width.toDouble(), image.height.toDouble());

    if (focusRect == null || normalized.isEmpty) {
      _resetFocusStability();
      _maybeProvideGuidance(
        focusRect: null,
        frameSize: frameSize,
        hasText: normalized.isNotEmpty,
        areaRatio: 0,
        isCentered: false,
        isStable: false,
      );
      if (normalized.isEmpty) {
        return;
      }
    }

    final areaRatio = focusRect == null
        ? 0.0
        : (focusRect.width * focusRect.height) /
            (frameSize.width * frameSize.height);
    final isCentered = focusRect != null && _isCentered(focusRect, frameSize);
    final isStable = focusRect != null && _updateFocusStability(focusRect);

    _maybeProvideGuidance(
      focusRect: focusRect,
      frameSize: frameSize,
      hasText: normalized.isNotEmpty,
      areaRatio: areaRatio,
      isCentered: isCentered,
      isStable: isStable,
    );

    final shouldUpdateText =
        !(normalized == _lastEmittedText && now.difference(_lastEmitTime) < _emitCooldown);
    if (shouldUpdateText && normalized.isNotEmpty) {
      _lastEmittedText = normalized;
      _lastEmitTime = now;
      if (mounted) {
        setState(() {
          _latestOcrText = cleaned;
          _latestSmartText = '';
          _latestSmartEmpty = false;
          _latestGeminiError = null;
        });
      }
      debugPrint('OCR: $cleaned');
    }

    if (focusRect != null &&
        normalized.isNotEmpty &&
        isCentered &&
        isStable &&
        areaRatio >= 0.03 &&
        now.difference(_lastCaptureTime) >= _captureCooldown &&
        !_conversationModeEnabled &&
        !_conversationInFlight &&
        _pendingConversationQuestion == null &&
        !_intentModeEnabled &&
        !_intentInFlight &&
        _pendingIntentQuery == null) {
      unawaited(_announceAndCaptureFromFrame(image, focusRect, cleaned));
    }
  }

  Future<void> _maybeSendToGemini(String text, Uint8List jpegBytes) async {
    if (_geminiInFlight) return;
    if (!_geminiService.hasApiKey) {
      debugPrint('GEMINI_API_KEY not set. Skipping Gemini.');
      if (mounted) {
        setState(() {
          _latestGeminiError =
              'Gemini API key missing. Run with --dart-define=GEMINI_API_KEY=YOUR_KEY';
          _latestSmartText = '';
          _latestSmartEmpty = false;
        });
      }
      return;
    }
    final now = DateTime.now();
    if (now.difference(_lastGeminiCall) < _geminiCooldown) return;

    final filteredNormalized = _normalizeText(text);
    if (_lastGeminiText.isNotEmpty &&
        _jaccardSimilarity(filteredNormalized, _lastGeminiText) >= 0.9) {
      return;
    }

    _geminiInFlight = true;
    _lastGeminiCall = now;
    _lastGeminiText = filteredNormalized;

    try {
      final result = await _geminiService.analyze(
        ocrText: text,
        jpegBytes: jpegBytes,
      );
      if (result == null) {
        if (mounted) {
          setState(() {
            _latestGeminiError = 'No response from Gemini.';
            _latestSmartText = '';
            _latestSmartEmpty = false;
          });
        }
        return;
      }
      if (result.action != null) {
        debugPrint('Gemini action: ${result.action!.type} -> ${result.action!.value}');
      }
      final speak = result.speak.trim();
      if (mounted) {
        setState(() {
          _latestSmartText = speak;
          _latestSmartEmpty = speak.isEmpty;
          _latestGeminiError = null;
        });
      }
      if (speak.isEmpty) return;
      debugPrint('Gemini speak: $speak');
      if (_soundEnabled) {
        await _speakGeminiText(speak);
      }
    } catch (error) {
      debugPrint('Gemini error: $error');
      if (mounted) {
        setState(() {
          _latestGeminiError = 'Gemini error: ${error.toString()}';
          _latestSmartText = '';
          _latestSmartEmpty = false;
        });
      }
    } finally {
      _geminiInFlight = false;
    }
  }

  Uint8List? _buildGeminiImage(CameraImage image, {Rect? cropRect}) {
    if (Platform.isIOS && image.format.group == ImageFormatGroup.bgra8888) {
      return _buildJpegFromBgra(image, cropRect: cropRect);
    }
    if (Platform.isAndroid) {
      return _buildJpegFromYuv420(image, cropRect: cropRect);
    }
    return null;
  }

  img.Image? _buildRgbImageForYolo(CameraImage image) {
    if (Platform.isIOS && image.format.group == ImageFormatGroup.bgra8888) {
      return _buildRgbFromBgra(image);
    }
    if (Platform.isAndroid) {
      return _buildRgbFromYuv420(image);
    }
    return null;
  }

  img.Image? _buildRgbFromBgra(CameraImage image) {
    if (image.planes.isEmpty) return null;
    final plane = image.planes.first;
    final bytes = plane.bytes;
    final width = image.width;
    final height = image.height;
    const downscale = 2;
    final outputWidth = (width / downscale).floor();
    final outputHeight = (height / downscale).floor();
    final img.Image rgbImage = img.Image(width: outputWidth, height: outputHeight);
    final int rowStride = plane.bytesPerRow;

    for (int y = 0, oy = 0; y < height; y += downscale, oy++) {
      final int rowStart = y * rowStride;
      for (int x = 0, ox = 0; x < width; x += downscale, ox++) {
        final int index = rowStart + (x * 4);
        if (index + 3 >= bytes.length) continue;
        final int b = bytes[index];
        final int g = bytes[index + 1];
        final int r = bytes[index + 2];
        rgbImage.setPixelRgba(ox, oy, r, g, b, 255);
      }
    }
    return rgbImage;
  }

  img.Image? _buildRgbFromYuv420(CameraImage image) {
    if (image.planes.length < 3) return null;
    final width = image.width;
    final height = image.height;
    const downscale = 2;
    final outputWidth = (width / downscale).floor();
    final outputHeight = (height / downscale).floor();
    final img.Image rgbImage = img.Image(width: outputWidth, height: outputHeight);

    final yPlane = image.planes[0];
    final uPlane = image.planes[1];
    final vPlane = image.planes[2];
    final int yRowStride = yPlane.bytesPerRow;
    final int uvRowStride = uPlane.bytesPerRow;
    final int uvPixelStride = uPlane.bytesPerPixel ?? 1;

    for (int y = 0, oy = 0; y < height; y += downscale, oy++) {
      final int yRow = yRowStride * y;
      final int uvRow = uvRowStride * (y >> 1);
      for (int x = 0, ox = 0; x < width; x += downscale, ox++) {
        final int yIndex = yRow + x;
        final int uvIndex = uvRow + (x >> 1) * uvPixelStride;

        final int yValue = yPlane.bytes[yIndex];
        final int uValue = uPlane.bytes[uvIndex];
        final int vValue = vPlane.bytes[uvIndex];

        final int r = (yValue + 1.370705 * (vValue - 128)).round().clamp(0, 255);
        final int g = (yValue - 0.337633 * (uValue - 128) - 0.698001 * (vValue - 128))
            .round()
            .clamp(0, 255);
        final int b = (yValue + 1.732446 * (uValue - 128)).round().clamp(0, 255);

        rgbImage.setPixelRgba(ox, oy, r, g, b, 255);
      }
    }

    return rgbImage;
  }

  Uint8List? _buildJpegFromBgra(CameraImage image, {Rect? cropRect}) {
    if (image.planes.isEmpty) return null;
    final plane = image.planes.first;
    final bytes = plane.bytes;
    final width = image.width;
    final height = image.height;
    const downscale = 2;
    final outputWidth = (width / downscale).floor();
    final outputHeight = (height / downscale).floor();
    final img.Image rgbImage = img.Image(width: outputWidth, height: outputHeight);
    final int rowStride = plane.bytesPerRow;

    for (int y = 0, oy = 0; y < height; y += downscale, oy++) {
      final int rowStart = y * rowStride;
      for (int x = 0, ox = 0; x < width; x += downscale, ox++) {
        final int index = rowStart + (x * 4);
        if (index + 3 >= bytes.length) continue;
        final int b = bytes[index];
        final int g = bytes[index + 1];
        final int r = bytes[index + 2];
        final int a = bytes[index + 3];
        rgbImage.setPixelRgba(ox, oy, r, g, b, a);
      }
    }
    final img.Image outputImage = _cropImageIfNeeded(
      rgbImage,
      cropRect: cropRect,
      originalSize: Size(width.toDouble(), height.toDouble()),
    );
    return Uint8List.fromList(img.encodeJpg(outputImage, quality: 85));
  }

  Uint8List? _buildJpegFromYuv420(CameraImage image, {Rect? cropRect}) {
    if (image.planes.length < 3) return null;
    final width = image.width;
    final height = image.height;
    const downscale = 2;
    final outputWidth = (width / downscale).floor();
    final outputHeight = (height / downscale).floor();
    final img.Image rgbImage = img.Image(width: outputWidth, height: outputHeight);

    final yPlane = image.planes[0];
    final uPlane = image.planes[1];
    final vPlane = image.planes[2];
    final int yRowStride = yPlane.bytesPerRow;
    final int uvRowStride = uPlane.bytesPerRow;
    final int uvPixelStride = uPlane.bytesPerPixel ?? 1;

    for (int y = 0, oy = 0; y < height; y += downscale, oy++) {
      final int yRow = yRowStride * y;
      final int uvRow = uvRowStride * (y >> 1);
      for (int x = 0, ox = 0; x < width; x += downscale, ox++) {
        final int yIndex = yRow + x;
        final int uvIndex = uvRow + (x >> 1) * uvPixelStride;

        final int yValue = yPlane.bytes[yIndex];
        final int uValue = uPlane.bytes[uvIndex];
        final int vValue = vPlane.bytes[uvIndex];

        final int r = (yValue + 1.370705 * (vValue - 128)).round().clamp(0, 255);
        final int g = (yValue - 0.337633 * (uValue - 128) - 0.698001 * (vValue - 128))
            .round()
            .clamp(0, 255);
        final int b = (yValue + 1.732446 * (uValue - 128)).round().clamp(0, 255);

        rgbImage.setPixelRgba(ox, oy, r, g, b, 255);
      }
    }

    final img.Image outputImage = _cropImageIfNeeded(
      rgbImage,
      cropRect: cropRect,
      originalSize: Size(width.toDouble(), height.toDouble()),
    );
    return Uint8List.fromList(img.encodeJpg(outputImage, quality: 85));
  }

  img.Image _cropImageIfNeeded(
    img.Image baseImage, {
    required Rect? cropRect,
    required Size originalSize,
  }) {
    if (cropRect == null) return baseImage;
    if (cropRect.width <= 1 || cropRect.height <= 1) return baseImage;

    final scaleX = baseImage.width / originalSize.width;
    final scaleY = baseImage.height / originalSize.height;

    int left = (cropRect.left * scaleX).round();
    int top = (cropRect.top * scaleY).round();
    int right = (cropRect.right * scaleX).round();
    int bottom = (cropRect.bottom * scaleY).round();

    left = left.clamp(0, baseImage.width - 1).toInt();
    top = top.clamp(0, baseImage.height - 1).toInt();
    right = right.clamp(left + 1, baseImage.width).toInt();
    bottom = bottom.clamp(top + 1, baseImage.height).toInt();

    final width = right - left;
    final height = bottom - top;
    if (width < 10 || height < 10) return baseImage;

    return img.copyCrop(baseImage, x: left, y: top, width: width, height: height);
  }

  Future<void> _speakGeminiText(String text) async {
    final normalized = _normalizeText(text);
    final now = DateTime.now();
    if (normalized == _lastSpokenText &&
        now.difference(_lastSpokenTime) < _speechCooldown) {
      return;
    }
    _lastSpokenText = normalized;
    _lastSpokenTime = now;
    await _voiceAssistant.speak(text);
  }

  String _filterOcrText(String text) {
    final lines = text.split('\n');
    final filtered = <String>[];
    final seen = <String>{};
    for (final line in lines) {
      final trimmed = line.trim();
      if (trimmed.length < 2) continue;
      if (_isNoiseLine(trimmed)) continue;
      final normalized = _normalizeText(trimmed);
      if (normalized.isEmpty) continue;
      if (!seen.add(normalized)) continue;
      filtered.add(trimmed);
      if (filtered.length >= 12) break;
    }
    return filtered.join('\n');
  }

  String _filterOcrTextForConversation(String text) {
    final lines = text.split('\n');
    final filtered = <String>[];
    final seen = <String>{};
    for (final line in lines) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      if (_isNoiseLine(trimmed)) continue;

      final normalized = _normalizeText(trimmed);
      if (normalized.isEmpty) continue;
      if (!seen.add(normalized)) continue;

      final hasLetters = RegExp(r'[a-zA-Z]').hasMatch(trimmed);
      final hasDigits = RegExp(r'\d').hasMatch(trimmed);
      final hasCurrency = RegExp(r'[₹$€£]|rs\.?|inr', caseSensitive: false)
          .hasMatch(trimmed);

      if (hasLetters || hasDigits || hasCurrency) {
        filtered.add(trimmed);
      }
      if (filtered.length >= 20) break;
    }
    return filtered.join('\n');
  }

  List<String> _intentKeywordsForQuery(String intent) {
    final normalized = _normalizeText(intent);
    final keywords = <String>{};
    for (final entry in _intentKeywordHints.entries) {
      if (normalized.contains(entry.key)) {
        keywords.addAll(entry.value.map(_normalizeText));
      }
    }
    keywords.addAll(
      normalized
          .split(' ')
          .map((token) => token.trim())
          .where((token) => token.length >= 2),
    );
    return keywords.toList();
  }

  bool _matchesIntentWithOcr(String intent, String ocrText) {
    final normalizedText = _normalizeText(ocrText);
    if (normalizedText.isEmpty) return false;
    for (final keyword in _intentKeywordsForQuery(intent)) {
      if (keyword.isEmpty) continue;
      if (normalizedText.contains(keyword)) {
        return true;
      }
    }
    return false;
  }

  String _canonicalIntentName(String intent) {
    final normalized = _normalizeText(intent);
    if (normalized.isEmpty) return 'Store';
    return intent.trim();
  }

  bool _isNoiseLine(String line) {
    final lower = line.toLowerCase();
    const noisyTokens = [
      'http',
      'www',
      '.com',
      '.in',
      '.org',
      '.net',
      'bing',
      'google',
      'search',
      'images',
      'image',
      'gmail',
      'youtube',
      'whatsapp',
      'instagram',
      'facebook',
      'twitter',
      'chrome',
      'edge',
      'browser',
      'tab',
      'play store',
      'app store',
    ];
    for (final token in noisyTokens) {
      if (lower.contains(token)) return true;
    }
    final alphaCount = RegExp(r'[a-zA-Z]').allMatches(line).length;
    if (line.length > 0 && (alphaCount / line.length) < 0.3) {
      return true;
    }
    return false;
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

  String _truncateText(String text, {int maxChars = 160}) {
    if (text.length <= maxChars) return text;
    return '${text.substring(0, maxChars).trimRight()}...';
  }

  double _jaccardSimilarity(String a, String b) {
    final aTokens = a.split(' ').where((token) => token.isNotEmpty).toSet();
    final bTokens = b.split(' ').where((token) => token.isNotEmpty).toSet();
    if (aTokens.isEmpty || bTokens.isEmpty) return 0;
    final intersection = aTokens.intersection(bTokens).length;
    final union = aTokens.union(bTokens).length;
    return union == 0 ? 0 : intersection / union;
  }

  // Voice response handling reserved for future 2-way conversations.

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
                    items: ['English', 'Hindi', 'Tamil'].map((lang) {
                      return DropdownMenuItem(value: lang, child: Text(lang, style: const TextStyle(fontSize: 18)));
                    }).toList(),
                    onChanged: (val) {
                      if (val == null) return;
                      setModalState(() => _selectedLanguage = val);
                      setState(() => _selectedLanguage = val);
                      final localeId = _selectedLanguage == 'Hindi'
                          ? 'hi_IN'
                          : _selectedLanguage == 'Tamil'
                              ? 'ta_IN'
                              : 'en_IN';
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
