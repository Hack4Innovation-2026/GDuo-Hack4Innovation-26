# DrishtiAI — A smart AI-powered Visual Assistant

A comprehensive AI-powered assistant for **visually impaired users**. DrishtiAI combines on-device scene understanding, real-time OCR, a local voice assistant, and a powerful Python backend to deliver grounded, actionable insights about the user's surroundings.

---

## 🌟 Core Features

### 1. Scene & Person Understanding (YOLOv8)
- Real-time person detection using on-device YOLOv8 models.
- **Distance Filtering:** Estimates person distance using bounding-box height.
- **Face Recognition:** MediaPipe face detection combined with DeepFace Facenet embeddings to recognize registered individuals.
- **Local Embedding Store:** Fast matching using a local JSON-based vector database.

### 2. Intelligent Signboard Reading (Gemini AI)
- Uses on-device OCR combined with the Google Gemini API to read and interpret signboards.
- Infers core meaning from images and text (e.g., detecting "Emergency" or "Pharmacy").
- Filters out noise like ads, slogans, and URLs.
- Extracts actionable entities like phone numbers (for calls) or locations (for maps).

### 3. Voice-Driven Copilot
Every interaction is routed through an intuitive voice assistant:
- **Speech-to-Text:** Listens to user questions (e.g., "Is there a pharmacy nearby?").
- **Intent Matching:** Classifies user intent and routes to the appropriate tool (Gemini or YOLO).
- **Text-to-Speech & Haptics:** Reads responses back in concise, prioritized sentences, accompanied by haptic feedback.

### 4. Cloud Synchronization (Optional)
- Optional Google Cloud Storage uploads for backing up registered face embeddings.

---

## 🏗️ Technology Stack

| Layer | Technology |
|-------|-----------|
| **Frontend** | Flutter (Dart), Riverpod, GoRouter |
| **Styling** | Material 3, Google Fonts |
| **On-Device ML** | Google ML Kit (OCR), ONNX Runtime (YOLOv8) |
| **Backend** | Python, FastAPI, Uvicorn |
| **Computer Vision** | YOLOv8n, MediaPipe Face Detection |
| **Face Recognition** | DeepFace (Facenet) |
| **AI Generation** | Google Gemini API (`gemini-2.5-flash`) |

---

## 📁 Project Structure

```
DrishtiAI/
├── backend/                      # Person Recognition Backend
│   ├── app/                      # FastAPI service
│   │   ├── main.py               # Application entry point
│   │   ├── recognition.py        # Face & YOLO logic
│   │   └── database.py           # Local embedding store
│   ├── data/                     # Runtime: face_embeddings.json
│   └── requirements.txt          # Python dependencies
├── lib/                          # Flutter Frontend Source
│   ├── main.dart                 # Application entry point + Theme
│   ├── router.dart               # App navigation
│   ├── screens/                  # UI screens (Home, Onboarding)
│   ├── services/                 # Core logic (Gemini, YOLO, Voice, Haptics)
│   └── widgets/                  # Reusable UI components
├── assets/                       # Local models and assets
├── pubspec.yaml                  # Flutter dependencies
├── .env.example                  # Example environment variables
└── README.md
```

---

## 🚀 Setup & Running

### Prerequisites
- Flutter SDK (v3.7.0+)
- Python 3.10+
- Google Gemini API Key

### 1. Clone
```bash
git clone <repository-url>
cd DrishtiAI
```

### 2. Configure Environment
Create `.env` files for both frontend and backend.

**Frontend (`.env` in root):**
```bash
cp .env.example .env
```
Ensure `PERSON_RECOGNITION_API_BASE_URL` is set to point to the backend (e.g., `http://10.0.2.2:8000` for Android emulators) and `GEMINI_API_KEY` is provided.

**Backend Environment (Exported or `.env`):**
```bash
export PERSON_RECOGNITION_YOLO_MODEL_PATH=/absolute/path/to/yolov8n.pt
export PERSON_RECOGNITION_FACE_MATCH_DISTANCE_THRESHOLD=0.4
export PERSON_RECOGNITION_MAX_PERSON_DISTANCE_M=2.5
```

### 3. Run Backend (Person Recognition)
```bash
python -m venv .venv
source .venv/bin/activate
pip install -r backend/requirements.txt
uvicorn backend.app.main:app --host 0.0.0.0 --port 8000 --reload
```

### 4. Run Frontend (Flutter App)
```bash
flutter pub get
flutter run
```

### 5. Using the App
1. Ensure the backend is running.
2. Launch the Flutter app on a physical device (recommended for camera features) or emulator.
3. Grant Camera and Microphone permissions.
4. Use voice commands or point the camera at signboards for real-time accessibility insights.

---

## 🔌 API Endpoints

| Method | Endpoint | Description |
|--------|----------|-------------|
| `GET` | `/health` | Fetch health status |
| `POST` | `/person-recognition/analyze` | Detect persons, infer distances, and match faces from an image frame |
| `POST` | `/person-recognition/register` | Register a new face embedding to the local database |

---

## 🐛 Troubleshooting

**Backend won't start:**
- Check if port 8000 is already in use.
- Ensure the YOLOv8 model path in `PERSON_RECOGNITION_YOLO_MODEL_PATH` is valid.

**Gemini Analysis Failed:**
- Verify `GEMINI_API_KEY` is set in the Flutter `.env` and has quota remaining.

**Backend Connectivity Issues (Flutter):**
- If using an Android emulator, ensure `PERSON_RECOGNITION_API_BASE_URL` is set to `http://10.0.2.2:8000` instead of `localhost`.

---

## 👥 Contributors
- **Rushil Patil**

---

## 📝 License
Created for DrishtiAI.
