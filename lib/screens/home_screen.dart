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
import 'package:url_launcher/url_launcher.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config/config.dart';
import '../services/voice_assistant_service.dart';
import '../services/gemini_service.dart';
import '../services/person_recognition_service.dart';
import '../services/yolo_detector_service.dart';

enum HomeState { idle, permission, scanning }

class _DetectionHistory {
  _DetectionHistory({
    required this.rect,
    required this.seenAt,
    required this.streak,
  });

  Rect rect;
  DateTime seenAt;
  int streak;
}

class _OcrLine {
  const _OcrLine(this.text, this.rect);

  final String text;
  final Rect rect;
}

class _MenuItem {
  _MenuItem(this.name, this.price, this.currency);

  final String name;
  final double price;
  final String currency;
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
  late final PersonRecognitionService _personRecognitionService;
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
  DateTime _lastOcrTime = DateTime.fromMillisecondsSinceEpoch(0);
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
  bool _personRecognitionInFlight = false;
  bool _latestSmartEmpty = false;
  String _latestPersonMessage = '';
  String? _personRecognitionError;
  DateTime _lastPersonRecognitionTime = DateTime.fromMillisecondsSinceEpoch(0);
  Uint8List? _latestRegistrationFrame;
  DateTime _latestRegistrationFrameAt = DateTime.fromMillisecondsSinceEpoch(0);
  bool _personRegistrationInFlight = false;
  bool _conversationModeEnabled = false;
  bool _conversationInFlight = false;
  String? _pendingConversationQuestion;
  bool _intentModeEnabled = false;
  bool _intentInFlight = false;
  String? _pendingIntentQuery;
  String? _activeIntentQuery;
  DateTime _lastIntentCall = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastIntentSpokenTime = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastIntentMapsLaunchAt = DateTime.fromMillisecondsSinceEpoch(0);
  String _lastIntentKey = '';
  String _lastIntentMapsQuery = '';
  String _lastIntentOcrText = '';
  String? _pendingCallNumber;
  bool _callPromptInFlight = false;
  DateTime _lastCallPromptAt = DateTime.fromMillisecondsSinceEpoch(0);
  String _emergencyContactName = '';
  String _emergencyContactNumber = '';

  static const String _prefEmergencyNameKey = 'emergency_contact_name';
  static const String _prefEmergencyNumberKey = 'emergency_contact_number';
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

