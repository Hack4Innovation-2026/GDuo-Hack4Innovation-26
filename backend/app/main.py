from contextlib import asynccontextmanager

from fastapi import FastAPI, HTTPException

from .config import get_settings
from .recognition import PersonRecognitionService
from .schemas import (
    AnalyzeFrameRequest,
    AnalyzeFrameResponse,
    RegisterPersonRequest,
    RegisterPersonResponse,
)


settings = get_settings()
recognition_service = PersonRecognitionService(settings)


@asynccontextmanager
async def lifespan(_: FastAPI):
    yield


app = FastAPI(
    title=settings.service_name,
    version="1.0.0",
    lifespan=lifespan,
)


@app.get("/health")
async def health() -> dict[str, str]:
    return {"status": "ok"}


@app.post("/person-recognition/analyze", response_model=AnalyzeFrameResponse)
async def analyze_person(request: AnalyzeFrameRequest) -> AnalyzeFrameResponse:
    try:
        return recognition_service.analyze_frame(
            image_base64=request.image_base64,
            language=request.language,
        )
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    except Exception as exc:  # pragma: no cover - runtime surface area
        raise HTTPException(status_code=500, detail=f"Recognition failed: {exc}") from exc


@app.post("/person-recognition/register", response_model=RegisterPersonResponse)
async def register_person(request: RegisterPersonRequest) -> RegisterPersonResponse:
    try:
        return recognition_service.register_person(
            name=request.name,
            image_base64=request.image_base64,
        )
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    except Exception as exc:  # pragma: no cover - runtime surface area
        raise HTTPException(status_code=500, detail=f"Registration failed: {exc}") from exc
