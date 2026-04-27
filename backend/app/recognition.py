from __future__ import annotations

import base64
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from math import tan, pi
from threading import RLock

import cv2
import numpy as np
from deepface import DeepFace
from ultralytics import YOLO

from .config import Settings
from .database import FaceEmbeddingDatabase, FaceEmbeddingRecord
from .schemas import AnalyzeFrameResponse, RegisterPersonResponse
from .storage import GCSFaceStorage


@dataclass
class BoundingBox:
    x1: int
    y1: int
    x2: int
    y2: int

    @property
    def width(self) -> int:
        return max(0, self.x2 - self.x1)

    @property
    def height(self) -> int:
        return max(0, self.y2 - self.y1)

    @property
    def area(self) -> int:
        return self.width * self.height


class PersonRecognitionService:
    def __init__(self, settings: Settings) -> None:
        self._settings = settings
        self._person_model = YOLO(settings.yolo_model_path)
        self._face_detector = cv2.CascadeClassifier(
            cv2.data.haarcascades + "haarcascade_frontalface_default.xml",
        )
        self._database = FaceEmbeddingDatabase(settings.embeddings_db_path)
        self._storage = GCSFaceStorage(settings)
        self._cooldown_lock = RLock()
        self._last_announcement_key = ""
        self._last_announcement_at = datetime.min.replace(tzinfo=timezone.utc)

    def analyze_frame(
        self,
        image_base64: str,
        language: str,
    ) -> AnalyzeFrameResponse:
        frame_bgr = _decode_base64_image(image_base64)
        person_box, distance_meters = self._detect_primary_person(frame_bgr)
        if person_box is None:
            return AnalyzeFrameResponse(status="no_person")
        if distance_meters is None or distance_meters > self._settings.max_person_distance_m:
            return AnalyzeFrameResponse(
                status="too_far",
                distance_meters=distance_meters,
            )

        face_bgr = self._extract_face_from_person(frame_bgr, person_box)
        if face_bgr is None:
            face_bgr = self._extract_face(frame_bgr)
        if face_bgr is None:
            return AnalyzeFrameResponse(
                status="face_not_found",
                distance_meters=distance_meters,
            )

        embedding = self._embedding_for_face(face_bgr)
        record, distance = self._database.match(
            embedding,
            max_distance=self._settings.face_match_distance_threshold,
        )

        if record is None:
            message = _localized_unknown_message(language)
            should_announce = self._should_announce(message)
            return AnalyzeFrameResponse(
                status="unknown",
                message=message,
                should_announce=should_announce,
                is_known=False,
                distance_meters=distance_meters,
                similarity_distance=distance,
            )

        message = _localized_known_message(language, record.name)
        should_announce = self._should_announce(message)
        return AnalyzeFrameResponse(
            status="known",
            message=message,
            should_announce=should_announce,
            is_known=True,
            name=record.name,
            distance_meters=distance_meters,
            similarity_distance=distance,
            gcs_path=record.gcs_path,
        )

    def register_person(self, name: str, image_base64: str) -> RegisterPersonResponse:
        frame_bgr = _decode_base64_image(image_base64)
        face_bgr = self._extract_face_for_registration(frame_bgr)
        embedding = self._embedding_for_face(face_bgr)
        success, encoded_face = cv2.imencode(".jpg", face_bgr)
        if not success:
            raise ValueError("Unable to encode face crop for storage.")
        gcs_path = self._storage.upload_face_image(encoded_face.tobytes(), name)
        record_count = self._database.add_record(
            FaceEmbeddingRecord(
                name=name.strip(),
                embedding=embedding,
                gcs_path=gcs_path,
            )
        )
        return RegisterPersonResponse(
            success=True,
            name=name.strip(),
            gcs_path=gcs_path,
            records_for_person=record_count,
            message=f"Registered {name.strip()} successfully.",
        )

    def _detect_primary_person(self, frame_bgr: np.ndarray) -> tuple[BoundingBox | None, float | None]:
        results = self._person_model.predict(
            source=frame_bgr,
            classes=[self._settings.person_class_id],
            conf=self._settings.min_person_confidence,
            verbose=False,
        )
        if not results:
            return None, None
        frame_height, frame_width = frame_bgr.shape[:2]
        candidates: list[tuple[BoundingBox, float]] = []
        for box in results[0].boxes:
            xyxy = box.xyxy[0].tolist()
            person_box = _clamp_box(
                BoundingBox(
                    x1=int(xyxy[0]),
                    y1=int(xyxy[1]),
                    x2=int(xyxy[2]),
                    y2=int(xyxy[3]),
                ),
                frame_width=frame_width,
                frame_height=frame_height,
            )
            if person_box.area <= 0:
                continue
            distance = self._estimate_distance(person_box.height, frame_height)
            candidates.append((person_box, distance))
        if not candidates:
            return None, None
        candidates.sort(key=lambda item: (item[0].area, -item[1]), reverse=True)
        return candidates[0]

    def _estimate_distance(self, bbox_height_px: int, frame_height_px: int) -> float | None:
        if bbox_height_px <= 0 or frame_height_px <= 0:
            return None
        fov_radians = self._settings.camera_fov_degrees * pi / 180.0
        focal_length_px = frame_height_px / (2 * tan(fov_radians / 2))
        return (
            self._settings.average_person_height_m * focal_length_px / bbox_height_px
        )

    def _extract_face_for_registration(self, frame_bgr: np.ndarray) -> np.ndarray:
        person_box, _ = self._detect_primary_person(frame_bgr)
        if person_box is not None:
            face = self._extract_face_from_person(frame_bgr, person_box)
            if face is not None:
                return face
        face = self._extract_face(frame_bgr)
        if face is None:
            raise ValueError("No face detected in the registration image.")
        return face

    def _extract_face_from_person(
        self,
        frame_bgr: np.ndarray,
        person_box: BoundingBox,
    ) -> np.ndarray | None:
        person_crop = frame_bgr[person_box.y1 : person_box.y2, person_box.x1 : person_box.x2]
        if person_crop.size == 0:
            return None
        return self._extract_face(person_crop)

    def _extract_face(self, image_bgr: np.ndarray) -> np.ndarray | None:
        deepface_face = self._extract_face_with_deepface(image_bgr)
        if deepface_face is not None:
            return deepface_face

        if self._face_detector.empty():
            raise ValueError("OpenCV face detector failed to initialize.")
        gray = cv2.cvtColor(image_bgr, cv2.COLOR_BGR2GRAY)
        gray = cv2.equalizeHist(gray)
        detections = self._face_detector.detectMultiScale(
            gray,
            scaleFactor=1.1,
            minNeighbors=5,
            minSize=(40, 40),
        )
        if len(detections) == 0:
            return None
        height, width = image_bgr.shape[:2]
        best_box: BoundingBox | None = None
        for x, y, w, h in detections:
            abs_box = _clamp_box(
                BoundingBox(
                    x1=int(x),
                    y1=int(y),
                    x2=int(x + w),
                    y2=int(y + h),
                ),
                frame_width=width,
                frame_height=height,
                expand_ratio=0.18,
            )
            if abs_box.area <= 0:
                continue
            if best_box is None or abs_box.area > best_box.area:
                best_box = abs_box
        if best_box is None:
            return None
        return image_bgr[best_box.y1 : best_box.y2, best_box.x1 : best_box.x2]

    def _extract_face_with_deepface(self, image_bgr: np.ndarray) -> np.ndarray | None:
        try:
            faces = DeepFace.extract_faces(
                img_path=image_bgr,
                detector_backend="opencv",
                enforce_detection=False,
                align=True,
            )
        except Exception:
            return None
        best_face: np.ndarray | None = None
        best_area = 0
        for face_info in faces:
            face = face_info.get("face")
            if face is None:
                continue
            facial_area = face_info.get("facial_area") or {}
            width = int(facial_area.get("w", 0) or 0)
            height = int(facial_area.get("h", 0) or 0)
            area = width * height
            if area < 1600:
                continue
            if area > best_area:
                best_area = area
                face_array = np.array(face)
                if face_array.max() <= 1.0:
                    face_array = (face_array * 255).clip(0, 255)
                if face_array.ndim == 3 and face_array.shape[2] == 3:
                    best_face = cv2.cvtColor(face_array.astype(np.uint8), cv2.COLOR_RGB2BGR)
                else:
                    best_face = face_array.astype(np.uint8)
        return best_face

    def _embedding_for_face(self, face_bgr: np.ndarray) -> list[float]:
        representations = DeepFace.represent(
            img_path=face_bgr,
            model_name="Facenet",
            detector_backend="skip",
            enforce_detection=False,
        )
        if not representations:
            raise ValueError("Unable to generate a face embedding.")
        first = representations[0] if isinstance(representations, list) else representations
        embedding = first.get("embedding") if isinstance(first, dict) else first
        if not isinstance(embedding, list):
            raise ValueError("DeepFace returned an invalid embedding payload.")
        return [float(value) for value in embedding]

    def _should_announce(self, message: str) -> bool:
        if not message:
            return False
        now = datetime.now(timezone.utc)
        with self._cooldown_lock:
            cooldown = timedelta(seconds=self._settings.announcement_cooldown_seconds)
            if (
                self._last_announcement_key == message
                and now - self._last_announcement_at < cooldown
            ):
                return False
            self._last_announcement_key = message
            self._last_announcement_at = now
            return True


