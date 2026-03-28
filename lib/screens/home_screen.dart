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
  late final YoloDetectorService _signboardDetector;

  bool _isProcessingFrame = false;
  bool _yoloReady = false;
  bool _yoloInFlight = false;
  String? _yoloError;
  List<YoloDetection> _latestDetections = [];
  bool _indoorReady = false;
  bool _indoorInFlight = false;
  String? _indoorError;
  List<YoloDetection> _latestIndoorDetections = [];
  bool _signboardReady = false;
  bool _signboardInFlight = false;
  String? _signboardError;
  List<YoloDetection> _latestSignboardDetections = [];
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
  Size? _lastFrameSize;
  DateTime _lastAlertSpokenAt = DateTime.fromMillisecondsSinceEpoch(0);
  String _lastAlertKey = '';
  DateTime _lastSignboardSpokenAt = DateTime.fromMillisecondsSinceEpoch(0);
  String _lastSignboardText = '';
  DateTime _lastSignboardTime = DateTime.fromMillisecondsSinceEpoch(0);
  Rect? _signboardLandmark;
  DateTime _signboardLandmarkAt = DateTime.fromMillisecondsSinceEpoch(0);
  int _signboardLandmarkStreak = 0;
  YoloDetection? _lastSignboardDetection;

  static const Duration _analysisInterval = Duration(milliseconds: 500);
  static const Duration _emitCooldown = Duration(milliseconds: 1500);
  static const Duration _speechCooldown = Duration(seconds: 4);
  static const Duration _alertSpeakCooldown = Duration(seconds: 4);
  static const Duration _geminiCooldown = Duration(seconds: 6);
  static const Duration _yoloInterval = Duration(milliseconds: 900);
  static const int _yoloFrameStride = 4;
  static const int _indoorFrameStride = 4;
  static const int _indoorFrameOffset = 2;
  static const Duration _signboardInterval = Duration(milliseconds: 1200);
  static const int _signboardFrameStride = 5;
  static const int _signboardFrameOffset = 1;
  static const Duration _signboardSpeakCooldown = Duration(seconds: 6);
  static const Duration _signboardLandmarkHold = Duration(seconds: 2);
  static const double _signboardLandmarkSmoothing = 0.6;
  int _frameIndex = 0;
  static const double _roadMinConfidence = 0.35;
  static const double _indoorMinConfidence = 0.4;
  static const int _alertStreakTarget = 2;
  final Map<String, int> _alertStreaks = {};

  static const Set<String> _roadAlertLabels = {
    'vehiclehazard',
    'humannearby',
    'animalhazard',
    'roadhazard',
    'roadsideobstacle',
  };

  static const Set<String> _indoorAlertLabels = {
    'door',
    'openeddoor',
    'cabinetdoor',
    'refrigeratordoor',
    'window',
    'chair',
    'table',
    'cabinet',
    'couch',
    'pole',
    'stair',
    'stairs',
  };

  static const String _vehicleHazardLabel = 'vehicle_hazard';
  static const String _humanHazardLabel = 'human_nearby';
  static const String _animalHazardLabel = 'animal_hazard';
  static const String _roadHazardLabel = 'road_hazard';
  static const String _roadsideHazardLabel = 'roadside_obstacle';

  static const Set<String> _vehicleClassLabels = {
    'vehicle',
    'car',
    'bus',
    'truck',
    'motorcycle',
    'bicycle',
    'train',
    'boat',
    'autorickshaw',
    'rickshaw',
    'scooter',
  };

  static const Set<String> _humanClassLabels = {
    'person',
    'living',
  };

  static const Set<String> _animalClassLabels = {
    'dog',
    'cat',
    'cow',
    'horse',
    'sheep',
    'goat',
    'elephant',
    'bear',
  };

  static const Set<String> _roadHazardClassLabels = {
    'pothole',
    'speedbump',
    'bump',
    'non_drivable',
    'road',
    'roadhazard',
  };

  static const Set<String> _roadsideClassLabels = {
    'roadside',
    'pole',
    'electricpole',
    'powerpole',
    'streetlight',
    'tree',
    'trashbin',
    'trashcan',
    'bin',
    'barrier',
    'barricade',
    'construction',
    'cone',
    'fence',
    'bench',
    'firehydrant',
    'parkingmeter',
    'stopsign',
    'trafficsignal',
    'trafficlight',
  };

  static const Map<String, String> _alertSpokenLabels = {
    'non_drivable': 'unsafe surface',
    'living': 'person',
    'roadside': 'roadside object',
    'vehicle': 'vehicle',
    'drivable': 'road',
    'far': 'distant area',
    'sky': 'sky',
    'openeddoor': 'open door',
    'cabinetdoor': 'cabinet door',
    'refrigeratordoor': 'refrigerator door',
    'electricpole': 'electric pole',
    'powerpole': 'electric pole',
    'streetlight': 'street light',
    'autorickshaw': 'auto rickshaw',
    'rickshaw': 'rickshaw',
    'speedbump': 'speed bump',
    'vehiclehazard': 'vehicle hazard',
    'humannearby': 'human nearby',
    'animalhazard': 'animal hazard',
    'roadhazard': 'road hazard',
    'roadsideobstacle': 'roadside obstacle',
  };

  static const Map<String, String> _alertGuidance = {
    'vehicle': 'Keep left.',
    'living': 'Give way.',
    'roadside': 'Obstacle ahead.',
    'non_drivable': 'Unsafe surface ahead.',
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
    'chair': 'Obstacle ahead.',
    'table': 'Obstacle ahead.',
    'cabinet': 'Obstacle ahead.',
    'couch': 'Obstacle ahead.',
    'vehiclehazard': 'Keep left.',
    'humannearby': 'Give way.',
    'animalhazard': 'Be careful.',
    'roadhazard': 'Watch your step.',
    'roadsideobstacle': 'Obstacle on the side.',
  };

  static const List<double> _defaultDistanceBuckets = [3.0, 6.0, 10.0];

  static const Map<String, List<double>> _distanceBucketsByLabel = {
    'vehicle': [4.0, 8.0, 12.0],
    'living': [3.5, 7.0, 10.0],
    'roadside': [3.5, 7.0, 10.0],
    'electricpole': [3.5, 7.0, 10.0],
    'powerpole': [3.5, 7.0, 10.0],
    'streetlight': [3.5, 7.0, 10.0],
    'door': [2.5, 5.0, 8.0],
    'openeddoor': [2.5, 5.0, 8.0],
    'cabinetdoor': [2.0, 4.0, 6.0],
    'refrigeratordoor': [2.0, 4.0, 6.0],
    'window': [2.0, 4.0, 7.0],
    'chair': [2.0, 4.0, 6.0],
    'table': [2.0, 4.0, 6.0],
    'cabinet': [2.0, 4.0, 6.0],
    'couch': [2.0, 4.0, 6.0],
    'pole': [3.0, 6.0, 9.0],
    'vehiclehazard': [4.0, 8.0, 12.0],
    'humannearby': [3.0, 6.0, 10.0],
    'animalhazard': [3.0, 6.0, 10.0],
    'roadhazard': [2.5, 5.0, 8.0],
    'roadsideobstacle': [3.0, 6.0, 10.0],
  };

  static const Map<String, double> _indoorMinAreaRatio = {
    'door': 0.03,
    'openeddoor': 0.03,
    'cabinetdoor': 0.02,
    'refrigeratordoor': 0.02,
    'window': 0.02,
    'chair': 0.008,
    'table': 0.01,
    'cabinet': 0.02,
    'couch': 0.02,
    'pole': 0.015,
  };

  static const Map<String, double> _indoorMinConfidenceByLabel = {
    'door': 0.45,
    'openeddoor': 0.45,
    'cabinetdoor': 0.45,
    'refrigeratordoor': 0.45,
    'window': 0.45,
    'cabinet': 0.45,
    'chair': 0.4,
    'table': 0.4,
    'couch': 0.4,
    'pole': 0.4,
  };

  static const Map<String, String> _hindiLabels = {
    'vehicle': 'वाहन',
    'living': 'व्यक्ति',
    'roadside': 'रोडसाइड वस्तु',
    'non_drivable': 'असुरक्षित सतह',
    'drivable': 'सड़क',
    'far': 'दूर क्षेत्र',
    'sky': 'आसमान',
    'car': 'कार',
    'truck': 'ट्रक',
    'bus': 'बस',
    'motorcycle': 'मोटरसाइकिल',
    'bicycle': 'साइकिल',
    'scooter': 'स्कूटर',
    'autorickshaw': 'ऑटो',
    'rickshaw': 'रिक्शा',
    'pothole': 'गड्ढा',
    'speedbump': 'स्पीड ब्रेकर',
    'bump': 'स्पीड ब्रेकर',
    'barricade': 'बैरिकेड',
    'barrier': 'बैरियर',
    'construction': 'निर्माण क्षेत्र',
    'cone': 'कोन',
    'electricpole': 'बिजली का खंभा',
    'powerpole': 'बिजली का खंभा',
    'streetlight': 'स्ट्रीट लाइट',
    'door': 'दरवाज़ा',
    'openeddoor': 'खुला दरवाज़ा',
    'cabinetdoor': 'कैबिनेट दरवाज़ा',
    'refrigeratordoor': 'फ्रिज का दरवाज़ा',
    'chair': 'कुर्सी',
    'table': 'मेज',
    'cabinet': 'कैबिनेट',
    'couch': 'सोफ़ा',
    'pole': 'खंभा',
    'vehiclehazard': 'वाहन खतरा',
    'humannearby': 'व्यक्ति पास में',
    'animalhazard': 'जानवर खतरा',
    'roadhazard': 'सड़क खतरा',
    'roadsideobstacle': 'सड़क किनारे बाधा',
  };

  static const Map<String, String> _hindiGuidance = {
    'vehicle': 'बाईं ओर रहें।',
    'living': 'रास्ता दें।',
    'roadside': 'सावधान रहें।',
    'non_drivable': 'सावधान रहें।',
    'car': 'बाईं ओर रहें।',
    'truck': 'बाईं ओर रहें।',
    'bus': 'बाईं ओर रहें।',
    'motorcycle': 'बाईं ओर रहें।',
    'bicycle': 'बाईं ओर रहें।',
    'autorickshaw': 'बाईं ओर रहें।',
    'rickshaw': 'बाईं ओर रहें।',
    'scooter': 'बाईं ओर रहें।',
    'pothole': 'सावधान रहें।',
    'speedbump': 'धीरे चलें।',
    'bump': 'धीरे चलें।',
    'barricade': 'सावधान रहें।',
    'barrier': 'सावधान रहें।',
    'construction': 'सावधान रहें।',
    'cone': 'सावधान रहें।',
    'door': 'सावधान रहें।',
    'openeddoor': 'सावधान रहें।',
    'cabinetdoor': 'सावधान रहें।',
    'refrigeratordoor': 'सावधान रहें।',
    'chair': 'सावधान रहें।',
    'table': 'सावधान रहें।',
    'cabinet': 'सावधान रहें।',
    'couch': 'सावधान रहें।',
    'pole': 'सावधान रहें।',
    'electricpole': 'सावधान रहें।',
    'powerpole': 'सावधान रहें।',
    'streetlight': 'सावधान रहें।',
    'vehiclehazard': 'बाईं ओर रहें।',
    'humannearby': 'धीरे चलें।',
    'animalhazard': 'सावधान रहें।',
    'roadhazard': 'सावधान रहें।',
    'roadsideobstacle': 'सावधान रहें।',
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
    _signboardDetector = YoloDetectorService(
      modelAsset: SIGNBOARD_YOLO_MODEL_ASSET,
      labelsAsset: SIGNBOARD_LABELS_ASSET,
      inputSize: 640,
    );
    unawaited(_initializeSignboardYolo());

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
    unawaited(_signboardDetector.dispose());
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

  Future<void> _initializeSignboardYolo() async {
    if (kIsWeb) {
      if (mounted) {
        setState(() {
          _signboardError = 'On-device detection is not available on web.';
        });
      }
      return;
    }
    try {
      await _signboardDetector.initialize();
      if (!mounted) return;
      setState(() {
        _signboardReady = true;
        _signboardError = null;
        _latestGeminiError = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _signboardReady = false;
        _signboardError = 'Signboard detector init failed: ${error.toString()}';
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

  Widget _buildSmartOverlay() {
    final signboardError = _signboardError;
    final hasError = (signboardError != null && signboardError.isNotEmpty) ||
        (_latestGeminiError != null && _latestGeminiError!.isNotEmpty);
    final hasSmart = _latestSmartText.isNotEmpty;

    String title;
    String body;
    Color accentColor;

    if (hasError) {
      title = signboardError != null && signboardError.isNotEmpty
          ? 'Signboard detector unavailable'
          : 'Smart reading unavailable';
      body = signboardError != null && signboardError.isNotEmpty
          ? signboardError
          : (_latestGeminiError ?? 'Unknown error');
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
      final fallback = _topByScore(_latestDetections);
      if (fallback == null) {
        roadTitle = 'No road alerts';
        roadBody = 'No nearby hazards detected.';
        roadAccentColor = const Color(0xFFFFE4A3);
      } else {
        final distanceText = fallback.distanceMeters == null
            ? ''
            : ' • ${fallback.distanceMeters!.toStringAsFixed(1)}m';
        roadTitle = 'Road detected';
        roadBody =
            '${fallback.label}$distanceText • ${(fallback.score * 100).toStringAsFixed(1)}%';
        roadAccentColor = const Color(0xFF9FB0C7);
      }
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
      final fallback = _topByScore(_latestIndoorDetections);
      if (fallback == null) {
        indoorTitle = 'No indoor alerts';
        indoorBody = 'No nearby hazards detected.';
        indoorAccentColor = const Color(0xFFFFE4A3);
      } else {
        final distanceText = fallback.distanceMeters == null
            ? ''
            : ' • ${fallback.distanceMeters!.toStringAsFixed(1)}m';
        indoorTitle = 'Indoor detected';
        indoorBody =
            '${fallback.label}$distanceText • ${(fallback.score * 100).toStringAsFixed(1)}%';
        indoorAccentColor = const Color(0xFF9FB0C7);
      }
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
    final isIndoor = identical(allowedLabels, _indoorAlertLabels);
    final alerts = detections.where((d) {
      final normalized = _normalizeLabelForAlert(d.label);
      final minConfidence = isIndoor
          ? (_indoorMinConfidenceByLabel[normalized] ?? _indoorMinConfidence)
          : _roadMinConfidence;
      if (d.score < minConfidence) return false;
      if (!allowedLabels.contains(normalized)) return false;
      if (isIndoor) {
        final minArea = _indoorMinAreaRatio[normalized];
        if (minArea != null && d.areaRatio < minArea) return false;
      }
      if (d.distanceMeters != null) {
        return d.distanceMeters! <= _maxAlertDistance(normalized);
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

  List<double> _distanceBucketsForLabel(String normalized) {
    return _distanceBucketsByLabel[normalized] ?? _defaultDistanceBuckets;
  }

  double _maxAlertDistance(String normalized) {
    final buckets = _distanceBucketsForLabel(normalized);
    return buckets[2];
  }

  String _distanceBucketForDetection(YoloDetection detection) {
    final normalized = _normalizeLabelForAlert(detection.label);
    final distance = detection.distanceMeters;
    if (distance != null) {
      final buckets = _distanceBucketsForLabel(normalized);
      if (distance <= buckets[0]) return 'urgent';
      if (distance <= buckets[1]) return 'near';
      if (distance <= buckets[2]) return 'mid';
      return 'far';
    }
    return detection.proximity;
  }

  int _urgencyRank(YoloDetection detection) {
    final distance = detection.distanceMeters;
    final normalized = _normalizeLabelForAlert(detection.label);
    final buckets = _distanceBucketsForLabel(normalized);
    if (distance != null) {
      if (distance <= buckets[0]) return 0;
      if (distance <= buckets[1]) return 1;
      if (distance <= buckets[2]) return 2;
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

  YoloDetection? _topByScore(List<YoloDetection> detections) {
    if (detections.isEmpty) return null;
    final sorted = [...detections]..sort((a, b) => b.score.compareTo(a.score));
    return sorted.first;
  }

  String? _hazardLabelForNormalized(String normalized) {
    if (_vehicleClassLabels.contains(normalized)) return _vehicleHazardLabel;
    if (_humanClassLabels.contains(normalized)) return _humanHazardLabel;
    if (_animalClassLabels.contains(normalized)) return _animalHazardLabel;
    if (_roadHazardClassLabels.contains(normalized)) return _roadHazardLabel;
    if (_roadsideClassLabels.contains(normalized)) return _roadsideHazardLabel;
    return null;
  }

  List<YoloDetection> _mapRoadDetectionsToHazards(List<YoloDetection> detections) {
    if (detections.isEmpty) return detections;
    final mapped = <YoloDetection>[];
    for (final det in detections) {
      final normalized = _normalizeLabelForAlert(det.label);
      final hazardLabel = _hazardLabelForNormalized(normalized);
      if (hazardLabel == null) continue;
      if (hazardLabel == det.label) {
        mapped.add(det);
      } else {
        mapped.add(
          YoloDetection(
            classId: det.classId,
            label: hazardLabel,
            score: det.score,
            rect: det.rect,
            areaRatio: det.areaRatio,
            proximity: det.proximity,
            distanceMeters: det.distanceMeters,
          ),
        );
      }
    }
    return mapped;
  }

  String _proximityFromAreaRatio(double areaRatio) {
    if (areaRatio >= 0.2) return 'near';
    if (areaRatio >= 0.08) return 'mid';
    return 'far';
  }

  YoloDetection? _detectDarkPatch(img.Image image) {
    final width = image.width;
    final height = image.height;
    if (width == 0 || height == 0) return null;
    final int startY = (height * 0.6).toInt();
    const int step = 4;
    int darkCount = 0;
    int total = 0;
    int minX = width;
    int minY = height;
    int maxX = 0;
    int maxY = 0;

    for (int y = startY; y < height; y += step) {
      for (int x = 0; x < width; x += step) {
        final pixel = image.getPixel(x, y);
        final int r = pixel.r.toInt();
        final int g = pixel.g.toInt();
        final int b = pixel.b.toInt();
        final double gray = 0.299 * r + 0.587 * g + 0.114 * b;
        total++;
        if (gray < 65) {
          darkCount++;
          if (x < minX) minX = x;
          if (y < minY) minY = y;
          if (x > maxX) maxX = x;
          if (y > maxY) maxY = y;
        }
      }
    }

    if (total == 0) return null;
    final double darkRatio = darkCount / total;
    if (darkRatio < 0.06 || darkRatio > 0.45) return null;
    if (minX >= maxX || minY >= maxY) return null;

    final rectWidth = (maxX - minX + step).toDouble().clamp(0.0, width.toDouble());
    final rectHeight = (maxY - minY + step).toDouble().clamp(0.0, height.toDouble());
    final rect = Rect.fromLTWH(
      minX.toDouble(),
      minY.toDouble(),
      rectWidth,
      rectHeight,
    );
    final areaRatio = (rectWidth * rectHeight) / (width * height);
    if (areaRatio < 0.01 || areaRatio > 0.5) return null;

    final proximity = _proximityFromAreaRatio(areaRatio);
    final score = (darkRatio * 3).clamp(0.2, 0.9);
    return YoloDetection(
      classId: -1,
      label: _roadHazardLabel,
      score: score,
      rect: rect,
      areaRatio: areaRatio,
      proximity: proximity,
      distanceMeters: null,
    );
  }

  String _extractTextFromSignboards(
    List<RecognizedText> results,
    List<YoloDetection> signboards,
  ) {
    if (results.isEmpty) return '';
    final rects = _getActiveSignboardRects(signboards);
    if (rects.isEmpty) return '';
    final lines = <String>[];
    final seen = <String>{};

    Rect? bestRectFor(Rect rect, double minOverlap) {
      Rect? best;
      double bestOverlap = 0.0;
      for (final r in rects) {
        if (!r.overlaps(rect)) continue;
        final inter = r.intersect(rect);
        if (inter.isEmpty) continue;
        final overlap = (inter.width * inter.height) / (rect.width * rect.height);
        if (overlap > bestOverlap) {
          bestOverlap = overlap;
          best = r;
        }
      }
      if (bestOverlap < minOverlap) return null;
      return best;
    }

    for (final result in results) {
      for (final block in result.blocks) {
        final box = block.boundingBox;
        if (box == null) continue;
        final bestRect = bestRectFor(box, 0.35);
        if (bestRect == null) continue;
        final heightRatio = box.height / bestRect.height;
        if (heightRatio < 0.04 || heightRatio > 0.9) continue;
        final raw = block.text.trim();
        if (raw.isEmpty) continue;
        if (!_lineLooksValid(raw)) continue;
        if (seen.add(raw)) {
          lines.add(raw);
        }
      }
    }
    final text = lines.join(' ').trim();
    return _shortenSignboardText(_cleanSignboardText(text));
  }

  List<Rect> _getActiveSignboardRects(List<YoloDetection> signboards) {
    if (signboards.isNotEmpty) {
      return signboards.map((d) => _expandRect(d.rect, 0.08)).toList();
    }
    final now = DateTime.now();
    if (_signboardLandmark == null) return const [];
    if (now.difference(_signboardLandmarkAt) > _signboardLandmarkHold) {
      return const [];
    }
    return [_expandRect(_signboardLandmark!, 0.1)];
  }

  Rect _expandRect(Rect rect, double padRatio) {
    final frame = _lastFrameSize;
    if (frame == null) return rect;
    final padX = rect.width * padRatio;
    final padY = rect.height * padRatio;
    final left = (rect.left - padX).clamp(0.0, frame.width);
    final top = (rect.top - padY).clamp(0.0, frame.height);
    final right = (rect.right + padX).clamp(0.0, frame.width);
    final bottom = (rect.bottom + padY).clamp(0.0, frame.height);
    return Rect.fromLTRB(left, top, right, bottom);
  }

  void _updateSignboardLandmark(Rect rect) {
    final now = DateTime.now();
    if (_signboardLandmark == null) {
      _signboardLandmark = rect;
      _signboardLandmarkAt = now;
      _signboardLandmarkStreak = 1;
      return;
    }
    final current = _signboardLandmark!;
    final blended = Rect.lerp(current, rect, _signboardLandmarkSmoothing) ?? rect;
    _signboardLandmark = blended;
    _signboardLandmarkAt = now;
    _signboardLandmarkStreak += 1;
  }

  String _shortenSignboardText(String text) {
    if (text.isEmpty) return text;
    final cleaned = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    final words = cleaned.split(' ');
    if (words.length <= 8) return cleaned;
    return words.take(8).join(' ');
  }

  String _cleanSignboardText(String text) {
    if (text.isEmpty) return text;
    final parts = text.split(RegExp(r'\s+'));
    final kept = <String>[];
    for (final part in parts) {
      if (_tokenLooksValid(part)) {
        kept.add(part);
      }
    }
    return kept.join(' ').trim();
  }

  bool _lineLooksValid(String text) {
    final cleaned = text.replaceAll(RegExp(r'[^A-Za-z0-9\u0900-\u097F]'), '');
    if (cleaned.length < 2) return false;
    final ratio = cleaned.length / text.length;
    if (ratio < 0.45) return false;
    return true;
  }

  bool _tokenLooksValid(String token) {
    if (token.length < 2) return false;
    final cleaned = token.replaceAll(RegExp(r'[^A-Za-z0-9\u0900-\u097F]'), '');
    if (cleaned.length < 2) return false;
    final nonWord = token.replaceAll(RegExp(r'[A-Za-z0-9\u0900-\u097F]'), '');
    final noiseRatio = nonWord.length / token.length;
    if (noiseRatio > 0.5) return false;
    if (RegExp(r'^(.)\1{3,}$').hasMatch(cleaned)) return false;
    return true;
  }

  String _buildSignboardMessage(String text, YoloDetection detection) {
    final direction = _directionForRect(detection.rect);
    final distanceWord = _distanceDescriptor(detection);
    final directionPhrase = direction == 'ahead' ? 'ahead' : 'on your $direction';
    if (_selectedLanguage == 'Hindi') {
      final hindiDirection = _hindiDirection(direction);
      final hindiDistance = _hindiDistanceDescriptor(detection, direction);
      return 'साइनबोर्ड: $text, $hindiDistance $hindiDirection है।';
    }
    return 'Signboard: $text, $distanceWord $directionPhrase.';
  }

  Future<void> _speakSignboard(String text, YoloDetection detection) async {
    if (!_soundEnabled) return;
    if (_voiceAssistant.isListening.value || _voiceAssistant.isSpeaking.value) return;
    final normalized = _normalizeText(text);
    final now = DateTime.now();
    if (normalized.isEmpty) return;
    if (normalized == _lastSignboardText &&
        now.difference(_lastSignboardSpokenAt) < _signboardSpeakCooldown) {
      return;
    }
    _lastSignboardText = normalized;
    _lastSignboardSpokenAt = now;
    final message = _buildSignboardMessage(text, detection);
    await _voiceAssistant.speak(message);
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
    final normalized = _normalizeLabelForAlert(detection.label);
    final buckets = _distanceBucketsForLabel(normalized);
    if (distance != null) {
      if (distance <= buckets[0]) return 'very close';
      if (distance <= buckets[1]) return 'nearby';
      if (distance <= buckets[2]) return 'ahead';
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
    if (_selectedLanguage == 'Hindi') {
      return _buildHindiAlertMessage(detection);
    }
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

  List<YoloDetection> _scaleDetectionsToFrame(
    List<YoloDetection> detections,
    img.Image rgbImage,
  ) {
    final frame = _lastFrameSize;
    if (frame == null || frame.width <= 0 || frame.height <= 0) return detections;
    final scaleX = frame.width / rgbImage.width;
    final scaleY = frame.height / rgbImage.height;
    if ((scaleX - 1.0).abs() < 0.01 && (scaleY - 1.0).abs() < 0.01) {
      return detections;
    }
    return detections
        .map(
          (d) => YoloDetection(
            classId: d.classId,
            label: d.label,
            score: d.score,
            rect: Rect.fromLTRB(
              d.rect.left * scaleX,
              d.rect.top * scaleY,
              d.rect.right * scaleX,
              d.rect.bottom * scaleY,
            ),
            areaRatio: d.areaRatio,
            proximity: d.proximity,
            distanceMeters: d.distanceMeters,
          ),
        )
        .toList();
  }

  YoloDetection _copyDetectionWithRect(YoloDetection detection, Rect rect) {
    return YoloDetection(
      classId: detection.classId,
      label: detection.label,
      score: detection.score,
      rect: rect,
      areaRatio: detection.areaRatio,
      proximity: detection.proximity,
      distanceMeters: detection.distanceMeters,
    );
  }

  YoloDetection? _fallbackSignboardDetection(Rect rect) {
    final base = _lastSignboardDetection;
    if (base != null) return _copyDetectionWithRect(base, rect);
    final frame = _lastFrameSize;
    if (frame == null || frame.width <= 0 || frame.height <= 0) return null;
    final areaRatio = (rect.width * rect.height) / (frame.width * frame.height);
    final proximity = _proximityFromAreaRatio(areaRatio);
    return YoloDetection(
      classId: 0,
      label: 'signboard',
      score: 1.0,
      rect: rect,
      areaRatio: areaRatio,
      proximity: proximity,
      distanceMeters: null,
    );
  }

  String _buildHindiAlertMessage(YoloDetection detection) {
    final normalized = _normalizeLabelForAlert(detection.label);
    final label = _hindiLabels[normalized] ?? _humanizeLabel(detection.label);
    final direction = _directionForRect(detection.rect);
    final distanceWord = _hindiDistanceDescriptor(detection, direction);
    final directionPhrase = _hindiDirection(direction);
    final guidance = _hindiGuidance[normalized];
    final base = '$label $distanceWord $directionPhrase है।';
    if (guidance == null) return base;
    return '$base $guidance';
  }

  String _hindiDirection(String direction) {
    switch (direction) {
      case 'left':
        return 'बाईं ओर';
      case 'right':
        return 'दाईं ओर';
      default:
        return 'सामने';
    }
  }

  String _hindiDistanceDescriptor(YoloDetection detection, String direction) {
    final distance = detection.distanceMeters;
    final normalized = _normalizeLabelForAlert(detection.label);
    final buckets = _distanceBucketsForLabel(normalized);
    String word;
    if (distance != null) {
      if (distance <= buckets[0]) {
        word = 'बहुत पास';
      } else if (distance <= buckets[1]) {
        word = 'पास';
      } else if (distance <= buckets[2]) {
        word = 'आगे';
      } else {
        word = 'दूर';
      }
    } else {
      switch (detection.proximity) {
        case 'urgent':
          word = 'बहुत पास';
          break;
        case 'near':
          word = 'पास';
          break;
        case 'mid':
          word = 'आगे';
          break;
        default:
          word = 'दूर';
      }
    }
    if (direction != 'ahead' && word == 'आगे') {
      word = 'पास';
    }
    return word;
  }

  String _alertKey(YoloDetection detection) {
    final normalized = _normalizeLabelForAlert(detection.label);
    final direction = _directionForRect(detection.rect);
    final bucket = _distanceBucketForDetection(detection);
    return '$normalized:$bucket:$direction';
  }

  Future<void> _maybeSpeakAlerts() async {
    if (!_soundEnabled) return;
    if (_voiceAssistant.isListening.value || _voiceAssistant.isSpeaking.value) return;
    final now = DateTime.now();
    if (now.difference(_lastAlertSpokenAt) < _alertSpeakCooldown) return;

    final roadAlerts = _filterAlertDetections(_latestDetections, _roadAlertLabels);
    final indoorAlerts = _filterAlertDetections(_latestIndoorDetections, _indoorAlertLabels);
    final seenNow = <String>{};
    for (final det in [...roadAlerts, ...indoorAlerts]) {
      seenNow.add(_normalizeLabelForAlert(det.label));
    }
    for (final label in _alertStreaks.keys.toList()) {
      if (!seenNow.contains(label)) {
        _alertStreaks[label] = 0;
      }
    }
    for (final label in seenNow) {
      final current = _alertStreaks[label] ?? 0;
      _alertStreaks[label] = current + 1;
    }

    final candidate = _pickMostUrgentAlert(roadAlerts, indoorAlerts);
    if (candidate == null) return;
    final candidateLabel = _normalizeLabelForAlert(candidate.label);
    if ((_alertStreaks[candidateLabel] ?? 0) < _alertStreakTarget) {
      return;
    }

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
      final results = await Future.wait([
        _latinTextRecognizer.processImage(inputImage),
        _devanagariTextRecognizer.processImage(inputImage),
        _tamilTextRecognizer.processImage(inputImage),
      ]);
      final ocrResults = results;
      final mergedText = _mergeRecognizedText(results);
      _updateOcrPreview(mergedText);
      if (!_signboardReady) {
        _handleOcrResult(mergedText, image);
      }

      final bool shouldRunRoad = _yoloReady &&
          !_yoloInFlight &&
          _frameIndex % _yoloFrameStride == 0 &&
          now.difference(_lastYoloTime) > _yoloInterval;
      final bool shouldRunIndoor = _indoorReady &&
          !_indoorInFlight &&
          _frameIndex % _indoorFrameStride == _indoorFrameOffset &&
          now.difference(_lastIndoorTime) > _yoloInterval;
      final bool shouldRunSignboard = _signboardReady &&
          !_signboardInFlight &&
          _frameIndex % _signboardFrameStride == _signboardFrameOffset &&
          now.difference(_lastSignboardTime) > _signboardInterval;
      if (shouldRunRoad) {
        _yoloInFlight = true;
        _lastYoloTime = now;
      }
      if (shouldRunIndoor) {
        _indoorInFlight = true;
        _lastIndoorTime = now;
      }
      if (shouldRunSignboard) {
        _signboardInFlight = true;
        _lastSignboardTime = now;
      }
      bool shouldSpeakAlerts = false;
      if (shouldRunRoad || shouldRunIndoor || shouldRunSignboard) {
        final rgbImage = _buildRgbImageForYolo(image);
        if (rgbImage != null) {
          if (shouldRunRoad) {
            try {
              final detections = await _yoloDetector.detect(rgbImage);
              final scaledDetections = _scaleDetectionsToFrame(detections, rgbImage);
              final darkPatch = _detectDarkPatch(rgbImage);
              final scaledDarkPatch = darkPatch == null
                  ? null
                  : _scaleDetectionsToFrame([darkPatch], rgbImage).first;
              final combined = <YoloDetection>[
                ...scaledDetections,
                if (scaledDarkPatch != null) scaledDarkPatch,
              ];
              final mappedDetections = _mapRoadDetectionsToHazards(combined);
              if (mounted) {
                setState(() {
                  _latestDetections = mappedDetections;
                  _yoloError = null;
                });
              }
              shouldSpeakAlerts = true;
            } catch (error) {
              debugPrint('YOLO road error: $error');
              if (mounted) {
                setState(() {
                  _yoloError = 'Detector error: ${error.toString()}';
                });
              }
            } finally {
              _yoloInFlight = false;
            }
          }
          if (shouldRunIndoor) {
            try {
              final detections = await _indoorDetector.detect(
                rgbImage,
                confThreshold: 0.35,
              );
              final scaledDetections = _scaleDetectionsToFrame(detections, rgbImage);
              if (mounted) {
                setState(() {
                  _latestIndoorDetections = scaledDetections;
                  _indoorError = null;
                });
              }
              shouldSpeakAlerts = true;
            } catch (error) {
              debugPrint('YOLO indoor error: $error');
              if (mounted) {
                setState(() {
                  _indoorError = 'Indoor detector error: ${error.toString()}';
                });
              }
            } finally {
              _indoorInFlight = false;
            }
          }
          if (shouldRunSignboard) {
            try {
              final detections = await _signboardDetector.detect(
                rgbImage,
                confThreshold: 0.3,
              );
              final scaledDetections = _scaleDetectionsToFrame(detections, rgbImage);
              if (mounted) {
                setState(() {
                  _latestSignboardDetections = scaledDetections;
                  _signboardError = null;
                });
              }
              YoloDetection? speakTarget;
              List<YoloDetection> rectSources = scaledDetections;
              if (scaledDetections.isNotEmpty) {
                final sorted = [...scaledDetections]
                  ..sort((a, b) => b.score.compareTo(a.score));
                final top = sorted.first;
                _lastSignboardDetection = top;
                _updateSignboardLandmark(top.rect);
                speakTarget = top;
                rectSources = sorted;
              }
              final text = _extractTextFromSignboards(ocrResults, rectSources);
              if (text.isNotEmpty) {
                if (mounted) {
                  setState(() {
                    _latestOcrText = text;
                    _latestSmartText = text;
                    _latestSmartEmpty = false;
                    _latestGeminiError = null;
                  });
                }
                final landmarkRect = _signboardLandmark;
                if (speakTarget == null && landmarkRect != null) {
                  speakTarget = _fallbackSignboardDetection(landmarkRect);
                }
                if (speakTarget != null) {
                  await _speakSignboard(text, speakTarget);
                }
              }
            } catch (error) {
              debugPrint('YOLO signboard error: $error');
              if (mounted) {
                setState(() {
                  _signboardError = 'Signboard detector error: ${error.toString()}';
                });
              }
            } finally {
              _signboardInFlight = false;
            }
          }
        } else {
          if (shouldRunRoad) _yoloInFlight = false;
          if (shouldRunIndoor) _indoorInFlight = false;
          if (shouldRunSignboard) _signboardInFlight = false;
        }
        if (shouldSpeakAlerts) {
          unawaited(_maybeSpeakAlerts());
        }
      }
    } catch (error) {
      debugPrint('Frame processing error: $error');
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

  void _handleOcrResult(String text, CameraImage image) {
    final cleaned = text.trim();
    if (cleaned.isEmpty) return;
    final normalized = _normalizeText(cleaned);
    if (normalized.isEmpty) return;

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
      setState(() {
        _latestOcrText = cleaned;
        _latestSmartText = '';
        _latestSmartEmpty = false;
        _latestGeminiError = null;
      });
    }
    debugPrint('OCR: $cleaned');
    unawaited(_maybeSendToGemini(cleaned, image));
  }

  void _updateOcrPreview(String text) {
    final cleaned = text.trim();
    if (cleaned.isEmpty) return;
    if (mounted) {
      setState(() {
        _latestOcrText = cleaned;
      });
    }
  }

  Future<void> _maybeSendToGemini(String text, CameraImage image) async {
    if (_signboardReady) {
      return;
    }
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
    final filteredNormalized = _normalizeText(filteredText);
    if (_lastGeminiText.isNotEmpty &&
        _jaccardSimilarity(filteredNormalized, _lastGeminiText) >= 0.9) {
      return;
    }

    final jpegBytes = _buildGeminiImage(image);
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

    _geminiInFlight = true;
    _lastGeminiCall = now;
    _lastGeminiText = filteredNormalized;

    try {
      final result = await _geminiService.analyze(
        ocrText: filteredText,
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

  Uint8List? _buildGeminiImage(CameraImage image) {
    if (Platform.isIOS && image.format.group == ImageFormatGroup.bgra8888) {
      return _buildJpegFromBgra(image);
    }
    if (Platform.isAndroid) {
      return _buildJpegFromYuv420(image);
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

  Uint8List? _buildJpegFromBgra(CameraImage image) {
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
    return Uint8List.fromList(img.encodeJpg(rgbImage, quality: 75));
  }

  Uint8List? _buildJpegFromYuv420(CameraImage image) {
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

    return Uint8List.fromList(img.encodeJpg(rgbImage, quality: 70));
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
