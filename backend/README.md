# Person Recognition Backend

FastAPI service for nearby person detection, face recognition, registration, and voice-ready responses.

## Run

```bash
python -m venv .venv
source .venv/bin/activate
pip install -r backend/requirements.txt
uvicorn backend.app.main:app --host 0.0.0.0 --port 8000 --reload
```

## Environment

Set these before starting the API when needed:

```bash
export PERSON_RECOGNITION_GCS_BUCKET_NAME=your-bucket
export PERSON_RECOGNITION_YOLO_MODEL_PATH=/absolute/path/to/yolov8n.pt
export PERSON_RECOGNITION_FACE_MATCH_DISTANCE_THRESHOLD=0.4
export PERSON_RECOGNITION_MAX_PERSON_DISTANCE_M=2.5
```

Stored embeddings are written to `backend/data/face_embeddings.json`.
