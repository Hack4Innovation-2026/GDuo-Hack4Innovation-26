import 'package:image/image.dart' as img;
import 'package:permission_handler/permission_handler.dart';

import '../services/voice_assistant_service.dart';
import '../services/gemini_service.dart';

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

  bool _isProcessingFrame = false;
  bool _isCapturing = false;
  DateTime _lastCaptureTime = DateTime.fromMillisecondsSinceEpoch(0);
  Rect? _lastFocusRect;
  DateTime _focusStableSince = DateTime.fromMillisecondsSinceEpoch(0);
  bool _detectedAnnounced = false;
  DateTime _lastAnalysisTime = DateTime.fromMillisecondsSinceEpoch(0);
  String _latestOcrText = '';
  String _latestSmartText = '';
  String? _latestGeminiError;
  DateTime _lastGuidanceTime = DateTime.fromMillisecondsSinceEpoch(0);
  String _lastGuidanceText = '';
  String _currentGuidanceText = '';
  bool _holdAnnounced = false;
  DateTime _lastSpokenTime = DateTime.fromMillisecondsSinceEpoch(0);
  String _lastSpokenText = '';
  DateTime _lastGeminiCall = DateTime.fromMillisecondsSinceEpoch(0);
  String _lastGeminiText = '';
  bool _geminiInFlight = false;
  bool _latestSmartEmpty = false;

  static const Duration _analysisInterval = Duration(milliseconds: 500);
  static const Duration _speechCooldown = Duration(seconds: 4);
  static const Duration _captureHoldDuration = Duration(milliseconds: 1000);
  static const Duration _captureCooldown = Duration(seconds: 5);
  static const Duration _geminiCooldown = Duration(seconds: 8);
  static const Duration _guidanceCooldown = Duration(seconds: 2);

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
    final bool isScanning = _currentState == HomeState.scanning;
    final String statusText = _cameraError != null
        ? _cameraError!
        : _isCapturing
            ? 'Reading signboard...'
            : isScanning
                ? (_cameraReady ? 'Scanning for signboards...' : 'Starting camera...')
                : 'Ready to scan';

    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Stack(
          children: [
            Positioned.fill(child: _buildCameraPreview()),
            if (!isScanning || _cameraError != null) _buildPermissionOverlay(),
            Positioned(
              top: 16,
              left: 16,
              right: 16,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildVoiceOverlay(),
                  if (_currentGuidanceText.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    _buildGuidanceOverlay(),
                  ],
                  if (_latestGeminiError != null ||
                      _latestSmartText.isNotEmpty ||
                      _latestOcrText.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    _buildSmartOverlay(),
                  ],
                ],
              ),
            ),
            _buildTopRightSettings(),
            _buildBottomRightSOS(),
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
        ),
      ),
    );
  }

  Widget _buildPermissionOverlay() {
    final bool hasError = _cameraError != null && _cameraError!.isNotEmpty;
    final String message = hasError
        ? _cameraError!
        : 'Grant camera access to start scanning signboards.';
    final String buttonLabel = hasError ? 'Retry' : 'Grant Access';

    return Center(
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 24),
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.92),
          borderRadius: BorderRadius.circular(24),
          boxShadow: const [
            BoxShadow(color: Colors.black26, blurRadius: 18, offset: Offset(0, 10)),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.visibility, color: hasError ? const Color(0xFFCC0000) : const Color(0xFF1A1A1A), size: 36),
            const SizedBox(height: 12),
            Text(
              'Welcome to DrishtiAI',
              textAlign: TextAlign.center,
              style: GoogleFonts.outfit(
                fontSize: 22,
                fontWeight: FontWeight.w700,
                color: const Color(0xFF1A1A1A),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: GoogleFonts.outfit(
                fontSize: 16,
                fontWeight: FontWeight.w500,
                color: hasError ? const Color(0xFFB00020) : const Color(0xFF4A4A4A),
              ),
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: _startOcrPipeline,
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF1A1A1A),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
              ),
              child: Text(
                buttonLabel,
                style: GoogleFonts.outfit(fontSize: 16, fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
      ),
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

  Widget _buildGuidanceOverlay() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.75),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFB3D4FF).withValues(alpha: 0.9), width: 1),
      ),
      child: Row(
        children: [
          const Icon(Icons.center_focus_strong, color: Color(0xFFB3D4FF), size: 22),
          const SizedBox(width: 12),
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
        ResolutionPreset.high,
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
        _focusStableSince = DateTime.fromMillisecondsSinceEpoch(0);
        _detectedAnnounced = false;
      });
      _lastFocusRect = null;
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

  Rect? _mergeBoundingBoxes(List<RecognizedText> results) {
    Rect? merged;
    for (final result in results) {
      for (final block in result.blocks) {
        final box = block.boundingBox;
        merged = merged == null ? box : merged.expandToInclude(box);
      }
    }
    return merged;
  }

  Rect? _largestTextRect(List<RecognizedText> results) {
    Rect? best;
    double bestArea = 0;
    for (final result in results) {
      for (final block in result.blocks) {
        final box = block.boundingBox;
        final area = box.width * box.height;
        if (area > bestArea) {
          bestArea = area;
          best = box;
        }
      }
    }
    return best;
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
    } else if (_isCapturing) {
      title = 'Reading signboard...';
      body = 'Hold steady while I capture the text.';
      accentColor = const Color(0xFFB3D4FF);
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
    if (_isProcessingFrame || _isCapturing) return;
    if (!mounted || _currentState != HomeState.scanning) return;
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
      final mergedRect = _mergeBoundingBoxes(results);
      final primaryRect = _largestTextRect(results) ?? mergedRect;
      _handleOcrResult(mergedText, image, primaryRect);
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

  void _handleOcrResult(String text, CameraImage image, Rect? mergedRect) {
    final now = DateTime.now();
    final imageSize = Size(image.width.toDouble(), image.height.toDouble());

    if (mergedRect == null) {
      _resetFocusStability();
      _maybeProvideGuidance(null, imageSize, false);
      if (mounted) {
        setState(() {
          _latestOcrText = '';
        });
      }
      return;
    }

    if (mounted) {
      setState(() {
        _latestOcrText = text.trim();
      });
    }

    final bool isCentered = _isCentered(mergedRect, imageSize);
    final bool isStable = _updateFocusStability(mergedRect, imageSize, now);
    _maybeProvideGuidance(mergedRect, imageSize, isCentered);

    final double areaRatio =
        (mergedRect.width * mergedRect.height) / (imageSize.width * imageSize.height);
    if (isStable &&
        isCentered &&
        areaRatio >= 0.03 &&
        now.difference(_lastCaptureTime) >= _captureCooldown) {
      unawaited(_announceAndCaptureFromFrame(image, mergedRect, imageSize, text));
    }
  }

  Future<void> _maybeSendToGemini(
    String filteredText,
    Uint8List jpegBytes,
  ) async {
    if (_geminiInFlight) return;
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

    if (!_geminiService.hasApiKey) {
      debugPrint('GEMINI_API_KEY not set. Skipping Gemini.');
      await _maybeSpeakOcrFallback(filteredText);
      return;
    }

    final now = DateTime.now();
    if (now.difference(_lastGeminiCall) < _geminiCooldown) {
      if (now.difference(_lastSpokenTime) > const Duration(seconds: 8)) {
        await _maybeSpeakOcrFallback(filteredText);
      }
      return;
    }

    final filteredNormalized = _normalizeText(filteredText);
    if (_lastGeminiText.isNotEmpty &&
        _jaccardSimilarity(filteredNormalized, _lastGeminiText) >= 0.9 &&
        now.difference(_lastGeminiCall) < const Duration(seconds: 12)) {
      return;
    }

    _geminiInFlight = true;
    _lastGeminiCall = now;
    _lastGeminiText = filteredNormalized;

    try {
      final result = await _geminiService.analyze(
        ocrText: filteredText,
        jpegBytes: jpegBytes,
        preferredLanguage: _preferredLanguageLabel(),
      );
      if (result == null) {
        await _maybeSpeakOcrFallback(filteredText);
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
      if (speak.isEmpty) {
        await _maybeSpeakOcrFallback(filteredText);
        return;
      }
      debugPrint('Gemini speak: $speak');
      if (!_soundEnabled) {
        return;
      }
      await _speakGeminiText(speak);
    } catch (error) {
      debugPrint('Gemini error: $error');
      await _maybeSpeakOcrFallback(filteredText);
    } finally {
      _geminiInFlight = false;
    }
  }

  void _resetFocusStability() {
    _focusStableSince = DateTime.fromMillisecondsSinceEpoch(0);
    _lastFocusRect = null;
    _detectedAnnounced = false;
  }

  bool _updateFocusStability(Rect rect, Size imageSize, DateTime now) {
    if (_lastFocusRect == null) {
      _lastFocusRect = rect;
      _focusStableSince = now;
      _detectedAnnounced = false;
      return false;
    }

    final double iou = _rectIoU(_lastFocusRect!, rect);
    if (iou < 0.5) {
      _focusStableSince = now;
      _detectedAnnounced = false;
    }

    _lastFocusRect = rect;
    final Duration requiredHold = _isCentered(rect, imageSize)
        ? _captureHoldDuration
        : const Duration(milliseconds: 1400);
    return now.difference(_focusStableSince) >= requiredHold;
  }

  double _rectIoU(Rect a, Rect b) {
    final double xA = a.left > b.left ? a.left : b.left;
    final double yA = a.top > b.top ? a.top : b.top;
    final double xB = a.right < b.right ? a.right : b.right;
    final double yB = a.bottom < b.bottom ? a.bottom : b.bottom;

    final double interWidth = (xB - xA).clamp(0.0, double.infinity);
    final double interHeight = (yB - yA).clamp(0.0, double.infinity);
    final double interArea = interWidth * interHeight;
    if (interArea <= 0) return 0.0;

    final double areaA = a.width * a.height;
    final double areaB = b.width * b.height;
    final double unionArea = areaA + areaB - interArea;
    if (unionArea <= 0) return 0.0;
    return interArea / unionArea;
  }

  Future<void> _announceAndCaptureFromFrame(
    CameraImage image,
    Rect focusRect,
    Size imageSize,
    String ocrText,
  ) async {
    if (_isCapturing || _detectedAnnounced) return;
    _detectedAnnounced = true;
    if (_soundEnabled) {
      unawaited(_voiceAssistant.speak('Signboard detected. Capturing.'));
    }
    await _captureFromFrame(image, focusRect, imageSize, ocrText);
  }

  bool _isCentered(Rect rect, Size imageSize) {
    // Check if the signboard size is reasonable (not too small, not too huge)
    final areaRatio = (rect.width * rect.height) / (imageSize.width * imageSize.height);
    if (areaRatio < 0.015 || areaRatio > 0.95) {
      return false;
    }
    
    // Normalized distance from center (0.0 to 1.0 scale)
    final dx = ((rect.center.dx - imageSize.width / 2) / (imageSize.width / 2)).abs();
    final dy = ((rect.center.dy - imageSize.height / 2) / (imageSize.height / 2)).abs();
    
    // Requirements for "centered": within 25% of the frame's center
    return dx <= 0.25 && dy <= 0.25;
  }

  Future<void> _captureFromFrame(
    CameraImage image,
    Rect focusRect,
    Size imageSize,
    String ocrText,
  ) async {
    if (_isCapturing) return;
    _isCapturing = true;
    _lastCaptureTime = DateTime.now();
    if (mounted) {
      setState(() {
        _latestSmartText = '';
        _latestSmartEmpty = false;
        _latestGeminiError = null;
      });
    }

    try {
      final filteredText = _filterOcrText(ocrText);
      if (filteredText.isEmpty) {
        await _maybeSpeakOcrFallback(ocrText);
        return;
      }

      final jpegBytes =
          _buildGeminiImage(image, focusRect: focusRect, imageSize: imageSize);
      if (jpegBytes == null) {
        await _maybeSpeakOcrFallback(filteredText);
        return;
      }
      await _maybeSendToGemini(filteredText, jpegBytes);
    } catch (error) {
      debugPrint('Virtual capture error: $error');
      if (mounted) {
        setState(() {
          _latestGeminiError = 'Unable to capture signboard.';
        });
      }
    } finally {
      _isCapturing = false;
      _detectedAnnounced = false;
    }
  }

  Uint8List? _buildGeminiImage(
    CameraImage image, {
    Rect? focusRect,
    Size? imageSize,
  }) {
    if (Platform.isIOS && image.format.group == ImageFormatGroup.bgra8888) {
      return _buildJpegFromBgra(image, focusRect: focusRect, imageSize: imageSize);
    }
    if (Platform.isAndroid) {
      return _buildJpegFromYuv420(image, focusRect: focusRect, imageSize: imageSize);
    }
    return null;
  }

  Uint8List? _buildJpegFromBgra(
    CameraImage image, {
    Rect? focusRect,
    Size? imageSize,
  }) {
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
    final cropped = _maybeCrop(rgbImage, focusRect, imageSize);
    return Uint8List.fromList(img.encodeJpg(cropped, quality: 75));
  }

  Uint8List? _buildJpegFromYuv420(
    CameraImage image, {
    Rect? focusRect,
    Size? imageSize,
  }) {
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

    final cropped = _maybeCrop(rgbImage, focusRect, imageSize);
    return Uint8List.fromList(img.encodeJpg(cropped, quality: 70));
  }



  img.Image _maybeCrop(
    img.Image source,
    Rect? focusRect,
    Size? imageSize,
  ) {
    if (focusRect == null || imageSize == null) return source;

    final double areaRatio =
        (focusRect.width * focusRect.height) / (imageSize.width * imageSize.height);
    if (areaRatio < 0.02 || areaRatio > 0.9) {
      return source;
    }

    final double scaleX = source.width / imageSize.width;
    final double scaleY = source.height / imageSize.height;

    final int left = (focusRect.left * scaleX).round().clamp(0, source.width - 1);
    final int top = (focusRect.top * scaleY).round().clamp(0, source.height - 1);
    final int right =
        (focusRect.right * scaleX).round().clamp(left + 1, source.width);
    final int bottom =
        (focusRect.bottom * scaleY).round().clamp(top + 1, source.height);

    int width = right - left;
    int height = bottom - top;

    // Expand slightly to include context.
    final int padX = (width * 0.15).round();
    final int padY = (height * 0.15).round();
    final int newLeft = (left - padX).clamp(0, source.width - 1);
    final int newTop = (top - padY).clamp(0, source.height - 1);
    final int newRight = (right + padX).clamp(newLeft + 1, source.width);
    final int newBottom = (bottom + padY).clamp(newTop + 1, source.height);

    width = newRight - newLeft;
    height = newBottom - newTop;

    if (width <= 0 || height <= 0) return source;

    try {
      return img.copyCrop(
        source,
        x: newLeft,
        y: newTop,
        width: width,
        height: height,
      );
    } catch (_) {
      return source;
    }
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
    try {
      await _voiceAssistant.speak(text);
    } catch (error) {
      debugPrint('TTS error: $error');
      if (mounted) {
        setState(() {
          _latestGeminiError = 'TTS error: ${error.toString()}';
        });
      }
    }
  }

  String _formatOcrForSpeech(String text) {
    final lines = _extractUsefulLines(text);
    if (lines.isEmpty) return '';
    final merged = lines.join(', ');
    return _truncateText(merged, maxChars: 320);
  }

  Future<void> _maybeSpeakOcrFallback(String text) async {
    final speakText = _formatOcrForSpeech(text);
    if (speakText.isEmpty) {
      if (mounted) {
        setState(() {
          _latestSmartText = '';
          _latestSmartEmpty = true;
          _latestGeminiError = null;
        });
      }
      return;
    }
    if (mounted) {
      setState(() {
        _latestSmartText = speakText;
        _latestSmartEmpty = false;
        _latestGeminiError = null;
      });
    }
    if (!_soundEnabled) return;
    await _speakGeminiText(speakText);
  }

  String _filterOcrText(String text) {
    return _extractUsefulLines(text).join('\n');
  }

  List<String> _extractUsefulLines(String text) {
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
      if (filtered.length >= 30) break;
    }
    return filtered;
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
    final alphaCount =
        RegExp(r'[A-Za-z\u0900-\u097F\u0B80-\u0BFF]').allMatches(line).length;
    final digitCount = RegExp(r'\d').allMatches(line).length;
    if (line.isNotEmpty && (alphaCount / line.length) < 0.3 && digitCount < 4) {
      return true;
    }
    if (line.length <= 4 && digitCount == 0) {
      final hasVowel =
          RegExp(r'[AEIOUaeiou\u0904-\u0914\u0B85-\u0B94]').hasMatch(line);
      final isAllCaps = RegExp(r'^[A-Z]{2,4}$').hasMatch(line);
      if (!hasVowel && !isAllCaps) {
        return true;
      }
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

  String _preferredLanguageLabel() {
    switch (_selectedLanguage) {
      case 'Hindi':
        return 'Hindi';
      case 'Tamil':
        return 'Tamil';
      case 'Marathi':
        return 'Marathi';
      case 'English':
        return 'English';
      default:
        return 'Auto';
    }
  }

  String _truncateText(String text, {int maxChars = 160}) {
    if (text.length <= maxChars) return text;
    return '${text.substring(0, maxChars).trimRight()}...';
  }

  void _maybeProvideGuidance(Rect? rect, Size imageSize, bool isCentered) {
    final bool allowSpeak = _soundEnabled;
    if (rect == null) {
      _holdAnnounced = false;
      if (_currentGuidanceText.isNotEmpty && mounted) {
        setState(() => _currentGuidanceText = '');
      }
      return;
    }
    if (_isCapturing || _geminiInFlight) return;

    final now = DateTime.now();
    if (now.difference(_lastGuidanceTime) < _guidanceCooldown) return;

    String? guidance;

    if (isCentered) {
      if (!_holdAnnounced) {
        guidance = 'Centered. Hold still.';
        _holdAnnounced = true;
      }
    } else {
      _holdAnnounced = false;
      final dx = (rect.center.dx - imageSize.width / 2) / (imageSize.width / 2);
      final dy = (rect.center.dy - imageSize.height / 2) / (imageSize.height / 2);
      final areaRatio = (rect.width * rect.height) / (imageSize.width * imageSize.height);

      if (areaRatio < 0.015) {
        guidance = 'Move closer.';
      } else if (dx > 0.3) {
        guidance = 'Move left.';
      } else if (dx < -0.3) {
        guidance = 'Move right.';
      } else if (dy > 0.3) {
        guidance = 'Move down.';
      } else if (dy < -0.3) {
        guidance = 'Move up.';
      } else {
        guidance = 'Center the signboard.';
      }
    }

    if (guidance == null) {
      if (_currentGuidanceText.isNotEmpty && mounted) {
        setState(() => _currentGuidanceText = '');
      }
      return;
    }
    if (guidance == _lastGuidanceText) return;

    _lastGuidanceText = guidance;
    _lastGuidanceTime = now;
    if (mounted) {
      setState(() => _currentGuidanceText = guidance!);
    }
    if (allowSpeak) {
      unawaited(_speakGuidance(guidance));
    }
  }

  Future<void> _speakGuidance(String text) async {
    try {
      await _voiceAssistant.speak(text);
    } catch (_) {
      // Ignore guidance TTS errors
    }
  }

  double _jaccardSimilarity(String a, String b) {
    final aTokens = a.split(' ').where((token) => token.isNotEmpty).toSet();
    final bTokens = b.split(' ').where((token) => token.isNotEmpty).toSet();
    if (aTokens.isEmpty || bTokens.isEmpty) return 0;
    final intersection = aTokens.intersection(bTokens).length;
    final union = aTokens.union(bTokens).length;
    return union == 0 ? 0 : intersection / union;
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
                top: 24,
                left: 24,
                right: 24,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'Settings',
                        style: GoogleFonts.outfit(
                          fontSize: 28,
                          fontWeight: FontWeight.bold,
                          color: const Color(0xFF1A1A1A),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close, size: 32, color: Color(0xFF1A1A1A)),
                        onPressed: () => Navigator.pop(context),
                        constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),
                  // Language Selector
                  Text(
                    'Language',
                    style: GoogleFonts.outfit(
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                      color: const Color(0xFF1A1A1A),
                    ),
                  ),
                  const SizedBox(height: 8),
                  DropdownButtonFormField<String>(
                    value: _selectedLanguage,
                    items: ['English', 'Hindi', 'Tamil'].map((lang) {
                      return DropdownMenuItem(
                        value: lang,
                        child: Text(lang, style: const TextStyle(fontSize: 18)),
                      );
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
                  Text(
                    'Emergency Contact',
                    style: GoogleFonts.outfit(
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                      color: const Color(0xFF1A1A1A),
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextFormField(
                    decoration: const InputDecoration(
                      labelText: 'Name',
                      hintText: 'e.g. John Doe',
                    ),
                    style: const TextStyle(fontSize: 18, color: Color(0xFF1A1A1A)),
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    decoration: const InputDecoration(
                      labelText: 'Phone Number',
                      hintText: 'e.g. +1234567890',
                    ),
                    keyboardType: TextInputType.phone,
                    style: const TextStyle(fontSize: 18, color: Color(0xFF1A1A1A)),
                  ),
                  const SizedBox(height: 24),
                  // Sound Toggle
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      'Audio Feedback',
                      style: GoogleFonts.outfit(
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                        color: const Color(0xFF1A1A1A),
                      ),
                    ),
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