def _decode_base64_image(image_base64: str) -> np.ndarray:
    try:
        raw_bytes = base64.b64decode(image_base64)
    except Exception as exc:  # pragma: no cover - defensive parsing
        raise ValueError("Invalid base64 image payload.") from exc
    buffer = np.frombuffer(raw_bytes, dtype=np.uint8)
    image = cv2.imdecode(buffer, cv2.IMREAD_COLOR)
    if image is None:
        raise ValueError("Unable to decode image payload.")
    return image


def _clamp_box(
    box: BoundingBox,
    *,
    frame_width: int,
    frame_height: int,
    expand_ratio: float = 0.0,
) -> BoundingBox:
    width = box.width
    height = box.height
    if expand_ratio > 0:
        expand_x = int(width * expand_ratio)
        expand_y = int(height * expand_ratio)
    else:
        expand_x = 0
        expand_y = 0
    x1 = max(0, box.x1 - expand_x)
    y1 = max(0, box.y1 - expand_y)
    x2 = min(frame_width, box.x2 + expand_x)
    y2 = min(frame_height, box.y2 + expand_y)
    return BoundingBox(x1=x1, y1=y1, x2=x2, y2=y2)


def _localized_known_message(language: str, name: str) -> str:
    if language == "Hindi":
        return f"{name} आपके सामने हैं।"
    if language == "Marathi":
        return f"{name} तुमच्या समोर आहेत."
    return f"{name} is in front of you."


def _localized_unknown_message(language: str) -> str:
    if language == "Hindi":
        return "अज्ञात व्यक्ति सामने है।"
    if language == "Marathi":
        return "अनोळखी व्यक्ती समोर आहे."
    return "Unknown person detected."