  static const Duration _analysisInterval = Duration(milliseconds: 250);
  static const Duration _ocrInterval = Duration(milliseconds: 650);
  static const Duration _emitCooldown = Duration(milliseconds: 1500);
  static const Duration _speechCooldown = Duration(seconds: 4);
  static const Duration _alertSpeakCooldown = Duration(seconds: 4);
  static const Duration _signboardPriorityWindow = Duration(seconds: 5);
  static const Duration _geminiCooldown = Duration(seconds: 6);
  static const Duration _conversationRearmDelay = Duration(milliseconds: 300);
  static const Duration _intentCooldown = Duration(seconds: 4);
  static const Duration _intentScanInterval = Duration(milliseconds: 900);
  static const Duration _intentMapsLaunchCooldown = Duration(seconds: 8);
  static const Duration _callPromptCooldown = Duration(seconds: 20);
  static const Map<String, String> _intentCategoryNames = {
    'medical': 'Medical store',
    'hospital': 'Hospital',
    'restaurant': 'Restaurant',
    'grocery': 'Grocery store',
    'bank': 'Bank',
    'hotel': 'Hotel',
    'school': 'School',
    'temple': 'Temple',
    'mosque': 'Mosque',
    'church': 'Church',
    'police': 'Police station',
    'fuel': 'Fuel station',
  };
  static const Map<String, List<String>> _intentKeywordHints = {
    'medical': ['medical', 'pharmacy', 'chemist', 'drug', 'drugs', 'medicine', 'pharma'],
    'hospital': ['hospital', 'clinic', 'emergency', 'er', 'casualty'],
    'restaurant': ['restaurant', 'cafe', 'caf├⌐', 'dhaba', 'eatery', 'food', 'tiffin', 'hotel'],
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
  static const Duration _yoloInterval = Duration(milliseconds: 1200);
  static const int _yoloFrameStride = 5;
  static const int _indoorFrameStride = 6;
  static const int _indoorFrameOffset = 2;
  static const Duration _signboardInterval = Duration(milliseconds: 350);
  static const int _signboardFrameStride = 2;
  static const int _signboardFrameOffset = 1;
  static const Duration _signboardSpeakCooldown = Duration(seconds: 6);
  static const Duration _signboardLandmarkHold = Duration(seconds: 2);
  static const double _signboardLandmarkSmoothing = 0.6;
  int _frameIndex = 0;
  static const double _roadMinConfidence = 0.45;
  static const double _indoorMinConfidence = 0.5;
  static const double _roadIndoorContextMinConfidence = 0.8;
  static const double _roadNoContextMinConfidence = 0.75;
  static const double _hazardSpeakDistanceMeters = 5.0;
  static const int _alertStreakTarget = 3;
  final Map<String, int> _alertStreaks = {};
  static const Duration _indoorContextHold = Duration(seconds: 3);
  DateTime _indoorContextUntil = DateTime.fromMillisecondsSinceEpoch(0);
  static const Duration _roadContextHold = Duration(seconds: 2);
  DateTime _roadContextUntil = DateTime.fromMillisecondsSinceEpoch(0);
  static const Duration _stabilityWindow = Duration(milliseconds: 1200);
  static const double _stabilityIoU = 0.4;
  static const int _stabilityTarget = 3;
  final Map<String, _DetectionHistory> _indoorHistory = {};
  final Map<String, _DetectionHistory> _roadHistory = {};

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

  static const Set<String> _roadContextLabels = {
    'road',
    'drivable',
    'non_drivable',
    'lane',
    'lanemarking',
    'sidewalk',
    'crosswalk',
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

  static const List<double> _defaultDistanceBuckets = [2.0, 4.0, 5.0];

  static const Map<String, List<double>> _distanceBucketsByLabel = {
    'vehicle': [2.5, 4.0, 5.0],
    'living': [2.0, 3.5, 5.0],
    'roadside': [2.5, 4.0, 5.0],
    'electricpole': [2.5, 4.0, 5.0],
    'powerpole': [2.5, 4.0, 5.0],
    'streetlight': [2.5, 4.0, 5.0],
    'door': [1.5, 3.0, 5.0],
    'openeddoor': [1.5, 3.0, 5.0],
    'cabinetdoor': [1.2, 2.5, 4.0],
    'refrigeratordoor': [1.2, 2.5, 4.0],
    'window': [1.5, 3.0, 5.0],
    'chair': [1.2, 2.5, 4.0],
    'table': [1.2, 2.5, 4.0],
    'cabinet': [1.2, 2.5, 4.0],
    'couch': [1.2, 2.5, 4.0],
    'pole': [2.5, 4.0, 5.0],
    'vehiclehazard': [2.5, 4.0, 5.0],
    'humannearby': [2.0, 3.5, 5.0],
    'animalhazard': [2.0, 3.5, 5.0],
    'roadhazard': [2.0, 3.5, 5.0],
    'roadsideobstacle': [2.5, 4.0, 5.0],
  };

  static const Map<String, double> _indoorMinAreaRatio = {
    'door': 0.06,
    'openeddoor': 0.06,
    'cabinetdoor': 0.04,
    'refrigeratordoor': 0.04,
    'window': 0.03,
    'chair': 0.012,
    'table': 0.015,
    'cabinet': 0.03,
    'couch': 0.03,
    'pole': 0.025,
  };

  static const Map<String, double> _indoorMinConfidenceByLabel = {
    'door': 0.65,
    'openeddoor': 0.65,
    'cabinetdoor': 0.6,
    'refrigeratordoor': 0.6,
    'window': 0.6,
    'cabinet': 0.6,
    'chair': 0.55,
    'table': 0.55,
    'couch': 0.55,
    'pole': 0.6,
  };

  static const Map<String, double> _roadMinConfidenceByLabel = {
    'vehiclehazard': 0.6,
    'humannearby': 0.55,
    'animalhazard': 0.55,
    'roadhazard': 0.65,
    'roadsideobstacle': 0.55,
  };

  static const Map<String, double> _roadMinAreaRatio = {
    'vehiclehazard': 0.015,
    'humannearby': 0.012,
    'animalhazard': 0.01,
    'roadhazard': 0.015,
    'roadsideobstacle': 0.012,
  };

  static const Map<String, double> _indoorMinAspectRatio = {
    'door': 1.25,
    'openeddoor': 1.25,
    'cabinetdoor': 1.0,
    'refrigeratordoor': 1.2,
  };

  static const Map<String, String> _hindiLabels = {
    'vehicle': 'αñ╡αñ╛αñ╣αñ¿',
    'living': 'αñ╡αÑìαñ»αñòαÑìαññαñ┐',
    'roadside': 'αñ░αÑïαñíαñ╕αñ╛αñçαñí αñ╡αñ╕αÑìαññαÑü',
    'non_drivable': 'αñàαñ╕αÑüαñ░αñòαÑìαñ╖αñ┐αññ αñ╕αññαñ╣',
    'drivable': 'αñ╕αñíαñ╝αñò',
    'far': 'αñªαÑéαñ░ αñòαÑìαñ╖αÑçαññαÑìαñ░',
    'sky': 'αñåαñ╕αñ«αñ╛αñ¿',
    'car': 'αñòαñ╛αñ░',
    'truck': 'αñƒαÑìαñ░αñò',
    'bus': 'αñ¼αñ╕',
    'motorcycle': 'αñ«αÑïαñƒαñ░αñ╕αñ╛αñçαñòαñ┐αñ▓',
    'bicycle': 'αñ╕αñ╛αñçαñòαñ┐αñ▓',
    'scooter': 'αñ╕αÑìαñòαÑéαñƒαñ░',
    'autorickshaw': 'αñæαñƒαÑï',
    'rickshaw': 'αñ░αñ┐αñòαÑìαñ╢αñ╛',
    'pothole': 'αñùαñíαÑìαñóαñ╛',
    'speedbump': 'αñ╕αÑìαñ¬αÑÇαñí αñ¼αÑìαñ░αÑçαñòαñ░',
    'bump': 'αñ╕αÑìαñ¬αÑÇαñí αñ¼αÑìαñ░αÑçαñòαñ░',
    'barricade': 'αñ¼αÑêαñ░αñ┐αñòαÑçαñí',
    'barrier': 'αñ¼αÑêαñ░αñ┐αñ»αñ░',
    'construction': 'αñ¿αñ┐αñ░αÑìαñ«αñ╛αñú αñòαÑìαñ╖αÑçαññαÑìαñ░',
    'cone': 'αñòαÑïαñ¿',
    'electricpole': 'αñ¼αñ┐αñ£αñ▓αÑÇ αñòαñ╛ αñûαñéαñ¡αñ╛',
    'powerpole': 'αñ¼αñ┐αñ£αñ▓αÑÇ αñòαñ╛ αñûαñéαñ¡αñ╛',
    'streetlight': 'αñ╕αÑìαñƒαÑìαñ░αÑÇαñƒ αñ▓αñ╛αñçαñƒ',
    'door': 'αñªαñ░αñ╡αñ╛αñ£αñ╝αñ╛',
    'openeddoor': 'αñûαÑüαñ▓αñ╛ αñªαñ░αñ╡αñ╛αñ£αñ╝αñ╛',
    'cabinetdoor': 'αñòαÑêαñ¼αñ┐αñ¿αÑçαñƒ αñªαñ░αñ╡αñ╛αñ£αñ╝αñ╛',
    'refrigeratordoor': 'αñ½αÑìαñ░αñ┐αñ£ αñòαñ╛ αñªαñ░αñ╡αñ╛αñ£αñ╝αñ╛',
    'chair': 'αñòαÑüαñ░αÑìαñ╕αÑÇ',
    'table': 'αñ«αÑçαñ£',
    'cabinet': 'αñòαÑêαñ¼αñ┐αñ¿αÑçαñƒ',
    'couch': 'αñ╕αÑïαñ½αñ╝αñ╛',
    'pole': 'αñûαñéαñ¡αñ╛',
    'vehiclehazard': 'αñ╡αñ╛αñ╣αñ¿ αñûαññαñ░αñ╛',
    'humannearby': 'αñ╡αÑìαñ»αñòαÑìαññαñ┐ αñ¬αñ╛αñ╕ αñ«αÑçαñé',
    'animalhazard': 'αñ£αñ╛αñ¿αñ╡αñ░ αñûαññαñ░αñ╛',
    'roadhazard': 'αñ╕αñíαñ╝αñò αñûαññαñ░αñ╛',
    'roadsideobstacle': 'αñ╕αñíαñ╝αñò αñòαñ┐αñ¿αñ╛αñ░αÑç αñ¼αñ╛αñºαñ╛',
  };

  static const Map<String, String> _hindiGuidance = {
    'vehicle': 'αñ¼αñ╛αñêαñé αñôαñ░ αñ░αñ╣αÑçαñéαÑñ',
    'living': 'αñ░αñ╛αñ╕αÑìαññαñ╛ αñªαÑçαñéαÑñ',
    'roadside': 'αñ╕αñ╛αñ╡αñºαñ╛αñ¿ αñ░αñ╣αÑçαñéαÑñ',
    'non_drivable': 'αñ╕αñ╛αñ╡αñºαñ╛αñ¿ αñ░αñ╣αÑçαñéαÑñ',
    'car': 'αñ¼αñ╛αñêαñé αñôαñ░ αñ░αñ╣αÑçαñéαÑñ',
    'truck': 'αñ¼αñ╛αñêαñé αñôαñ░ αñ░αñ╣αÑçαñéαÑñ',
    'bus': 'αñ¼αñ╛αñêαñé αñôαñ░ αñ░αñ╣αÑçαñéαÑñ',
    'motorcycle': 'αñ¼αñ╛αñêαñé αñôαñ░ αñ░αñ╣αÑçαñéαÑñ',
    'bicycle': 'αñ¼αñ╛αñêαñé αñôαñ░ αñ░αñ╣αÑçαñéαÑñ',
    'autorickshaw': 'αñ¼αñ╛αñêαñé αñôαñ░ αñ░αñ╣αÑçαñéαÑñ',
    'rickshaw': 'αñ¼αñ╛αñêαñé αñôαñ░ αñ░αñ╣αÑçαñéαÑñ',
    'scooter': 'αñ¼αñ╛αñêαñé αñôαñ░ αñ░αñ╣αÑçαñéαÑñ',
    'pothole': 'αñ╕αñ╛αñ╡αñºαñ╛αñ¿ αñ░αñ╣αÑçαñéαÑñ',
    'speedbump': 'αñºαÑÇαñ░αÑç αñÜαñ▓αÑçαñéαÑñ',
    'bump': 'αñºαÑÇαñ░αÑç αñÜαñ▓αÑçαñéαÑñ',
    'barricade': 'αñ╕αñ╛αñ╡αñºαñ╛αñ¿ αñ░αñ╣αÑçαñéαÑñ',
    'barrier': 'αñ╕αñ╛αñ╡αñºαñ╛αñ¿ αñ░αñ╣αÑçαñéαÑñ',
    'construction': 'αñ╕αñ╛αñ╡αñºαñ╛αñ¿ αñ░αñ╣αÑçαñéαÑñ',
    'cone': 'αñ╕αñ╛αñ╡αñºαñ╛αñ¿ αñ░αñ╣αÑçαñéαÑñ',
    'door': 'αñ╕αñ╛αñ╡αñºαñ╛αñ¿ αñ░αñ╣αÑçαñéαÑñ',
    'openeddoor': 'αñ╕αñ╛αñ╡αñºαñ╛αñ¿ αñ░αñ╣αÑçαñéαÑñ',
    'cabinetdoor': 'αñ╕αñ╛αñ╡αñºαñ╛αñ¿ αñ░αñ╣αÑçαñéαÑñ',
    'refrigeratordoor': 'αñ╕αñ╛αñ╡αñºαñ╛αñ¿ αñ░αñ╣αÑçαñéαÑñ',
    'chair': 'αñ╕αñ╛αñ╡αñºαñ╛αñ¿ αñ░αñ╣αÑçαñéαÑñ',
    'table': 'αñ╕αñ╛αñ╡αñºαñ╛αñ¿ αñ░αñ╣αÑçαñéαÑñ',
    'cabinet': 'αñ╕αñ╛αñ╡αñºαñ╛αñ¿ αñ░αñ╣αÑçαñéαÑñ',
    'couch': 'αñ╕αñ╛αñ╡αñºαñ╛αñ¿ αñ░αñ╣αÑçαñéαÑñ',
    'pole': 'αñ╕αñ╛αñ╡αñºαñ╛αñ¿ αñ░αñ╣αÑçαñéαÑñ',
    'electricpole': 'αñ╕αñ╛αñ╡αñºαñ╛αñ¿ αñ░αñ╣αÑçαñéαÑñ',
    'powerpole': 'αñ╕αñ╛αñ╡αñºαñ╛αñ¿ αñ░αñ╣αÑçαñéαÑñ',
    'streetlight': 'αñ╕αñ╛αñ╡αñºαñ╛αñ¿ αñ░αñ╣αÑçαñéαÑñ',
    'vehiclehazard': 'αñ¼αñ╛αñêαñé αñôαñ░ αñ░αñ╣αÑçαñéαÑñ',
    'humannearby': 'αñºαÑÇαñ░αÑç αñÜαñ▓αÑçαñéαÑñ',
    'animalhazard': 'αñ╕αñ╛αñ╡αñºαñ╛αñ¿ αñ░αñ╣αÑçαñéαÑñ',
    'roadhazard': 'αñ╕αñ╛αñ╡αñºαñ╛αñ¿ αñ░αñ╣αÑçαñéαÑñ',
    'roadsideobstacle': 'αñ╕αñ╛αñ╡αñºαñ╛αñ¿ αñ░αñ╣αÑçαñéαÑñ',
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
    _personRecognitionService = PersonRecognitionService();
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
    unawaited(_loadEmergencyContact());
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
    _personRecognitionService.dispose();
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
            _buildTopRightEmergencyCall(),
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
      right: 72,
      child: IconButton(
        icon: const Icon(Icons.settings, size: 32),
        color: _currentState == HomeState.scanning ? Colors.white : const Color(0xFF1A1A1A),
        tooltip: 'Settings',
        onPressed: _showSettingsBottomSheet,
        constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
      ),
    );
  }

  Widget _buildTopRightEmergencyCall() {
    if (_emergencyContactNumber.trim().isEmpty) {
      return const SizedBox.shrink();
    }
    return Positioned(
      top: 16,
      right: 16,
      child: IconButton(
        icon: const Icon(Icons.call_rounded, size: 30),
        color: const Color(0xFFCC0000),
        tooltip: 'Emergency Call',
        onPressed: () {
          unawaited(_launchCall(_emergencyContactNumber));
        },
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
        _conversationModeEnabled = false;
        _conversationInFlight = false;
        _pendingConversationQuestion = null;
        _intentModeEnabled = false;
        _intentInFlight = false;
        _pendingIntentQuery = null;
        _activeIntentQuery = null;
        _lastIntentCall = DateTime.fromMillisecondsSinceEpoch(0);
        _lastIntentSpokenTime = DateTime.fromMillisecondsSinceEpoch(0);
        _lastIntentMapsLaunchAt = DateTime.fromMillisecondsSinceEpoch(0);
        _lastIntentKey = '';
        _lastIntentMapsQuery = '';
        _pendingCallNumber = null;
        _callPromptInFlight = false;
        _lastCallPromptAt = DateTime.fromMillisecondsSinceEpoch(0);
        _lastIntentOcrText = '';
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
        await _maybeOpenMapsForIntentQuery(trimmed);
      },
    );
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
          if (_pendingCallNumber != null) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Call ${_pendingCallNumber!}?',
                    style: GoogleFonts.outfit(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: Colors.white,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                TextButton(
                  onPressed: () {
                    setState(() {
                      _pendingCallNumber = null;
                    });
                  },
                  child: const Text('No'),
                ),
                ElevatedButton(
                  onPressed: () {
                    final number = _pendingCallNumber;
                    if (number == null) return;
                    setState(() {
                      _pendingCallNumber = null;
                    });
                    unawaited(_launchCall(number));
                  },
                  child: const Text('Call'),
                ),
              ],
            ),
          ],
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
            : ' ΓÇó ${fallback.distanceMeters!.toStringAsFixed(1)}m';
        roadTitle = 'Road detected';
        roadBody =
            '${fallback.label}$distanceText ΓÇó ${(fallback.score * 100).toStringAsFixed(1)}%';
        roadAccentColor = const Color(0xFF9FB0C7);
      }
    } else {
      final top = roadAlerts.first;
      final distanceText = top.distanceMeters == null
          ? ''
          : ' ΓÇó ${top.distanceMeters!.toStringAsFixed(1)}m';
      roadTitle = 'Road alert';
      roadBody =
          '${top.label} ΓÇó ${top.proximity}$distanceText ΓÇó ${(top.score * 100).toStringAsFixed(1)}%';
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
            : ' ΓÇó ${fallback.distanceMeters!.toStringAsFixed(1)}m';
        indoorTitle = 'Indoor detected';
        indoorBody =
            '${fallback.label}$distanceText ΓÇó ${(fallback.score * 100).toStringAsFixed(1)}%';
        indoorAccentColor = const Color(0xFF9FB0C7);
      }
    } else {
      final top = indoorAlerts.first;
      final distanceText = top.distanceMeters == null
          ? ''
          : ' ΓÇó ${top.distanceMeters!.toStringAsFixed(1)}m';
      indoorTitle = 'Indoor alert';
      indoorBody =
          '${top.label} ΓÇó ${top.proximity}$distanceText ΓÇó ${(top.score * 100).toStringAsFixed(1)}%';
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
    final now = DateTime.now();
    final hasRoadContext = now.isBefore(_roadContextUntil);
    final alerts = detections.where((d) {
      final normalized = _normalizeLabelForAlert(d.label);
      final minConfidence = isIndoor
          ? (_indoorMinConfidenceByLabel[normalized] ?? _indoorMinConfidence)
          : (_roadMinConfidenceByLabel[normalized] ?? _roadMinConfidence);
      if (d.score < minConfidence) return false;
      if (!allowedLabels.contains(normalized)) return false;
      if (isIndoor) {
        final minArea = _indoorMinAreaRatio[normalized];
        if (minArea != null && d.areaRatio < minArea) return false;
        if (!_passesAspectRatioForLabel(normalized, d.rect)) return false;
      } else {
        final minArea = _roadMinAreaRatio[normalized];
        if (minArea != null && d.areaRatio < minArea) return false;
        if (!hasRoadContext) {
          return false;
        }
      }
      if (!isIndoor && now.isBefore(_indoorContextUntil)) {
        if (d.score < _roadIndoorContextMinConfidence) return false;
        return false;
      }
      if (d.distanceMeters != null) {
        return d.distanceMeters! <= _hazardSpeakDistanceMeters;
      }
      return d.proximity == 'near' || d.proximity == 'urgent';
    }).toList();
    final stableAlerts = _applyTemporalStability(
      alerts,
      isIndoor ? _indoorHistory : _roadHistory,
    );
    if (isIndoor && stableAlerts.isNotEmpty) {
      _indoorContextUntil = now.add(_indoorContextHold);
    }
    stableAlerts.sort((a, b) {
      final da = a.distanceMeters;
      final db = b.distanceMeters;
      if (da != null && db != null) {
        return da.compareTo(db);
      }
      if (da != null) return -1;
      if (db != null) return 1;
      return b.score.compareTo(a.score);
    });
    return stableAlerts;
  }

  String _normalizeLabelForAlert(String label) {
    final lowered = label.trim().toLowerCase();
    return lowered.replaceAll(RegExp(r'[^a-z0-9]+'), '');
  }

  bool _passesAspectRatioForLabel(String normalized, Rect rect) {
    final minRatio = _indoorMinAspectRatio[normalized];
    if (minRatio == null) return true;
    if (rect.width <= 0 || rect.height <= 0) return false;
    final ratio = rect.height / rect.width;
    return ratio >= minRatio;
  }

  List<YoloDetection> _applyTemporalStability(
    List<YoloDetection> detections,
    Map<String, _DetectionHistory> history,
  ) {
    if (detections.isEmpty) return <YoloDetection>[];
    final now = DateTime.now();
    history.removeWhere((_, value) => now.difference(value.seenAt) > _stabilityWindow);
    final stable = <YoloDetection>[];
    for (final det in detections) {
      final key = _normalizeLabelForAlert(det.label);
      final prev = history[key];
      int streak = 1;
      if (prev != null && now.difference(prev.seenAt) <= _stabilityWindow) {
        final iou = _rectIoU(prev.rect, det.rect);
        if (iou >= _stabilityIoU) {
          streak = prev.streak + 1;
        }
      }
      history[key] = _DetectionHistory(rect: det.rect, seenAt: now, streak: streak);
      if (streak >= _stabilityTarget) {
        stable.add(det);
      }
    }
    return stable;
  }

  double _rectIoU(Rect a, Rect b) {
    if (!a.overlaps(b)) return 0.0;
    final intersect = a.intersect(b);
    final intersectArea = intersect.width * intersect.height;
    final unionArea = a.width * a.height + b.width * b.height - intersectArea;
    if (unionArea <= 0) return 0.0;
    return intersectArea / unionArea;
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
    final candidates = <_OcrLine>[];
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
        for (final line in block.lines) {
          final box = line.boundingBox;
          if (box == null) continue;
          final bestRect = bestRectFor(box, 0.12);
          if (bestRect == null) continue;
          final heightRatio = box.height / bestRect.height;
          if (heightRatio < 0.02 || heightRatio > 0.95) continue;
          final raw = line.text.trim();
          if (raw.isEmpty) continue;
          if (!_lineLooksValid(raw)) continue;
          final key = _normalizeText(raw);
          if (key.isEmpty || !seen.add(key)) continue;
          candidates.add(_OcrLine(raw, box));
        }
      }
    }

    if (candidates.isEmpty) {
      for (final result in results) {
        for (final block in result.blocks) {
          final box = block.boundingBox;
          if (box == null) continue;
          final bestRect = bestRectFor(box, 0.12);
          if (bestRect == null) continue;
          final heightRatio = box.height / bestRect.height;
          if (heightRatio < 0.02 || heightRatio > 0.95) continue;
          final raw = block.text.trim();
          if (raw.isEmpty) continue;
          if (!_lineLooksValid(raw)) continue;
          final key = _normalizeText(raw);
          if (key.isEmpty || !seen.add(key)) continue;
          candidates.add(_OcrLine(raw, box));
        }
      }
    }

    candidates.sort((a, b) {
      final dy = (a.rect.top - b.rect.top).abs();
      if (dy > 12) {
        return a.rect.top.compareTo(b.rect.top);
      }
      return a.rect.left.compareTo(b.rect.left);
    });

    final text = candidates.map((line) => line.text).join(' ').trim();
    return _shortenSignboardText(_cleanSignboardText(text));
  }

  List<Rect> _getActiveSignboardRects(List<YoloDetection> signboards) {
    if (signboards.isNotEmpty) {
      return signboards.map((d) => _expandRect(d.rect, 0.22)).toList();
    }
    final now = DateTime.now();
    if (_signboardLandmark == null) return const [];
    if (now.difference(_signboardLandmarkAt) > _signboardLandmarkHold) {
      return const [];
    }
    return [_expandRect(_signboardLandmark!, 0.28)];
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
    if (words.length <= 30) return cleaned;
    return words.take(30).join(' ');
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
    if (ratio < 0.35) return false;
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
      return 'αñ╕αñ╛αñçαñ¿αñ¼αÑïαñ░αÑìαñí: $text, $hindiDistance $hindiDirection αñ╣αÑêαÑñ';
    }
    return 'Signboard: $text, $distanceWord $directionPhrase.';
  }

  Future<void> _speakSignboard(String text, YoloDetection detection) async {
    if (_conversationModeEnabled) return;
    // When intent mode is active, let the intent announcer speak instead.
    if (_intentModeEnabled && _activeIntentQuery != null) return;
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
    final base = '$label $distanceWord $directionPhrase αñ╣αÑêαÑñ';
    if (guidance == null) return base;
    return '$base $guidance';
  }

  String _hindiDirection(String direction) {
    switch (direction) {
      case 'left':
        return 'αñ¼αñ╛αñêαñé αñôαñ░';
      case 'right':
        return 'αñªαñ╛αñêαñé αñôαñ░';
      default:
        return 'αñ╕αñ╛αñ«αñ¿αÑç';
    }
  }

  String _hindiDistanceDescriptor(YoloDetection detection, String direction) {
    final distance = detection.distanceMeters;
    final normalized = _normalizeLabelForAlert(detection.label);
    final buckets = _distanceBucketsForLabel(normalized);
    String word;
    if (distance != null) {
      if (distance <= buckets[0]) {
        word = 'αñ¼αñ╣αÑüαññ αñ¬αñ╛αñ╕';
      } else if (distance <= buckets[1]) {
        word = 'αñ¬αñ╛αñ╕';
      } else if (distance <= buckets[2]) {
        word = 'αñåαñùαÑç';
      } else {
        word = 'αñªαÑéαñ░';
      }
    } else {
      switch (detection.proximity) {
        case 'urgent':
          word = 'αñ¼αñ╣αÑüαññ αñ¬αñ╛αñ╕';
          break;
        case 'near':
          word = 'αñ¬αñ╛αñ╕';
          break;
        case 'mid':
          word = 'αñåαñùαÑç';
          break;
        default:
          word = 'αñªαÑéαñ░';
      }
    }
    if (direction != 'ahead' && word == 'αñåαñùαÑç') {
      word = 'αñ¬αñ╛αñ╕';
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
    if (_conversationModeEnabled) return;
    if (!_soundEnabled) return;
    if (_voiceAssistant.isListening.value || _voiceAssistant.isSpeaking.value) return;
    final now = DateTime.now();
    if (now.difference(_lastSignboardSpokenAt) < _signboardPriorityWindow) return;
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
      final forceOcr = _pendingConversationQuestion != null || _intentModeEnabled || !_signboardReady;
      final shouldRunOcr = forceOcr || now.difference(_lastOcrTime) >= _ocrInterval;
      List<RecognizedText> ocrResults = const [];
      var mergedText = _lastIntentOcrText;
      if (shouldRunOcr) {
        final recognizers = _activeRecognizersForCurrentLanguage();
        ocrResults = await Future.wait(recognizers.map((r) => r.processImage(inputImage)));
        mergedText = _mergeRecognizedText(ocrResults);
        _lastOcrTime = now;
      }
      _updateOcrPreview(mergedText);
      if (mergedText.trim().isNotEmpty) {
        _lastIntentOcrText = mergedText.trim();
      }
      final focusRect = _lastSignboardDetection?.rect ?? _signboardLandmark;
      if (_pendingConversationQuestion != null && !_conversationInFlight) {
        final question = _pendingConversationQuestion!;
        _pendingConversationQuestion = null;
        final conversationText = mergedText.trim().isNotEmpty
            ? mergedText
            : _lastIntentOcrText;
        unawaited(_answerConversation(question, conversationText, image));
      }
      if (_intentModeEnabled &&
          _activeIntentQuery != null &&
          !_intentInFlight &&
          !_conversationInFlight &&
          _pendingConversationQuestion == null) {
        final query = _activeIntentQuery!;
        debugPrint('[INTENT] Frame check: mode=enabled query="$query" ocr=${mergedText.length}chars');
        unawaited(_checkIntentMatch(query, mergedText, image, focusRect));
      }
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
              final detections = await _yoloDetector.detect(
                rgbImage,
                confThreshold: 0.4,
              );
              final scaledDetections = _scaleDetectionsToFrame(detections, rgbImage);
              final hasRoadContext = detections.any((d) {
                final normalized = _normalizeLabelForAlert(d.label);
                return _roadContextLabels.contains(normalized);
              });
              if (hasRoadContext) {
                _roadContextUntil = DateTime.now().add(_roadContextHold);
              }
              final darkPatch = hasRoadContext ? _detectDarkPatch(rgbImage) : null;
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
                confThreshold: 0.45,
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
                confThreshold: 0.25,
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
                _lastIntentOcrText = text;
                if (mounted) {
                  setState(() {
                    _latestOcrText = text;
                    _latestSmartText = text;
                    _latestSmartEmpty = false;
                    _latestGeminiError = null;
                  });
                }
                _maybePromptCallFromText(text);
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

  List<TextRecognizer> _activeRecognizersForCurrentLanguage() {
    switch (_selectedLanguage) {
      case 'Hindi':
        return [_latinTextRecognizer, _devanagariTextRecognizer];
      case 'Tamil':
        return [_latinTextRecognizer, _tamilTextRecognizer];
      default:
        return [_latinTextRecognizer];
    }
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
    _maybePromptCallFromText(cleaned);
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
    if (_conversationModeEnabled || _intentModeEnabled) {
      return;
    }
    if (_geminiInFlight) return;
    if (!_geminiService.hasApiKey) {
      debugPrint('GEMINI_API_KEY not set. Skipping Gemini.');
      if (mounted) {
        setState(() {
          _latestGeminiError =
              'Gemini API key missing. Add GEMINI_API_KEY in .env or run with --dart-define=GEMINI_API_KEY=YOUR_KEY';
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

  Future<void> _answerConversation(
    String question,
    String ocrText,
    CameraImage image,
  ) async {
    if (_conversationInFlight) return;
    _conversationInFlight = true;

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
      await _maybeContinueConversation();
      return;
    }

    final localAnswer = _localAnswerFromOcr(question, cleaned);
    if (localAnswer != null && localAnswer.trim().isNotEmpty) {
      if (mounted) {
        setState(() {
          _latestSmartText = localAnswer;
          _latestSmartEmpty = false;
          _latestGeminiError = null;
        });
      }
      if (_soundEnabled) {
        if (_voiceAssistant.isListening.value) {
          await _voiceAssistant.stop();
        }
        await _voiceAssistant.speak(localAnswer);
      }
      _conversationInFlight = false;
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
        final fallback = _localAnswerFromOcr(question, cleaned);
        if (fallback != null && fallback.trim().isNotEmpty) {
          if (mounted) {
            setState(() {
              _latestSmartText = fallback;
              _latestSmartEmpty = false;
              _latestGeminiError = null;
            });
          }
          if (_soundEnabled) {
            if (_voiceAssistant.isListening.value) {
              await _voiceAssistant.stop();
            }
            await _voiceAssistant.speak(fallback);
          }
          _conversationInFlight = false;
          await _maybeContinueConversation();
          return;
        }
        if (mounted) {
          setState(() {
            _latestGeminiError = 'No response from Gemini.';
            _latestSmartText = '';
            _latestSmartEmpty = false;
          });
        }
        _conversationInFlight = false;
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
        if (_voiceAssistant.isListening.value) {
          await _voiceAssistant.stop();
        }
        await _voiceAssistant.speak(speak);
      } else if (_soundEnabled && speak.isEmpty) {
        await _voiceAssistant.speak('I cannot see that answer right now.');
      }
    } catch (error) {
      debugPrint('Conversation error: $error');
      final fallback = _localAnswerFromOcr(question, cleaned);
      if (fallback != null && fallback.trim().isNotEmpty) {
        if (mounted) {
          setState(() {
            _latestSmartText = fallback;
            _latestSmartEmpty = false;
            _latestGeminiError = null;
          });
        }
        if (_soundEnabled) {
          if (_voiceAssistant.isListening.value) {
            await _voiceAssistant.stop();
          }
          await _voiceAssistant.speak(fallback);
        }
        _conversationInFlight = false;
        await _maybeContinueConversation();
        return;
      }
      if (mounted) {
        setState(() {
          _latestGeminiError = 'Gemini error: ${error.toString()}';
          _latestSmartText = '';
          _latestSmartEmpty = false;
        });
      }
    } finally {
      _conversationInFlight = false;
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
    if (_intentInFlight) return;
    final now = DateTime.now();

    // --- Fast OCR-only path (no cooldown restriction, no API key needed) ---
    // Use raw OCR text for intent matching ΓÇö don't over-filter it.
    // Prefer the most recent OCR text captured (signboard-cropped or full frame).
    final fullOcr = ocrText.trim();
    final bestOcr = _lastIntentOcrText.trim().isNotEmpty ? _lastIntentOcrText.trim() : fullOcr;
    if (bestOcr.isNotEmpty) {
      if (_matchesIntentWithOcr(intent, bestOcr)) {
        await _announceIntentMatch(_activeIntentQuery ?? intent, focusRect);
        return;
      }
    }

    // --- Gemini path (rate-limited, requires API key) ---
    if (now.difference(_lastIntentCall) < _intentScanInterval) return;
    if (!_geminiService.hasApiKey) return;
    _lastIntentCall = now;

    final cleaned = bestOcr.isNotEmpty ? bestOcr : fullOcr;
    if (cleaned.isEmpty) {
      debugPrint('[INTENT] No OCR text available for Gemini check');
      return;
    }
    debugPrint('[INTENT] Sending to Gemini: intent="$intent"');
    final filteredText = _filterOcrTextForConversation(cleaned);
    final textForGemini = filteredText.isNotEmpty ? filteredText : cleaned;

    final jpegBytes = _buildGeminiImage(image);
    if (jpegBytes == null) return;

    _intentInFlight = true;

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
    }
  }

  Future<void> _announceIntentMatch(String intentName, Rect? focusRect) async {
    if (_conversationModeEnabled) return;
    final now = DateTime.now();
    final direction = focusRect != null ? _directionForRect(focusRect) : 'ahead';
    final canonical = _canonicalIntentName(intentName);
    final directionPhrase =
        direction == 'ahead' ? 'ahead' : 'on your ${direction}';
    final message = '$canonical detected $directionPhrase';
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

  Future<void> _maybePromptCallFromText(String text) async {
    if (_conversationModeEnabled) return;
    if (_callPromptInFlight) return;
    final now = DateTime.now();
    if (now.difference(_lastCallPromptAt) < _callPromptCooldown) return;
    final number = _bestPhoneCandidate(text);
    if (number == null || number.isEmpty) return;
    if (_pendingCallNumber == number &&
        now.difference(_lastCallPromptAt) < const Duration(seconds: 10)) {
      return;
    }
    _pendingCallNumber = number;
    _lastCallPromptAt = now;
    if (!_soundEnabled) return;
    if (_voiceAssistant.isListening.value || _voiceAssistant.isSpeaking.value) return;
    _callPromptInFlight = true;
    unawaited(Future<void>.delayed(const Duration(seconds: 12), () {
      _callPromptInFlight = false;
    }));
    await _voiceAssistant.requestUserQuery(
      prompt: 'Phone number detected. Do you want to call $number?',
      onUserResponse: (response) async {
        final normalized = response.trim();
        if (_isAffirmative(normalized)) {
          await _launchCall(number);
        }
        _pendingCallNumber = null;
        _callPromptInFlight = false;
      },
    );
  }

  bool _isAffirmative(String text) {
    final lower = text.toLowerCase();
    if (lower.contains('no') || lower.contains('nah') || lower.contains('nahi')) {
      return false;
    }
    return lower.contains('yes') ||
        lower.contains('yeah') ||
        lower.contains('yep') ||
        lower.contains('call') ||
        lower.contains('ok') ||
        lower.contains('haan') ||
        lower.contains('han') ||
        lower.contains('ji');
  }

  String? _bestPhoneCandidate(String text) {
    final lines = text.split('\n');
    String? bestNumber;
    var bestScore = 0;
    for (final line in lines) {
      final candidates = _extractPhoneCandidatesFromLine(line);
      if (candidates.isEmpty) continue;
      final contextBoost = _phoneContextBoost(line);
      for (final raw in candidates) {
        final digits = raw.replaceAll(RegExp(r'\D'), '');
        if (digits.length < 7 || digits.length > 15) continue;
        if (_looksLikePrice(raw, line)) continue;
        var score = 0;
        if (digits.length == 10) {
          score += 4;
        } else if (digits.length >= 11 && digits.length <= 12) {
          score += 3;
        } else {
          score += 1;
        }
        if (raw.trim().startsWith('+')) score += 1;
        score += contextBoost;
        if (score > bestScore) {
          bestScore = score;
          bestNumber = raw.trim().startsWith('+') ? '+$digits' : digits;
        }
      }
    }
    return bestNumber;
  }

  List<String> _extractPhoneCandidatesFromLine(String line) {
    final regex = RegExp(r'(\+?\d[\d\s().-]{6,}\d)');
    return regex.allMatches(line).map((m) => m.group(0) ?? '').toList();
  }

  int _phoneContextBoost(String line) {
    final lower = line.toLowerCase();
    const keywords = ['phone', 'ph', 'tel', 'call', 'mob', 'mobile', 'contact'];
    for (final key in keywords) {
      if (lower.contains(key)) return 2;
    }
    return 0;
  }

  bool _looksLikePrice(String token, String line) {
    final lower = line.toLowerCase();
    if (lower.contains('rs') || lower.contains('inr') || lower.contains('\u20b9') || lower.contains('\$')) {
      final digits = token.replaceAll(RegExp(r'\D'), '');
      if (digits.length <= 6) return true;
    }
    if (token.contains('.') && RegExp(r'\d+\.\d{2}').hasMatch(token)) {
      return true;
    }
    return false;
  }

  Future<void> _launchCall(String number) async {
    final uri = Uri(scheme: 'tel', path: number);
    final canLaunch = await canLaunchUrl(uri);
    if (!canLaunch) {
      if (mounted) {
        setState(() {
          _latestSmartText = 'Unable to place the call.';
          _latestSmartEmpty = false;
        });
      }
      return;
    }
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  Future<void> _loadEmergencyContact() async {
    final prefs = await SharedPreferences.getInstance();
    final storedName = prefs.getString(_prefEmergencyNameKey) ?? '';
    final storedNumber = prefs.getString(_prefEmergencyNumberKey) ?? '';
    final fallbackNumber = EMERGENCY_CONTACT_NUMBER.trim();
    if (!mounted) return;
    setState(() {
      _emergencyContactName = storedName;
      _emergencyContactNumber =
          storedNumber.isNotEmpty ? storedNumber : fallbackNumber;
    });
  }

  Future<void> _saveEmergencyContact(String name, String number) async {
    final normalizedNumber = _normalizePhoneNumber(number);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefEmergencyNameKey, name.trim());
    await prefs.setString(_prefEmergencyNumberKey, normalizedNumber);
    if (!mounted) return;
    setState(() {
      _emergencyContactName = name.trim();
      _emergencyContactNumber = normalizedNumber;
    });
  }

  String _normalizePhoneNumber(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return '';
    final hasPlus = trimmed.startsWith('+');
    final digits = trimmed.replaceAll(RegExp(r'\D'), '');
    if (digits.isEmpty) return '';
    return hasPlus ? '+$digits' : digits;
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
    if (_conversationModeEnabled) return;
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

  String? _localAnswerFromOcr(String question, String ocrText) {
    final q = question.toLowerCase();
    final items = _parseMenuItems(ocrText);
    if (items.isEmpty) return null;

    if (q.contains('cheapest') || q.contains('lowest') || q.contains('least expensive')) {
      final cheapest = items.reduce((a, b) => a.price <= b.price ? a : b);
      return 'The cheapest item is ${cheapest.name} at ${_formatPrice(cheapest)}.';
    }
    if (q.contains('most expensive') || q.contains('costliest') || q.contains('highest')) {
      final costliest = items.reduce((a, b) => a.price >= b.price ? a : b);
      return 'The most expensive item is ${costliest.name} at ${_formatPrice(costliest)}.';
    }

    if (q.contains('price') || q.contains('cost') || q.contains('how much')) {
      final qTokens = q.split(RegExp(r'[^a-z0-9]+')).where((t) => t.length > 2).toSet();
      _MenuItem? best;
      var bestScore = 0;
      for (final item in items) {
        final nameTokens =
            item.name.toLowerCase().split(RegExp(r'[^a-z0-9]+')).where((t) => t.length > 2);
        var score = 0;
        for (final token in nameTokens) {
          if (qTokens.contains(token)) score++;
        }
        if (score > bestScore) {
          bestScore = score;
          best = item;
        }
      }
      if (best != null && bestScore > 0) {
        return '${best.name} costs ${_formatPrice(best)}.';
      }
    }

    return null;
  }

  String _formatPrice(_MenuItem item) {
    final hasDecimals = (item.price - item.price.truncateToDouble()).abs() > 0.001;
    final value = hasDecimals ? item.price.toStringAsFixed(2) : item.price.toStringAsFixed(0);
    if (item.currency == r'$') {
      return '\$$value';
    }
    if (item.currency == 'Γé╣') {
      return '$value rupees';
    }
    return value;
  }

  List<_MenuItem> _parseMenuItems(String ocrText) {
    final lines = ocrText.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).toList();
    final items = <_MenuItem>[];
    final priceRegex = RegExp(r'((?:Γé╣|rs\\.?|inr|\\$)\\s*)?(\\d+(?:[.,]\\d{2})?)', caseSensitive: false);
    final defaultCurrency = _detectCurrency(ocrText);
    String? pendingName;
    for (final line in lines) {
      final matches = priceRegex.allMatches(line).toList();
      final hasLetters = RegExp(r'[A-Za-z]').hasMatch(line);
      if (matches.isNotEmpty) {
        final match = matches.last;
        final currencyToken = (match.group(1) ?? '').trim();
        final rawNumber = (match.group(2) ?? '').replaceAll(',', '.');
        final price = double.tryParse(rawNumber);
        if (price == null) continue;
        var name = line.replaceAll(priceRegex, ' ').replaceAll(RegExp(r'\\s+'), ' ').trim();
        if (name.isEmpty && pendingName != null) {
          name = pendingName;
        }
        if (name.isNotEmpty) {
          final currency = _normalizeCurrency(currencyToken, defaultCurrency);
          items.add(_MenuItem(name, price, currency));
          pendingName = null;
        }
      } else if (hasLetters) {
        pendingName = line;
      }
    }
    return items;
  }

  String _detectCurrency(String text) {
    final lower = text.toLowerCase();
    if (lower.contains(r'$')) return r'$';
    if (lower.contains('?') || lower.contains('rs') || lower.contains('inr')) {
      return 'Γé╣';
    }
    return '';
  }

  String _normalizeCurrency(String token, String fallback) {
    final lower = token.toLowerCase();
    if (lower.contains(r'$')) return r'$';
    if (lower.contains('?') || lower.contains('rs') || lower.contains('inr')) {
      return 'Γé╣';
    }
    return fallback;
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
      final hasCurrency =
          RegExp(r'(rs\.?|inr|\$)', caseSensitive: false).hasMatch(trimmed);

      if (hasLetters || hasDigits || hasCurrency) {
        filtered.add(trimmed);
      }
      if (filtered.length >= 20) break;
    }
    return filtered.join('\n');
  }

  List<String> _intentKeywordsForQuery(String intent) {
    final normalizedIntent = _normalizeText(intent);
    final intentTokens = normalizedIntent
        .split(' ')
        .map((t) => t.trim())
        .where((t) => t.length >= 2)
        .toSet();
    final keywords = <String>{};
    // Add the raw intent tokens themselves
    keywords.addAll(intentTokens);
    // Expand using synonym hints: if any hint keyword matches an intent token,
    // add the full synonym set for that category.
    for (final entry in _intentKeywordHints.entries) {
      final synonyms = entry.value.map(_normalizeText).toList();
      // Check if user said any word from this category's synonym list
      final hasMatch = intentTokens.any((token) =>
          synonyms.any((syn) => syn.contains(token) || token.contains(syn)));
      if (hasMatch) {
        keywords.addAll(synonyms);
        // Also add the category key itself
        keywords.add(_normalizeText(entry.key));
      }
    }
    return keywords.toList();
  }

  bool _matchesIntentWithOcr(String intent, String ocrText) {
    final normalizedText = _normalizeText(ocrText);
    if (normalizedText.isEmpty) return false;
    final keywords = _intentKeywordsForQuery(intent);
    for (final keyword in keywords) {
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
    // Check if any recognized category key appears in the normalized intent.
    for (final entry in _intentCategoryNames.entries) {
      if (normalized.contains(entry.key)) {
        return entry.value;
      }
    }
    // Check synonym lists to map a synonym back to its category name.
    for (final entry in _intentKeywordHints.entries) {
      final synonyms = entry.value.map(_normalizeText).toList();
      if (synonyms.any((syn) => normalized.contains(syn))) {
        return _intentCategoryNames[entry.key] ?? intent.trim();
      }
    }
    return intent.trim();
  }

  Future<void> _maybeOpenMapsForIntentQuery(String intentQuery) async {
    final trimmed = intentQuery.trim();
    if (trimmed.isEmpty) return;

    final mapsQuery = _mapsQueryForIntent(trimmed);
    if (mapsQuery.isEmpty) return;

    final normalizedQuery = _normalizeText(mapsQuery);
    final now = DateTime.now();
    if (_lastIntentMapsQuery == normalizedQuery &&
        now.difference(_lastIntentMapsLaunchAt) < _intentMapsLaunchCooldown) {
      return;
    }

    _lastIntentMapsQuery = normalizedQuery;
    _lastIntentMapsLaunchAt = now;

    final uri = Uri.parse(
      'https://www.google.com/maps/search/?api=1&query=${Uri.encodeComponent(mapsQuery)}',
    );
    final launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!launched) {
      if (mounted) {
        setState(() {
          _latestGeminiError = 'Unable to open Google Maps.';
          _latestSmartEmpty = false;
        });
      }
      return;
    }

    if (mounted) {
      final label = _canonicalIntentName(trimmed);
      setState(() {
        _latestSmartText = 'Opening Google Maps for $label';
        _latestGeminiError = null;
        _latestSmartEmpty = false;
      });
    }
  }

  String _mapsQueryForIntent(String intentQuery) {
    final lower = intentQuery.toLowerCase();
    final hasLocationHint = RegExp(
      r'\b(near|nearby|nearest|around|in|at|to|towards|from|close)\b',
      caseSensitive: false,
    ).hasMatch(lower);
    if (hasLocationHint) return intentQuery;

    final canonical = _canonicalIntentName(intentQuery);
    return '$canonical near me';
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
            final nameController =
                TextEditingController(text: _emergencyContactName);
            final numberController =
                TextEditingController(text: _emergencyContactNumber);
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
                    controller: nameController,
                    decoration: const InputDecoration(labelText: 'Name', hintText: 'e.g. John Doe'),
                    style: const TextStyle(fontSize: 18, color: Color(0xFF1A1A1A)),
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: numberController,
                    decoration: const InputDecoration(labelText: 'Phone Number', hintText: 'e.g. +1234567890'),
                    keyboardType: TextInputType.phone,
                    style: const TextStyle(fontSize: 18, color: Color(0xFF1A1A1A)),
                  ),
                  const SizedBox(height: 12),
                  Align(
                    alignment: Alignment.centerRight,
                    child: ElevatedButton(
                      onPressed: () {
                        unawaited(_saveEmergencyContact(
                          nameController.text,
                          numberController.text,
                        ));
                        setModalState(() {});
                      },
                      child: const Text('Save Contact'),
                    ),
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

