/// Gemini REST endpoint
const String GEMINI_ENDPOINT =
    'https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent';

/// Path to the YOLOv8 ONNX model asset (exported from best.pt)
const String YOLO_MODEL_ASSET = 'assets/models/best.onnx';

/// Path to the model class labels asset
const String COCO_LABELS_ASSET = 'assets/models/road_labels.txt';

/// Path to the indoor YOLOv8 ONNX model asset
const String INDOOR_YOLO_MODEL_ASSET = 'assets/models/indoor.onnx';

/// Path to the indoor model class labels asset
const String INDOOR_LABELS_ASSET = 'assets/models/indoor_labels.txt';

/// Path to the signboard YOLOv8 ONNX model asset
const String SIGNBOARD_YOLO_MODEL_ASSET = 'assets/models/Signboard_v1.onnx';

/// Path to the signboard model class labels asset
const String SIGNBOARD_LABELS_ASSET = 'assets/models/signboard_labels.txt';

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

/// Emergency contact number (tap to call). Leave empty to hide the button.
const String EMERGENCY_CONTACT_NUMBER = '9876543210';
