from typing import Literal

from pydantic import BaseModel, Field


Language = Literal["English", "Hindi", "Marathi"]


class AnalyzeFrameRequest(BaseModel):
    image_base64: str = Field(..., description="Base64-encoded JPEG frame")
    language: Language = "English"


class AnalyzeFrameResponse(BaseModel):
    status: Literal["known", "unknown", "no_person", "too_far", "face_not_found"]
    message: str = ""
    should_announce: bool = False
    is_known: bool = False
    name: str | None = None
    distance_meters: float | None = None
    similarity_distance: float | None = None
    gcs_path: str | None = None


class RegisterPersonRequest(BaseModel):
    name: str = Field(..., min_length=1, max_length=80)
    image_base64: str = Field(..., description="Base64-encoded JPEG frame")


class RegisterPersonResponse(BaseModel):
    success: bool
    name: str
    gcs_path: str | None = None
    records_for_person: int
    message: str
