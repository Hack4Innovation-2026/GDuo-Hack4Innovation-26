# DrishtiAI

DrishtiAI is a Flutter assistive application with on-device scene understanding and a FastAPI person-recognition backend.

## Flutter app

```bash
flutter pub get
flutter run
```

Optional runtime configuration goes in `.env`:

```bash
cp .env.example .env
```

`PERSON_RECOGNITION_API_BASE_URL` should point to the FastAPI backend. For Android emulators, `http://10.0.2.2:8000` is the usual local mapping.

## Person Recognition Backend

The backend implements:

- YOLOv8n person detection
- distance filtering using person bounding-box height
- MediaPipe face detection
- DeepFace Facenet embeddings
- local embedding database for fast matching
- optional Google Cloud Storage uploads for registered faces

Start it with:

```bash
python -m venv .venv
source .venv/bin/activate
pip install -r backend/requirements.txt
uvicorn backend.app.main:app --host 0.0.0.0 --port 8000 --reload
```

More backend details are in [backend/README.md](/Users/manasighalsasi/Desktop/DrishtiAi/backend/README.md).
