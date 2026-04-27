from __future__ import annotations

import json
import math
from dataclasses import asdict, dataclass
from pathlib import Path
from threading import RLock


@dataclass
class FaceEmbeddingRecord:
    name: str
    embedding: list[float]
    gcs_path: str | None = None


class FaceEmbeddingDatabase:
    def __init__(self, db_path: Path) -> None:
        self._db_path = db_path
        self._lock = RLock()
        self._records: list[FaceEmbeddingRecord] = []
        self.load()

    @property
    def records(self) -> list[FaceEmbeddingRecord]:
        with self._lock:
            return list(self._records)

    def load(self) -> None:
        with self._lock:
            if not self._db_path.exists():
                self._records = []
                return
            raw = json.loads(self._db_path.read_text(encoding="utf-8"))
            self._records = [
                FaceEmbeddingRecord(
                    name=item["name"],
                    embedding=[float(v) for v in item["embedding"]],
                    gcs_path=item.get("gcs_path"),
                )
                for item in raw
                if isinstance(item, dict)
                and item.get("name")
                and isinstance(item.get("embedding"), list)
            ]

    def add_record(self, record: FaceEmbeddingRecord) -> int:
        with self._lock:
            self._records.append(record)
            self._persist()
            return sum(1 for item in self._records if item.name == record.name)

    def match(
        self,
        embedding: list[float],
        max_distance: float,
    ) -> tuple[FaceEmbeddingRecord | None, float | None]:
        with self._lock:
            best_record: FaceEmbeddingRecord | None = None
            best_distance: float | None = None
            for record in self._records:
                distance = cosine_distance(record.embedding, embedding)
                if best_distance is None or distance < best_distance:
                    best_record = record
                    best_distance = distance
            if best_distance is None or best_distance > max_distance:
                return None, best_distance
            return best_record, best_distance

    def _persist(self) -> None:
        self._db_path.parent.mkdir(parents=True, exist_ok=True)
        data = [asdict(record) for record in self._records]
        self._db_path.write_text(
            json.dumps(data, ensure_ascii=True, indent=2),
            encoding="utf-8",
        )


def cosine_distance(vec_a: list[float], vec_b: list[float]) -> float:
    if not vec_a or not vec_b or len(vec_a) != len(vec_b):
        return 1.0
    dot = sum(a * b for a, b in zip(vec_a, vec_b))
    norm_a = math.sqrt(sum(a * a for a in vec_a))
    norm_b = math.sqrt(sum(b * b for b in vec_b))
    if norm_a == 0 or norm_b == 0:
        return 1.0
    return 1.0 - (dot / (norm_a * norm_b))
