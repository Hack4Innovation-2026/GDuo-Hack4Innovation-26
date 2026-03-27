// ─────────────────────────────────────────────────────────────────────────────
// DrishtiAI Configuration
// ─────────────────────────────────────────────────────────────────────────────
//
// IMPORTANT: Replace GEMINI_API_KEY with your real key before Phase 4 testing.
// Never commit this file with a real key to version control.
//
// ignore_for_file: constant_identifier_names

/// Your Gemini 1.5 Flash API key.
/// Leave as-is until Phase 4 — the app will not call Gemini before that phase.
const String GEMINI_API_KEY = 'AIzaSyA_HhasPrATdqwWTcpfOwqbzEkMcZAdeAo';

/// Gemini REST endpoint
const String GEMINI_ENDPOINT =
    'https://generativelanguage.googleapis.com/v1beta/models/gemini-1.5-flash:generateContent';

/// Path to the YOLOv8-Nano ONNX model asset
const String YOLO_MODEL_ASSET = 'assets/models/yolov8n.onnx';

/// Path to the COCO class labels asset
const String COCO_LABELS_ASSET = 'assets/models/coco_labels.txt';

/// Cosine similarity threshold for face recognition
const double FACE_SIMILARITY_THRESHOLD = 0.82;

/// Maximum metres before a landmark is announced
const double LANDMARK_PROXIMITY_METRES = 20.0;

/// Metres at which YOLO obstacle triggers an urgent spoken warning
const double OBSTACLE_WARNING_METRES = 5.0;

/// Intent auto-clear duration in seconds
const int INTENT_TIMEOUT_SECONDS = 60;

/// How many conversation rows to keep in DB
const int MAX_CONVERSATION_ROWS = 20;

/// App name shown in UI
const String APP_NAME = 'DrishtiAI';
