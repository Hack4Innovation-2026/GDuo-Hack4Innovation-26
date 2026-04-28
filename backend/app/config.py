from functools import lru_cache
from pathlib import Path

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_file=".env",
        env_prefix="PERSON_RECOGNITION_",
        extra="ignore",
    )

    service_name: str = "DrishtiAI Person Recognition"
    embeddings_db_path: Path = Path("backend/data/face_embeddings.json")
    gcs_bucket_name: str = ""
    gcs_faces_prefix: str = "faces_db"
    yolo_model_path: str = "yolov8n.pt"
    person_class_id: int = 0
    min_person_confidence: float = 0.35
    camera_fov_degrees: float = 60.0
    average_person_height_m: float = 1.7
    max_person_distance_m: float = 5.0
    face_detection_confidence: float = 0.5
    face_match_distance_threshold: float = 0.6
    announcement_cooldown_seconds: int = 4


@lru_cache(maxsize=1)
def get_settings() -> Settings:
    settings = Settings()
    settings.embeddings_db_path.parent.mkdir(parents=True, exist_ok=True)
    return settings
