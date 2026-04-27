from __future__ import annotations

import re
from datetime import datetime, timezone

from google.cloud import storage

from .config import Settings


class GCSFaceStorage:
    def __init__(self, settings: Settings) -> None:
        self._settings = settings
        self._client: storage.Client | None = None
        if settings.gcs_bucket_name:
            self._client = storage.Client()

    @property
    def enabled(self) -> bool:
        return self._client is not None and bool(self._settings.gcs_bucket_name)

    def upload_face_image(self, image_bytes: bytes, person_name: str) -> str | None:
        if not self.enabled or self._client is None:
            return None
        safe_name = _slugify(person_name)
        timestamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
        object_name = (
            f"{self._settings.gcs_faces_prefix.rstrip('/')}/{safe_name}/{timestamp}.jpg"
        )
        bucket = self._client.bucket(self._settings.gcs_bucket_name)
        blob = bucket.blob(object_name)
        blob.upload_from_string(image_bytes, content_type="image/jpeg")
        return f"gs://{self._settings.gcs_bucket_name}/{object_name}"


def _slugify(value: str) -> str:
    normalized = re.sub(r"[^a-zA-Z0-9]+", "_", value.strip().lower())
    return normalized.strip("_") or "person"
