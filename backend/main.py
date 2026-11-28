# ==============================================================================
#  Photo Organizer - API Server & Main Entry Point (Fully Featured)
# ==============================================================================
#
#  This script launches a FastAPI web server with real-time logging via
#  Server-Sent Events (SSE) to provide a responsive user experience for
#  both sorting and face enrollment.
#
# ==============================================================================

#! CRITICAL: This MUST be at the very top before any other imports
# Required for PyInstaller to work correctly with multiprocessing on macOS/Windows
import multiprocessing
if __name__ == "__main__":
    multiprocessing.freeze_support()

import os
import sys

# 从 backend 目录下的 .env 加载环境变量（如 SILICONFLOW_API_KEY），不依赖 python-dotenv
def _load_dotenv():
    env_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), ".env")
    if not os.path.isfile(env_path):
        return
    try:
        with open(env_path, "r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                if "=" in line:
                    k, _, v = line.partition("=")
                    k = k.strip()
                    v = v.strip().strip('"').strip("'")
                    if k and k not in os.environ:
                        os.environ[k] = v
    except Exception:
        pass

_load_dotenv()

import asyncio
import time
MONGODB_ONLY_READS = os.getenv("MONGODB_ONLY_READS", "0").strip().lower() in {
    "1",
    "true",
    "yes",
    "on",
}
# sqlite 彻底弃用：强制关闭，避免任何回退或创建 DB。
USE_SQLITE = False
MONGODB_ONLY_READS = True
import hashlib
import json
import subprocess
import shutil
import pickle
import logging
import signal
from contextlib import asynccontextmanager
from pathlib import Path
from datetime import datetime
import uuid
import base64
import tempfile
from fastapi import FastAPI, HTTPException, Body, Request, BackgroundTasks, UploadFile, File, Form, Query
from fastapi.staticfiles import StaticFiles
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse
from pydantic import BaseModel
from typing import Any, Dict, List, Optional, Set
from starlette.responses import StreamingResponse
import asyncio
from sqlalchemy import text as sql_text
from sqlmodel import SQLModel, Field, Session, create_engine, select
from fastapi.concurrency import run_in_threadpool
from anyio import open_file
import uvicorn
from asyncio import Queue, CancelledError # FIX: Import the asyncio Queue and CancelledError
import httpx
from ai_editor import make_router as make_ai_editor_router

logger = logging.getLogger("uvicorn.info")
AMAP_WEB_KEY = os.getenv("AMAP_WEB_KEY", "").strip()
AMAP_BASE_URL = "https://restapi.amap.com/v3"


def _mongodb_target_from_uri(mongodb_uri: str) -> str:
    try:
        from urllib.parse import urlparse

        u = urlparse(mongodb_uri or "")
        host = u.hostname or ""
        port = int(u.port or 27017)
        return f"{host}:{port}" if host else f":{port}"
    except Exception:
        return mongodb_uri or ""


def _mongodb_uri_points_to_localhost(mongodb_uri: str) -> bool:
    """
    Best-effort check: only attempt auto-start when URI targets local mongod.
    Supports common forms like:
      - mongodb://127.0.0.1:27017
      - mongodb://localhost:27017/?...
    """
    try:
        from urllib.parse import urlparse

        u = urlparse(mongodb_uri or "")
        if (u.scheme or "").lower() != "mongodb":
            return False
        host = (u.hostname or "").lower()
        port = int(u.port or 27017)
        return host in {"127.0.0.1", "localhost"} and port == 27017
    except Exception:
        return False


def _mongodb_ping(mongodb_uri: str, timeout_ms: int = 2000) -> bool:
    try:
        from pymongo import MongoClient  # type: ignore

        client = MongoClient(mongodb_uri, serverSelectionTimeoutMS=timeout_ms)
        client.admin.command("ping")
        return True
    except Exception:
        return False


def ensure_mongodb_running_and_ready() -> bool:
    """
    Ensure a local MongoDB is reachable.

    Behavior:
    - Always tries a fast ping first.
    - On Windows, if MONGODB_URI points to localhost and ENABLE_MONGODB_BOOTSTRAP is on,
      it will try to start a MongoDB Windows service (default service name 'MongoDB'
      or env override MONGODB_SERVICE_NAME) and wait for readiness.
    """
    mongodb_uri = os.getenv("MONGODB_URI", "mongodb://127.0.0.1:27017").strip() or "mongodb://127.0.0.1:27017"
    if _mongodb_ping(mongodb_uri):
        logger.info("MongoDB connected: %s", _mongodb_target_from_uri(mongodb_uri))
        return True

    if sys.platform != "win32":
        return False

    # Only auto-start for explicit bootstrap setups, to avoid surprising behavior.
    enable_bootstrap = os.getenv("ENABLE_MONGODB_BOOTSTRAP", "0").strip().lower() in {"1", "true", "yes", "on"}
    if not enable_bootstrap:
        return False

    if not _mongodb_uri_points_to_localhost(mongodb_uri):
        return False

    service_name = os.getenv("MONGODB_SERVICE_NAME", "MongoDB").strip() or "MongoDB"
    try:
        # net.exe is broadly available on Windows and does not require PowerShell.
        res = subprocess.run(["net", "start", service_name], check=False, capture_output=True, text=True)
        if getattr(res, "returncode", 0) != 0:
            out = (getattr(res, "stdout", "") or "").strip()
            err = (getattr(res, "stderr", "") or "").strip()
            logger.warning(
                "Failed to start MongoDB service via 'net start %s' (code=%s). %s%s",
                service_name,
                getattr(res, "returncode", None),
                f"stdout={out} " if out else "",
                f"stderr={err}" if err else "",
            )
            # Fallback: sc.exe may return more informative output.
            res2 = subprocess.run(["sc", "start", service_name], check=False, capture_output=True, text=True)
            if getattr(res2, "returncode", 0) != 0:
                out2 = (getattr(res2, "stdout", "") or "").strip()
                err2 = (getattr(res2, "stderr", "") or "").strip()
                logger.warning(
                    "Failed to start MongoDB service via 'sc start %s' (code=%s). %s%s",
                    service_name,
                    getattr(res2, "returncode", None),
                    f"stdout={out2} " if out2 else "",
                    f"stderr={err2}" if err2 else "",
                )
    except Exception:
        # Best-effort only.
        pass

    deadline = time.time() + 30
    while time.time() < deadline:
        if _mongodb_ping(mongodb_uri):
            logger.info("MongoDB connected: %s", _mongodb_target_from_uri(mongodb_uri))
            return True
        time.sleep(1)
    ok = _mongodb_ping(mongodb_uri, timeout_ms=5000)
    if ok:
        logger.info("MongoDB connected: %s", _mongodb_target_from_uri(mongodb_uri))
    return ok


# #region agent log
def _debug_log(location: str, message: str, data: dict, hypothesis_id: str = "", run_id: str = ""):
    """
    Lightweight NDJSON logger for automated debugging.

    NOTE: This function is intentionally minimal and MUST NOT raise.
    """
    try:
        import time
        log_path = Path(__file__).resolve().parent.parent / "debug-34b3b1.log"
        payload = {
            "sessionId": "34b3b1",
            "location": location,
            "message": message,
            "data": data,
            "timestamp": int(time.time() * 1000),
        }
        if hypothesis_id:
            payload["hypothesisId"] = hypothesis_id
        if run_id:
            payload["runId"] = run_id
        with open(log_path, "a", encoding="utf-8") as f:
            f.write(json.dumps(payload, ensure_ascii=False) + "\n")
    except Exception:
        # Never allow logging failures to break the main flow.
        pass
# #endregion

# --- Custom Exception Import ---
from exceptions import OperationAbortedError

# --- MongoDB enhanced photo metadata helpers ---
from mongo_enhanced import (
    mongodb_available,
    upsert_image_base,
    get_enhanced_docs,
    merge_description,
    extract_people,
    extract_taken_at,
    extract_location_name,
    patch_enhanced,
    set_default_location_time_if_missing,
    upsert_memory_card,
    upsert_story_card,
    upsert_location_card,
    allocate_photo_id,
    allocate_memory_card_id,
    allocate_story_card_id,
    allocate_trip_id,
    delete_memory_card_from_mongo,
    delete_story_card_from_mongo,
    delete_location_card_from_mongo,
    purge_deleted_cards_from_mongo,
    purge_unused_images_from_mongo,
    migrate_img_description_field,
    get_image_id_by_content_hash,
    delete_image_from_mongo,
    list_memory_cards_from_mongo,
    list_story_cards_from_mongo,
    list_location_cards_from_mongo,
    get_memory_card_from_mongo,
    get_story_card_from_mongo,
    get_location_card_from_mongo,
    list_images_from_mongo,
    list_image_search_items_from_mongo,
    get_image_from_mongo,
)


async def _purge_unused_images_and_files_background() -> None:
    orphans = await asyncio.to_thread(purge_unused_images_from_mongo)
    for d in orphans:
        rel = d.get("relative_path") if isinstance(d, dict) else None
        if rel:
            delete_photo_file(str(rel))

# --- Path Configuration ---

# NEW: Define the path to the frontend build directory
# This handles both development (running as script) and production (running as .exe)
if getattr(sys, 'frozen', False):
    # Path when running as a bundled executable (e.g., from PyInstaller)
    # The frontend is expected to be in a 'dist' folder relative to the executable
    application_path = os.path.dirname(sys.executable)
    # This path assumes the backend exe is in `src-tauri` and the UI is in `dist`
    # Adjust if your final build structure is different.
    FRONTEND_DIR = os.path.join(application_path, '..', 'dist') 
else:
    # Path when running as a script (`python main.py`)
    application_path = os.path.dirname(os.path.abspath(__file__))
    FRONTEND_DIR = os.path.join(application_path, '..', 'frontend', 'dist')


def get_app_data_dir():
    """Gets the application data directory, creating it if it doesn't exist."""
    if sys.platform == 'win32':
        appdata_env = os.getenv('APPDATA')
        if not appdata_env:
            raise RuntimeError("APPDATA environment variable is not set on Windows.")
        app_data_path = Path(appdata_env) / 'MemoirsCore'
    else: # For macOS and Linux
        app_data_path = Path.home() / '.config' / 'MemoirsCore'
    app_data_path.mkdir(parents=True, exist_ok=True)
    return app_data_path

# --- Centralized paths for ALL user data ---
APP_DATA_DIR = get_app_data_dir()
ENROLLMENT_FOLDER = APP_DATA_DIR / "Enrollment"
ENCODINGS_FILE = APP_DATA_DIR / "encodings.pickle"
LAST_CONFIG_FILE = APP_DATA_DIR / "last_config.json"
PATH_PRESETS_FILE = APP_DATA_DIR / "path_presets.json"
# New: Centralized folder for all stored photos（应用内固定图库根目录）
PHOTOS_DIR = APP_DATA_DIR / "Photos"
# 图库根目录在开发阶段就已经约定好，不对用户暴露修改入口。
# 后续所有依赖“图库根目录”的逻辑，都应以此常量为准，而不是使用前端传入的路径。

# SQLite database for photo metadata
DB_PATH = APP_DATA_DIR / "memoirs_core.db"
engine = create_engine(
    f"sqlite:///{DB_PATH}",
    connect_args={"check_same_thread": False},
)


class LibraryConfig(BaseModel):
    """
    High-level configuration for a single photo library.

    The user only needs to choose `library_root`. All internal folders
    such as `.MemoirsCore/Organized` and `.MemoirsCore/Database` are
    derived from this root and hidden from the UI.
    """
    library_root: str
    use_internal_organize: bool = True
    enable_backup: bool = False
    backup_path: Optional[str] = None


class Photo(SQLModel, table=True):
    id: Optional[int] = Field(default=None, primary_key=True)
    filename: str
    relative_path: str
    mime_type: str
    filesize: int
    description: Optional[str] = None
    content_hash: Optional[str] = Field(default=None, index=True)  # SHA256 hex，用于添加前查重
    created_at: datetime
    updated_at: datetime


# --- Memory Cards (Home feed) ---
class MemoryCardDB(SQLModel, table=True):
    id: Optional[int] = Field(default=None, primary_key=True)
    title: str = ""
    content: str = ""
    # Store as JSON string for compatibility with SQLite + SQLModel.
    image_paths_json: str = "[]"
    created_at: datetime = Field(default_factory=datetime.utcnow)
    updated_at: datetime = Field(default_factory=datetime.utcnow)


class MemoryCardCreate(BaseModel):
    title: Optional[str] = ""
    content: Optional[str] = ""
    image_paths: Optional[List[str]] = []


class MemoryCardUpdate(BaseModel):
    title: Optional[str] = None
    content: Optional[str] = None
    image_paths: Optional[List[str]] = None


class MemoryCardRead(BaseModel):
    id: int
    title: str
    content: str
    image_paths: List[str]
    created_at: datetime


class StoryArticleDB(SQLModel, table=True):
    id: Optional[int] = Field(default=None, primary_key=True)
    title: str = ""
    content: str = ""
    cover_photo_id: Optional[int] = None
    image_photo_ids_json: str = "[]"
    reading_minutes: int = 1
    created_at: datetime = Field(default_factory=datetime.utcnow)
    updated_at: datetime = Field(default_factory=datetime.utcnow)


class StoryArticleCreate(BaseModel):
    title: Optional[str] = ""
    content: Optional[str] = ""
    cover_photo_id: Optional[int] = None
    image_photo_ids: Optional[List[int]] = []
    reading_minutes: Optional[int] = 1


class StoryArticleRead(BaseModel):
    id: int
    title: str
    content: str
    cover_photo_id: Optional[int]
    image_photo_ids: List[int]
    reading_minutes: int
    created_at: datetime


class TripDB(SQLModel, table=True):
    __tablename__ = "trip"
    id: Optional[int] = Field(default=None, primary_key=True)
    title: str = ""
    created_at: datetime = Field(default_factory=datetime.utcnow)


class CheckInPointDB(SQLModel, table=True):
    __tablename__ = "check_in_point"
    id: Optional[int] = Field(default=None, primary_key=True)
    trip_id: int = Field(foreign_key="trip.id")
    location_name: str = ""
    latitude: float = 0.0
    longitude: float = 0.0
    coordinate_system: str = "GCJ-02"
    note: str = ""
    photo_ids_json: str = "[]"
    time: datetime = Field(default_factory=datetime.utcnow)


# --- Trip / Check-in Models ---
# 请求模型
class CheckInPointCreate(BaseModel):
    location_name: str
    latitude: float
    longitude: float
    coordinate_system: Optional[str] = "GCJ-02"
    # Backwards compatible: old payload used a single photo_id.
    photo_id: Optional[int] = None
    # New payload: a check-in point can carry multiple photos.
    photo_ids: List[int] = []
    note: str = ""
    time: datetime


class TripCreate(BaseModel):
    title: str
    points: List[CheckInPointCreate]


# 响应模型
class CheckInPointRead(BaseModel):
    id: int
    location_name: str
    latitude: float
    longitude: float
    coordinate_system: str
    note: str
    photo_ids: List[int]
    time: datetime


class TripRead(BaseModel):
    id: int
    title: str
    points: List[CheckInPointRead]
    created_at: datetime


def _decode_image_paths(value: str) -> List[str]:
    try:
        data = json.loads(value or "[]")
        if isinstance(data, list):
            return [str(x) for x in data]
    except Exception:
        pass
    return []


def _encode_image_paths(paths: Optional[List[str]]) -> str:
    try:
        return json.dumps([str(x) for x in (paths or [])], ensure_ascii=False)
    except Exception:
        return "[]"


def _decode_photo_ids(value: str) -> List[int]:
    try:
        data = json.loads(value or "[]")
        if isinstance(data, list):
            out: List[int] = []
            for x in data:
                try:
                    v = int(x)
                    if v > 0:
                        out.append(v)
                except (TypeError, ValueError):
                    continue
            return out
    except Exception:
        pass
    return []


def _encode_photo_ids(ids: Optional[List[int]]) -> str:
    try:
        return json.dumps([int(x) for x in (ids or [])], ensure_ascii=False)
    except Exception:
        return "[]"


def _merge_checkin_photo_ids(payload: CheckInPointCreate) -> List[int]:
    """Merge legacy single photo_id with photo_ids; dedupe while preserving order."""
    merged: List[int] = []
    seen: Set[int] = set()
    if payload.photo_id is not None:
        try:
            v = int(payload.photo_id)
            if v > 0 and v not in seen:
                merged.append(v)
                seen.add(v)
        except (TypeError, ValueError):
            pass
    for x in payload.photo_ids or []:
        try:
            v = int(x)
            if v > 0 and v not in seen:
                merged.append(v)
                seen.add(v)
        except (TypeError, ValueError):
            continue
    return merged


def _check_in_point_to_read(row: CheckInPointDB) -> CheckInPointRead:
    if row.id is None:
        raise ValueError("check-in point id missing")
    return CheckInPointRead(
        id=row.id,
        location_name=row.location_name or "",
        latitude=row.latitude,
        longitude=row.longitude,
        coordinate_system=row.coordinate_system or "GCJ-02",
        note=row.note or "",
        photo_ids=_decode_photo_ids(row.photo_ids_json),
        time=row.time,
    )


def _trip_to_read(session: Session, trip_row: TripDB) -> TripRead:
    if trip_row.id is None:
        raise ValueError("trip id missing")
    pts = session.exec(
        select(CheckInPointDB)
        .where(CheckInPointDB.trip_id == trip_row.id)
        .order_by(CheckInPointDB.id)
    ).all()
    return TripRead(
        id=trip_row.id,
        title=trip_row.title or "",
        points=[_check_in_point_to_read(p) for p in pts if p.id is not None],
        created_at=trip_row.created_at,
    )


def init_db() -> None:
    """Create database tables if they don't exist. Ensures content_hash column exists for existing DBs."""
    if not USE_SQLITE:
        return
    SQLModel.metadata.create_all(engine)
    # Migration: add content_hash if table already existed without it (SQLite)
    try:
        with engine.connect() as conn:
            r = conn.execute(sql_text("PRAGMA table_info(photo)"))
            rows = r.fetchall()
            if rows and not any(c[1] == "content_hash" for c in rows):
                conn.execute(sql_text("ALTER TABLE photo ADD COLUMN content_hash VARCHAR(64)"))
                conn.commit()
    except Exception:
        pass


def _photo_by_content_hash(content_hash: str) -> Optional[Photo]:
    """Return existing Photo with this content_hash if any."""
    with get_session() as session:
        return session.exec(select(Photo).where(Photo.content_hash == content_hash)).first()


def get_session() -> Session:
    if not USE_SQLITE:
        raise RuntimeError("SQLite disabled (USE_SQLITE=0).")
    return Session(engine)


# --- Backend Logic Imports ---
# MODIFIED: Import the module itself to access its variables dynamically.
from organizer_logic import (
    process_photos,
    SUPPORTED_EXTENSIONS,
    load_face_encodings,
    find_and_group_photos,
    get_metadata_overview,
    initialize_libraries,
    build_folder_tree,
    get_exif_data,
    get_date_taken,
    get_location,
    recognize_faces,
)
import organizer_logic
from enrollment_logic import update_encodings
try:
    from mongo_bootstrap import bootstrap_mongodb
except Exception:
    bootstrap_mongodb = None

# --- Lifespan Context Manager ---
@asynccontextmanager
async def lifespan(app: FastAPI):
    """Ensure necessary directories exist and libraries are initialized on server startup."""
    global event_loop
    event_loop = asyncio.get_running_loop()
    # One-time initialization of heavy libraries with verbose output.
    initialize_libraries(is_main_process=True)
    
    # Create necessary folders on startup in the persistent location
    ENROLLMENT_FOLDER.mkdir(exist_ok=True)
    PHOTOS_DIR.mkdir(parents=True, exist_ok=True)

    # Initialize database tables
    init_db()

    # Best-effort: auto-start local MongoDB on Windows when bootstrap is enabled.
    # This reduces "connection refused" failures during initial development setup.
    try:
        ok = ensure_mongodb_running_and_ready()
        if not ok:
            logger.warning("MongoDB is not reachable (MONGODB_URI=%s).", os.getenv("MONGODB_URI", "mongodb://127.0.0.1:27017"))
    except Exception:
        logger.exception("MongoDB readiness check failed.")

    # Optional MongoDB bootstrap (collections + indexes).
    if os.getenv("ENABLE_MONGODB_BOOTSTRAP", "0").strip() in {"1", "true", "yes"}:
        if bootstrap_mongodb is None:
            logger.warning("MongoDB bootstrap requested but mongo_bootstrap is unavailable.")
        else:
            try:
                bootstrap_mongodb()
            except Exception as e:
                logger.error(f"MongoDB bootstrap failed: {e}", exc_info=True)
    yield
    # Code here would run on shutdown

# --- Application State ---
# A queue for sending real-time status updates to the frontend (consumed by SSE).
log_queue: "Queue[str]" = Queue()
# The main event loop is captured in the lifespan context and used to safely
# push updates from background worker threads into the async queue.
event_loop = None

# --- Cancellation Events for Aborting Tasks ---
# Use multiprocessing.Event, which can be safely passed to other processes.
cancellation_events = {
    "sorting": multiprocessing.Event(),
    "enrollment": multiprocessing.Event(),
    "find_group": multiprocessing.Event()
}

# --- FastAPI App Initialization ---
app = FastAPI(
    title="Photo Organizer API",
    description="Backend services for the AI Photo Organizer application with SSE.",
    version="2.0.0",
    lifespan=lifespan
)


@app.post("/api/admin/purge-deleted-cards")
async def admin_purge_deleted_cards():
    # Dev helper: purge hard-deleted card docs that were previously soft-deleted.
    if not mongodb_available():
        raise HTTPException(status_code=503, detail="MongoDB is not available.")
    return await asyncio.to_thread(purge_deleted_cards_from_mongo)


@app.post("/api/admin/purge-unused-images")
async def admin_purge_unused_images():
    orphans = await asyncio.to_thread(purge_unused_images_from_mongo)
    # Best-effort: also delete files from disk (Mongo is source of relative_path).
    for d in orphans:
        rel = d.get("relative_path") if isinstance(d, dict) else None
        if rel:
            delete_photo_file(str(rel))
    return {"deleted": len(orphans)}


@app.post("/api/admin/migrate-image-description-field")
async def admin_migrate_image_description_field():
    res = await asyncio.to_thread(migrate_img_description_field)
    return res


@app.post("/api/admin/backfill-face-people")
async def admin_backfill_face_people(
    background_tasks: BackgroundTasks,
    offset: int = 0,
    limit: int = 200,
    mode: str = "balanced",
    force: bool = False,
):
    """
    Backfill face tags into Mongo for a slice of photos.
    - offset/limit paginate Mongo `images` (newest first).
    - force=true will overwrite existing non-empty `img_people`.
    """
    if not mongodb_available():
        raise HTTPException(status_code=503, detail="MongoDB is not available.")

    docs = await asyncio.to_thread(list_images_from_mongo, offset, limit)
    ids: List[int] = []
    for d in docs:
        try:
            pid = int(d.get("img_id"))
            if pid > 0:
                ids.append(pid)
        except Exception:
            continue

    if not ids:
        return {"scheduled": 0}

    background_tasks.add_task(pre_process_face_people, ids, mode=mode, force=force)
    return {"scheduled": len(ids)}

# --- CORS Middleware ---
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"], # Allow all origins for local development with Tauri
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# 回忆录 / 博客混合信息流（液态玻璃卡片 Mock 联调）
from memoir_feed import router as memoir_feed_router

app.include_router(memoir_feed_router)
async def _editor_photo_source(photo_id: int) -> Path:
    response = await get_photo_file(photo_id)
    return Path(response.path)


async def _editor_photo_items() -> list[dict]:
    photos = []
    offset = 0
    while True:
        batch = await list_photos(offset=offset, limit=200)
        photos.extend(batch)
        if len(batch) < 200:
            break
        offset += len(batch)
    ids = [photo.id for photo in photos if photo.id is not None]
    enhanced = {}
    if ids and mongodb_available():
        for offset in range(0, len(ids), 200):
            enhanced.update(await asyncio.to_thread(get_enhanced_docs, ids[offset:offset + 200]))
    items = []
    for photo in photos:
        if photo.id is None:
            continue
        document = enhanced.get(str(photo.id), {})
        location = document.get("img_location") or {}
        time = document.get("img_time") or {}
        items.append({
            "id": f"photo-{photo.id}", "photo_id": photo.id, "kind": "photo",
            "name": photo.filename, "status": "pending", "start": 0.0, "end": 5.0,
            "has_thumbnail": True, "playable": True,
            "metadata": {
                "description": photo.description,
                "location": location.get("name") if isinstance(location, dict) else None,
                "creation_time": str(time.get("taken_at") or "") if isinstance(time, dict) else "",
                "people": extract_people(document) or [],
            },
        })
    return items


def _editor_video_people(frames) -> list[dict]:
    if not ENCODINGS_FILE.is_file():
        return []
    organizer_logic.initialize_libraries()
    if organizer_logic.face_recognition is None:
        return []
    known_encodings, known_names = load_face_encodings(str(ENCODINGS_FILE))
    if not known_encodings or not known_names:
        return []
    from tempfile import TemporaryDirectory

    observations = []
    with TemporaryDirectory() as folder:
        sample = Path(folder) / "frame.jpg"
        for timestamp, jpg in frames:
            sample.write_bytes(jpg)
            names = recognize_faces(str(sample), known_encodings, known_names, "balanced")
            people = sorted({str(name) for name in names if name and str(name).lower() != "unknown"})
            if people:
                observations.append({"time": timestamp, "people": people})
    return observations


ai_editor_router, index_editor_photos = make_ai_editor_router(
    APP_DATA_DIR / "AIEditor", _editor_photo_items, _editor_photo_source, _editor_video_people
)
app.include_router(ai_editor_router)

# --- Pydantic Models for API Data Validation ---

# MODIFIED: This model is now flexible enough to handle Standard and Hybrid sort options.
class SortOptions(BaseModel):
    primary_sort: str
    face_mode: Optional[str] = 'balanced'
    maintain_hierarchy: Optional[bool] = True
    # --- Fields for Hybrid Sort ---
    base_sort: Optional[str] = None
    specific_folder_name: Optional[str] = None
    custom_filter: Optional[Dict] = None
    # --- Fields for Standard Location Sort ---
    sub_sort_by_date: Optional[bool] = False


class SortRequest(BaseModel):
    source_folder: str
    destination_folder: str
    sorting_options: SortOptions
    ignore_list: Optional[List[str]] = []
    operation_mode: Optional[str] = 'move' # Add this line, default to 'move'


class SimpleSortRequest(BaseModel):
    """
    Simplified request model for single-library mode.

    注意：出于产品设计，图库根目录在后端是固定的，library_root 仅作为兼容字段保留。
    前端可以通过 primary_sort / face_mode / maintain_hierarchy 控制整理行为。
    """
    # 为了兼容已有前端结构，这个字段保留但在后端被忽略，统一使用固定图库根目录。
    library_root: str
    primary_sort: Optional[str] = "Date"
    face_mode: Optional[str] = "balanced"
    maintain_hierarchy: Optional[bool] = False

# NEW: Model for the 'Find & Group' feature configuration
class FindGroupConfig(BaseModel):
    folderName: str
    years: Optional[List[str]] = []
    months: Optional[List[str]] = []
    locations: Optional[List[str]] = []
    people: Optional[List[str]] = []

# NEW: Model for the 'Find & Group' request
class FindGroupRequest(BaseModel):
    source_folder: str
    destination_folder: str
    find_config: FindGroupConfig
    ignore_list: Optional[List[str]] = []
    # REMOVE: operation_mode is no longer needed here.
    # operation_mode: Optional[str] = 'copy'

class LastConfig(BaseModel):
    # NEW: single-library concept (optional; kept for backwards compatibility)
    library_root: Optional[str] = ""
    source_folder: Optional[str] = ""
    destination_folder: Optional[str] = ""
    sort_method: Optional[str] = "Date"
    face_mode: Optional[str] = "balanced"
    # NEW: keep the UI's file operation mode when saving/loading
    file_operation_mode: Optional[str] = "copy"
    maintain_hierarchy: Optional[bool] = False
    ignored_subfolders: Optional[List[str]] = []
    operation_mode: Optional[str] = "standard" # This is for UI mode, not file op

# NEW: Model for a single person's data in a batch.
class PersonData(BaseModel):
    person_name: str
    image_paths: List[str]

# NEW: Model for batch enrollment request.
class BatchEnrollmentRequest(BaseModel):
    people_to_enroll: List[PersonData]

class PathPreset(BaseModel):
    name: str
    source: str
    destination: str

class OpenFolderRequest(BaseModel):
    folder_path: str

class OpenEnrolledFolderRequest(BaseModel):
    person_name: str

class DeleteEnrolledImagesRequest(BaseModel):
    person_name: str
    filenames: List[str]

class SubfolderRequest(BaseModel):
    path: str
    # ADD THIS: The frontend will send the list of folders to ignore.
    ignore_list: Optional[List[str]] = []

class MetadataOverviewRequest(BaseModel):
    source_folder: str
    ignore_list: Optional[List[str]] = []


class PhotoRead(BaseModel):
    id: int
    filename: str
    description: Optional[str] = None
    url: str
    created_at: datetime
    updated_at: datetime


class PhotoAdvancedRead(BaseModel):
    id: int
    url: str
    person_names: List[str] = []
    location: Optional[str] = None
    taken_at: Optional[datetime] = None


class PhotoUpdate(BaseModel):
    description: Optional[str] = None


# --- AI Chat (SiliconFlow) ---
class AIChatMessage(BaseModel):
    role: str  # "user" | "assistant" | "system"
    content: str


class AIChatRequest(BaseModel):
    messages: List[AIChatMessage]
    person_context: Optional[str] = None  # 可选：当前对话聚焦的人物名，用于增强 prompt


class SmartSearchPhoto(BaseModel):
    id: int
    url: str
    description: Optional[str] = None
    person_names: List[str] = []
    location: Optional[str] = None
    taken_at: Optional[datetime] = None


class AIChatResponse(BaseModel):
    content: str
    photos: Optional[List[SmartSearchPhoto]] = None


def resolve_library_paths(library_root: str) -> Dict[str, Path]:
    """
    计算单一图库的内部路径。

    注意：出于产品设计，图库根目录是开发阶段就固定好的，不允许用户在前端随意指定。
    这里会忽略传入的 library_root 参数，统一使用应用固定的 PHOTOS_DIR 作为图库根目录。

    Layout (example for PHOTOS_DIR):
        <APP_DATA_DIR>\\Photos\\
          ├── <user folders>...
          └── .MemoirsCore\\
                ├── Database\\
                ├── Organized\\
                ├── Thumbnails\\      (future use)
                └── Backups\\         (future use)
    """
    # 始终以固定图库根目录为准，防止前端随意修改。
    root = PHOTOS_DIR.expanduser().resolve()
    system_dir = root / ".MemoirsCore"

    destination_dir = system_dir / "Organized"
    database_dir = system_dir / "Database"
    thumbnails_dir = system_dir / "Thumbnails"
    backups_dir = system_dir / "Backups"

    # Ensure core folders exist
    destination_dir.mkdir(parents=True, exist_ok=True)
    database_dir.mkdir(parents=True, exist_ok=True)
    thumbnails_dir.mkdir(parents=True, exist_ok=True)
    backups_dir.mkdir(parents=True, exist_ok=True)

    encodings_file = database_dir / "encodings.pickle"

    # #region agent log
    _debug_log("main.py:resolve_library_paths", "encodings path built", {
        "database_dir": str(database_dir),
        "encodings_file_str": str(encodings_file),
        "encodings_file_repr": repr(str(encodings_file)),
        "has_sep_before_encodings": "encodings.pickle" in str(encodings_file) and str(encodings_file).replace("encodings.pickle", "").endswith((os.sep, "/", "\\")),
    }, "H1")
    # #endregion

    return {
        "root": root,
        "system_base": system_dir,
        "source_folder": root,
        "destination_folder": destination_dir,
        "database_dir": database_dir,
        "thumbnails_dir": thumbnails_dir,
        "backups_dir": backups_dir,
        "encodings_file": encodings_file,
        # IMPORTANT: prevent scanning our own internal structures
        "ignore_list": [str(system_dir)],
    }


def _build_photo_path(relative_path: str) -> Path:
    """Resolve a photo path under PHOTOS_DIR and guard against path traversal."""
    base = PHOTOS_DIR.resolve()
    target = (PHOTOS_DIR / relative_path).resolve()
    if not str(target).startswith(str(base)):
        raise HTTPException(status_code=400, detail="Invalid photo path.")
    return target


# 单次上传最大 50MB，用于读入内存并计算哈希
MAX_UPLOAD_SIZE_FOR_HASH = 50 * 1024 * 1024


async def _read_upload_and_hash(upload_file: UploadFile) -> tuple[bytes, str]:
    """Read upload body and compute SHA256. Returns (content, hex_digest). Raises if too large."""
    chunks: List[bytes] = []
    hasher = hashlib.sha256()
    total = 0
    while True:
        chunk = await upload_file.read(1024 * 1024)
        if not chunk:
            break
        total += len(chunk)
        if total > MAX_UPLOAD_SIZE_FOR_HASH:
            raise HTTPException(status_code=413, detail="File too large for upload.")
        hasher.update(chunk)
        chunks.append(chunk)
    content = b"".join(chunks)
    return content, hasher.hexdigest()


def _save_photo_file_from_bytes(content: bytes, original_filename: str) -> tuple[str, str, int]:
    """Write content to PHOTOS_DIR under date/uuid.ext; return (relative_path, stored_filename, filesize)."""
    _, ext = os.path.splitext(original_filename)
    ext = (ext or ".jpg").lower()
    now = datetime.utcnow()
    rel_dir = Path(str(now.year)) / f"{now.month:02d}" / f"{now.day:02d}"
    target_dir = PHOTOS_DIR / rel_dir
    target_dir.mkdir(parents=True, exist_ok=True)
    stored_filename = f"{uuid.uuid4().hex}{ext}"
    absolute_path = target_dir / stored_filename
    absolute_path.write_bytes(content)
    filesize = len(content)
    relative_path = str(rel_dir / stored_filename)
    return relative_path, stored_filename, filesize


async def save_photo_file(upload_file: UploadFile) -> tuple[str, str, int]:
    """Save an uploaded image into PHOTOS_DIR and return (relative_path, stored_filename, filesize)."""
    original_name = upload_file.filename or "upload"
    _, ext = os.path.splitext(original_name)
    ext = ext.lower() or ".jpg"

    now = datetime.utcnow()
    rel_dir = Path(str(now.year)) / f"{now.month:02d}" / f"{now.day:02d}"
    target_dir = PHOTOS_DIR / rel_dir
    target_dir.mkdir(parents=True, exist_ok=True)

    stored_filename = f"{uuid.uuid4().hex}{ext}"
    absolute_path = target_dir / stored_filename

    # 使用分块读取与异步文件写入，避免一次性将整张大图读入内存。
    async with await open_file(absolute_path, "wb") as f:
        while True:
            chunk = await upload_file.read(1024 * 1024)  # 每次读 1MB
            if not chunk:
                break
            await f.write(chunk)

    filesize = absolute_path.stat().st_size
    relative_path = str(rel_dir / stored_filename)
    return relative_path, stored_filename, filesize


def _create_photo_record(
    relative_path: str,
    stored_filename: str,
    filesize: int,
    content_type: str,
    description: Optional[str],
    content_hash: Optional[str] = None,
) -> Photo:
    """Synchronous helper to insert a Photo row into the database."""
    now = datetime.utcnow()
    with get_session() as session:
        photo = Photo(
            filename=stored_filename,
            relative_path=relative_path,
            mime_type=content_type,
            filesize=filesize,
            description=description,
            content_hash=content_hash,
            created_at=now,
            updated_at=now,
        )
        session.add(photo)
        session.commit()
        session.refresh(photo)
        return photo


def delete_photo_file(relative_path: str) -> None:
    """Delete a photo file from disk if it exists."""
    try:
        absolute_path = _build_photo_path(relative_path)
    except HTTPException:
        return
    if absolute_path.exists() and absolute_path.is_file():
        absolute_path.unlink()

# --- Background Task & SSE Logic ---

def update_status_callback(update_data: Dict):
    """Puts a log message into the queue for the client."""
    try:
        payload = json.dumps(update_data)
        # Use the main event loop to enqueue from worker threads in a
        # thread-safe way. If the loop is not yet available, fall back
        # to a direct put (e.g., during early startup).
        if event_loop is not None and event_loop.is_running():
            event_loop.call_soon_threadsafe(log_queue.put_nowait, payload)
        else:
            log_queue.put_nowait(payload)
    except Exception as e:
        print(f"Error adding log to queue: {e}")

async def run_organization_task(config: Dict):
    """The main processing task, wrapped to be run in the background."""
    cancellation_events["sorting"].clear() # Reset event at start
    try:
        # Pass the encodings file path to the logic function.
        # Allow callers to override this (e.g., per-library encodings)
        # while preserving the old behavior as a default.
        config.setdefault("encodings_path", ENCODINGS_FILE)
        config["cancellation_event"] = cancellation_events["sorting"]
        
        # Create an adapter for the callback to match the expected signature
        def callback_adapter(progress: int, message: str, status: str = "running", analytics: Optional[Dict] = None):
            update_data = {
                "progress": progress, 
                "message": message, 
                "status": status,
                "analytics": analytics or {} # Add analytics to the payload
            }
            update_status_callback(update_data)

        # Run the entire blocking function in a separate thread
        await asyncio.to_thread(process_photos, config, callback_adapter)
    except OperationAbortedError:
        abort_message = "Operation aborted by user. Cleaning up..."
        print(f"BACKGROUND TASK: {abort_message}")
        error_update = {"progress": 100, "message": abort_message, "status": "aborted"}
        update_status_callback(error_update)
    except Exception as e:
        error_update = {"progress": 100, "message": f"An error occurred: {e}", "status": "error"}
        update_status_callback(error_update)
        print(f"BACKGROUND TASK ERROR: {e}")

# NEW: Background task runner for the find and group process.
async def run_find_group_task(config: Dict):
    """The find & group task, wrapped to be run in the background."""
    cancellation_events["find_group"].clear()
    target_folder = None
    try:
        config["encodings_path"] = ENCODINGS_FILE
        config["cancellation_event"] = cancellation_events["find_group"]
        
        # Determine the target folder path for potential cleanup
        target_folder_name = config.get("find_config", {}).get('folderName', "Find_Results")
        target_folder = os.path.join(config["destination_folder"], target_folder_name)

        # FIX: The callback adapter now accepts the 'analytics' dictionary.
        def callback_adapter(progress: int, message: str, status: str = "running", analytics: Optional[Dict] = None):
            update_data = {
                "progress": progress, 
                "message": message, 
                "status": status,
                "analytics": analytics or {}
            }
            update_status_callback(update_data)

        # Run the entire blocking function in a separate thread
        await asyncio.to_thread(find_and_group_photos, config, callback_adapter)
    except OperationAbortedError:
        abort_message = "Find & Group aborted by user. Cleaning up..."
        print(f"BACKGROUND TASK: {abort_message}")
        if target_folder and os.path.exists(target_folder):
            shutil.rmtree(target_folder)
            print(f"Cleaned up partially created folder: {target_folder}")
        error_update = {"progress": 100, "message": abort_message, "status": "aborted"}
        update_status_callback(error_update)
    except Exception as e:
        error_update = {"progress": 100, "message": f"An error occurred: {e}", "status": "error"}
        update_status_callback(error_update)
        print(f"BACKGROUND TASK ERROR: {e}")


# NEW: Background task runner for the enrollment process.
async def run_enrollment_task(newly_created_dirs: List[str]):
    """Wrapper to run the face enrollment process and send real-time updates."""
    cancellation_events["enrollment"].clear()
    try:
        def callback_adapter(progress: int, message: str, status: str = "running"):
            # Add a 'source' key to distinguish from sorting logs
            update_data = {"progress": progress, "message": message, "status": status, "source": "enrollment"}
            update_status_callback(update_data)
        
        # Run the entire blocking function in a separate thread
        await asyncio.to_thread(
            update_encodings, 
            ENROLLMENT_FOLDER, 
            ENCODINGS_FILE, 
            cancellation_events["enrollment"], 
            callback_adapter
        )
        # Ensure per-library encodings file exists for the simplified single-library flow.
        try:
            paths = resolve_library_paths(str(PHOTOS_DIR))
            library_encodings_file = paths.get("encodings_file")
            if library_encodings_file:
                library_encodings_file = Path(library_encodings_file)
                library_encodings_file.parent.mkdir(parents=True, exist_ok=True)
                if ENCODINGS_FILE.exists():
                    shutil.copy2(ENCODINGS_FILE, library_encodings_file)
        except Exception as mirror_err:
            print(f"Warning: failed to mirror encodings to library path: {mirror_err}")
    except OperationAbortedError:
        abort_message = "Enrollment aborted by user. Reverting changes..."
        print(f"ENROLLMENT TASK: {abort_message}")
        # Clean up folders created in this session
        for person_dir in newly_created_dirs:
            if os.path.isdir(person_dir):
                try:
                    shutil.rmtree(person_dir)
                    print(f"Successfully removed aborted enrollment folder: {person_dir}")
                except Exception as e:
                    print(f"Error removing directory {person_dir}: {e}")
        
        # FIX: The original `error_update` was not being passed to the callback.
        # This ensures the final "aborted" status is sent to the UI.
        final_update = {"progress": 100, "message": abort_message, "status": "aborted", "source": "enrollment"}
        update_status_callback(final_update)

    except Exception as e:
        error_update = {"progress": 100, "message": f"An error occurred during enrollment: {e}", "status": "error", "source": "enrollment"}
        update_status_callback(error_update)
        print(f"ENROLLMENT TASK ERROR: {e}")

async def log_streamer(request: Request):
    """Yields server-sent events to the client."""
    # Use a local queue to buffer messages for this specific client
    # This prevents race conditions if multiple clients connect.
    client_queue: "Queue[str]" = Queue()

    # Function to copy messages from the global queue to the local one
    async def queue_copier():
        while True:
            message = await log_queue.get()
            await client_queue.put(message)
            log_queue.task_done()

    copier_task = asyncio.create_task(queue_copier())

    try:
        while True:
            # Check if the client has disconnected
            if await request.is_disconnected():
                print("Client disconnected, closing log stream.")
                break
            
            try:
                # Wait for a message from the local queue
                log_message = await asyncio.wait_for(client_queue.get(), timeout=1.0)
                yield f"data: {log_message}\n\n"
                client_queue.task_done()
            except asyncio.TimeoutError:
                # No message, just loop and check for disconnect again
                continue
    except CancelledError:
        print("Log stream cancelled.")
    finally:
        copier_task.cancel()


# ==============================================================================
#  API Endpoints
# ==============================================================================

@app.get("/")
def read_root():
    return {"message": "Welcome to the Photo Organizer API. Please refer to the documentation for available endpoints."}

@app.get("/api/stream-logs")
async def stream_logs(request: Request):
    """Endpoint for the frontend to connect to for real-time log updates."""
    return StreamingResponse(log_streamer(request), media_type="text/event-stream")


# NOTE:
# 404 root cause found: routes existed, but some runtimes/proxies prepend `/api`
# while others do not. To avoid prefix mismatch (`/api/maps/*` vs `/maps/*`),
# expose both paths during migration.
@app.get("/api/maps/regeo")
@app.get("/maps/regeo")
async def maps_regeo(lat: float, lng: float):
    """Amap reverse geocode proxy: coordinate -> place name."""
    if not AMAP_WEB_KEY:
        # Graceful fallback for local/dev environments without Amap key.
        return {"name": "未知地点"}
    try:
        async with httpx.AsyncClient(timeout=15.0) as client:
            response = await client.get(
                f"{AMAP_BASE_URL}/geocode/regeo",
                params={
                    "location": f"{lng},{lat}",
                    "key": AMAP_WEB_KEY,
                    "extensions": "all",
                },
            )
        response.raise_for_status()
        data = response.json()
    except Exception as e:
        raise HTTPException(status_code=502, detail=f"Amap request failed: {e}")

    if data.get("status") != "1":
        return {"name": "未知地点"}

    regeo = data.get("regeocode") or {}
    pois = regeo.get("pois") or []
    if isinstance(pois, list) and pois:
        first = pois[0] if isinstance(pois[0], dict) else {}
        name = (first.get("name") or "").strip()
        if name:
            return {"name": name}

    formatted = (regeo.get("formatted_address") or "").strip()
    return {"name": formatted or "未知地点"}


@app.get("/api/maps/pois")
@app.get("/maps/pois")
async def maps_pois(keyword: str = Query(..., min_length=1)):
    """Amap POI keyword search proxy."""
    if not AMAP_WEB_KEY:
        # Graceful fallback for local/dev environments without Amap key.
        return {"items": []}
    try:
        async with httpx.AsyncClient(timeout=15.0) as client:
            response = await client.get(
                f"{AMAP_BASE_URL}/place/text",
                params={
                    "keywords": keyword.strip(),
                    "key": AMAP_WEB_KEY,
                    "offset": 10,
                    "page": 1,
                    "extensions": "base",
                },
            )
        response.raise_for_status()
        data = response.json()
    except Exception as e:
        raise HTTPException(status_code=502, detail=f"Amap request failed: {e}")

    if data.get("status") != "1":
        return {"pois": []}

    cleaned: List[dict] = []
    for p in data.get("pois", []):
        if not isinstance(p, dict):
            continue
        cleaned.append(
            {
                "name": p.get("name", "") or "",
                "location": p.get("location", "") or "",
                "address": p.get("address", "") or "",
            }
        )
    return {"pois": cleaned}


@app.get("/api/maps/inputtips")
@app.get("/maps/inputtips")
async def get_input_tips(keywords: str = Query(..., min_length=1)):
    """高德输入提示（InputTips）代理：用于前端地址框实时下拉联想。"""
    if not AMAP_WEB_KEY:
        raise HTTPException(status_code=500, detail="Server missing AMAP_WEB_KEY")
    try:
        async with httpx.AsyncClient(timeout=15.0) as client:
            response = await client.get(
                f"{AMAP_BASE_URL}/assistant/inputtips",
                params={
                    "keywords": keywords.strip(),
                    "key": AMAP_WEB_KEY,
                    "datatype": "all",
                },
            )
            data = response.json()
            if data.get("status") == "1":
                tips = [
                    {
                        "name": t.get("name", ""),
                        "location": t.get("location", ""),
                        "district": t.get("district", ""),
                    }
                    for t in data.get("tips", [])
                    if isinstance(t, dict) and len(t.get("location", "") or "") > 0
                ]
                return {"tips": tips}
            return {"tips": []}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@app.post("/api/list-subfolders")
async def list_subfolders(request: SubfolderRequest):
    """
    MODIFIED: Lists subdirectories as a hierarchical tree and dynamically counts 
    files and folders, respecting an ignore list of full paths.
    """
    source_path = request.path
    # The ignore list now contains full paths.
    ignore_set = set(request.ignore_list or [])

    if not source_path or not os.path.isdir(source_path):
        raise HTTPException(status_code=404, detail="Source path is not a valid directory.")
    try:
        # Build the hierarchical tree structure for the UI.
        folder_tree = build_folder_tree(source_path)
        
        file_count = 0
        folder_count = 0
        
        # CORRECTED LOGIC: Walk the entire directory tree to accurately count items.
        # This now matches the behavior of the core processing logic.
        for dirpath, dirnames, filenames in os.walk(source_path):
            # Count folders that are NOT in the ignore list.
            # We check this by iterating through the children of the current dirpath.
            for d in dirnames:
                if os.path.join(dirpath, d) not in ignore_set:
                    folder_count += 1

            # If the current directory itself is ignored, skip counting its files,
            # but allow os.walk to continue into its subdirectories (like 'B' inside 'A').
            if dirpath in ignore_set:
                continue
            
            # If the directory is not ignored, count its supported files.
            file_count += len([f for f in filenames if f.lower().endswith(SUPPORTED_EXTENSIONS)])

        return {
            "subfolders": folder_tree, # Return the tree structure
            "stats": {
                "folder_count": folder_count,
                "file_count": file_count
            }
        }
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Failed to read directory contents: {str(e)}")

@app.post("/api/start-sorting")
async def start_sorting_endpoint(request: SortRequest, background_tasks: BackgroundTasks):
    """Starts the photo organization process in the background."""
    config = {
        "source_folder": request.source_folder,
        "destination_folder": request.destination_folder,
        "sorting_options": request.sorting_options.dict(),
        "ignore_list": request.ignore_list or [],
        "operation_mode": request.operation_mode
    }
    background_tasks.add_task(run_organization_task, config)
    return {"message": "Organization process started successfully."}


@app.post("/api/start-sorting-simplified")
async def start_sorting_simplified_endpoint(
    request: SimpleSortRequest,
    background_tasks: BackgroundTasks
):
    """
    Starts the photo organization process using a single `library_root`.

    - Source folder: 固定图库根目录本身（后端常量 PHOTOS_DIR）
    - Destination folder: `<PHOTOS_DIR>/.MemoirsCore/Organized`
    - Internal system folders (Database/Thumbnails/Backups) live under `.MemoirsCore`
    - `.MemoirsCore` is automatically added to the ignore list to avoid recursion
    """
    # 忽略前端传入的 library_root，统一使用固定图库根目录
    paths = resolve_library_paths(str(PHOTOS_DIR))

    # 从请求中读取排序与人脸识别相关配置，带有向后兼容的默认值。
    primary_sort = (request.primary_sort or "Date").strip()
    face_mode = (request.face_mode or "balanced").strip()
    maintain_hierarchy = request.maintain_hierarchy if request.maintain_hierarchy is not None else False

    config = {
        "source_folder": str(paths["source_folder"]),
        "destination_folder": str(paths["destination_folder"]),
        # Default sorting behavior，可由前端传入的参数覆盖。
        "sorting_options": {
            "primary_sort": primary_sort,
            "face_mode": face_mode,
            "maintain_hierarchy": maintain_hierarchy,
            "base_sort": None,
            "specific_folder_name": None,
            "custom_filter": None,
            "sub_sort_by_date": False,
        },
        "ignore_list": paths["ignore_list"],
        # In simplified mode we strongly prefer non-destructive operations.
        "operation_mode": "copy",
        # NOTE: We intentionally do NOT override `encodings_path` here.
        # `run_organization_task` will fall back to the global ENCODINGS_FILE,
        # which is also where the enrollment task writes. This avoids
        # mismatches between different encodings paths.
    }

    # #region agent log
    # At this point we intentionally do not force an encodings_path.
    # Log what will be used by default (global ENCODINGS_FILE).
    _debug_log("main.py:start_sorting_simplified", "config before add_task", {
        "encodings_path": str(config.get("encodings_path", ENCODINGS_FILE)),
        "encodings_path_repr": repr(str(config.get("encodings_path", ENCODINGS_FILE))),
    }, "H2")
    # #endregion

    background_tasks.add_task(run_organization_task, config)
    return {
        "message": "Organization process started successfully inside .MemoirsCore/Organized.",
        "library_root": str(paths["root"]),
        "destination_folder": str(paths["destination_folder"]),
    }


# NEW: Endpoint to start the 'Find & Group' process
@app.post("/api/start-find-group")
async def start_find_group_endpoint(request: FindGroupRequest, background_tasks: BackgroundTasks):
    """Starts the 'Find & Group' process in the background."""
    config = {
        "source_folder": request.source_folder,
        "destination_folder": request.destination_folder,
        "find_config": request.find_config.dict(),
        "ignore_list": request.ignore_list or [],
        # REMOVE: No longer passing operation_mode from here.
    }
    background_tasks.add_task(run_find_group_task, config)
    return {"message": "Find & Group process started successfully."}


@app.post("/api/metadata-overview")
async def get_metadata_overview_endpoint(request: MetadataOverviewRequest):
    """Scans the source folder to return all available filter criteria."""
    if not request.source_folder or not os.path.isdir(request.source_folder):
        raise HTTPException(status_code=400, detail="Source path is not a valid directory.")
    
    from organizer_logic import get_metadata_overview as get_metadata_logic

    try:
        locations, date_info, people = get_metadata_logic(
            request.source_folder, 
            request.ignore_list,
            ENCODINGS_FILE
        )
        
        return {
            "locations": locations,
            "dates": date_info, # MODIFIED: from "years" to "dates"
            "people": people
        }
    except Exception as e:
        logging.error(f"Error during metadata scan: {e}", exc_info=True)
        raise HTTPException(status_code=500, detail=f"An unexpected error occurred during metadata scan: {str(e)}")


# ==============================================================================
#  Photo CRUD Endpoints
# ==============================================================================

@app.post("/api/photos")
async def create_photo(
    background_tasks: BackgroundTasks,
    file: UploadFile = File(...),
    description: Optional[str] = Form(None),
):
    """Upload a new photo. Uses content hash to skip duplicates (returns duplicate info if already present)."""
    if not file.content_type or not file.content_type.startswith("image/"):
        raise HTTPException(status_code=400, detail="Only image uploads are supported.")

    if not USE_SQLITE:
        content, content_hash = await _read_upload_and_hash(file)
        original_filename = (file.filename or "").strip() or "upload"

        existing_id = await asyncio.to_thread(get_image_id_by_content_hash, content_hash)
        if existing_id is not None:
            return {
                "duplicate": True,
                "existing_id": existing_id,
                "message": "Photo already in library (duplicate content).",
            }

        relative_path, stored_filename, filesize = _save_photo_file_from_bytes(
            content, original_filename
        )
        now = datetime.utcnow()
        img_id = await asyncio.to_thread(allocate_photo_id)
        await asyncio.to_thread(
            upsert_image_base,
            img_id=img_id,
            filename=stored_filename,
            relative_path=relative_path,
            mime_type=file.content_type,
            filesize=filesize,
            created_at=now,
            updated_at=now,
            content_hash=content_hash,
        )

        # Optional: user-provided description (rare; AI may overwrite later).
        if description is not None and description.strip():
            await asyncio.to_thread(
                patch_enhanced,
                img_id=int(img_id),
                base_photo={
                    "filename": stored_filename,
                    "relative_path": relative_path,
                    "mime_type": file.content_type,
                    "filesize": filesize,
                    "created_at": now,
                    "updated_at": now,
                    "description": None,
                },
                patch={"description": description.strip()},
            )

        background_tasks.add_task(pre_process_vision_descriptions, [int(img_id)])
        background_tasks.add_task(index_editor_photos, [int(img_id)])
        background_tasks.add_task(pre_process_face_people, [int(img_id)])

        return {
            "duplicate": False,
            "photo": PhotoRead(
                id=int(img_id),
                filename=stored_filename,
                description=None,
                url=f"/api/photos/{img_id}/file",
                created_at=now,
                updated_at=now,
            ),
        }

    content, content_hash = await _read_upload_and_hash(file)
    existing = _photo_by_content_hash(content_hash)
    if existing:
        # Ensure mongo base document exists for duplicates too.
        if existing.id is not None:
            await asyncio.to_thread(
                upsert_image_base,
                img_id=int(existing.id),
                filename=existing.filename,
                relative_path=existing.relative_path,
                mime_type=existing.mime_type,
                filesize=existing.filesize,
                created_at=existing.created_at,
                updated_at=existing.updated_at,
            )
        return {
            "duplicate": True,
            "existing_id": existing.id,
            "message": "Photo already in library (duplicate content).",
        }

    relative_path, stored_filename, filesize = _save_photo_file_from_bytes(
        content, file.filename or "upload"
    )
    photo = await run_in_threadpool(
        _create_photo_record,
        relative_path,
        stored_filename,
        filesize,
        file.content_type,
        description,
        content_hash,
    )

    if photo.id is not None:
        await asyncio.to_thread(
            upsert_image_base,
            img_id=int(photo.id),
            filename=photo.filename,
            relative_path=photo.relative_path,
            mime_type=photo.mime_type,
            filesize=photo.filesize,
            created_at=photo.created_at,
            updated_at=photo.updated_at,
        )

        # Vision pre-process (AI description) + Mongo sync
        background_tasks.add_task(pre_process_vision_descriptions, [int(photo.id)])
        background_tasks.add_task(index_editor_photos, [int(photo.id)])

    return {
        "duplicate": False,
        "photo": PhotoRead(
            id=photo.id,
            filename=photo.filename,
            description=photo.description,
            url=f"/api/photos/{photo.id}/file",
            created_at=photo.created_at,
            updated_at=photo.updated_at,
        ),
    }


@app.post("/api/photos/batch")
async def create_photos_batch(
    background_tasks: BackgroundTasks,
    files: List[UploadFile] = File(...),
    description: Optional[str] = Form(None),
):
    """Batch upload: add only non-duplicate photos by content hash; return added list and duplicate list."""
    added: List[dict] = []
    duplicates: List[dict] = []
    new_photo_ids: List[int] = []

    if not USE_SQLITE:
        for upload_file in files:
            original_filename = (upload_file.filename or "").strip() or "upload"
            if not upload_file.content_type or not upload_file.content_type.startswith("image/"):
                duplicates.append(
                    {
                        "id": None,
                        "original_filename": original_filename,
                        "reason": "not an image",
                    }
                )
                continue
            try:
                content, content_hash = await _read_upload_and_hash(upload_file)
            except HTTPException:
                duplicates.append(
                    {
                        "id": None,
                        "original_filename": original_filename,
                        "reason": "file too large",
                    }
                )
                continue

            existing_id = await asyncio.to_thread(
                get_image_id_by_content_hash, content_hash
            )
            if existing_id is not None:
                duplicates.append(
                    {
                        "id": int(existing_id),
                        "original_filename": original_filename,
                        "reason": "duplicate",
                    }
                )
                continue

            relative_path, stored_filename, filesize = _save_photo_file_from_bytes(
                content, original_filename
            )
            now = datetime.utcnow()
            img_id = await asyncio.to_thread(allocate_photo_id)
            await asyncio.to_thread(
                upsert_image_base,
                img_id=int(img_id),
                filename=stored_filename,
                relative_path=relative_path,
                mime_type=upload_file.content_type,
                filesize=filesize,
                created_at=now,
                updated_at=now,
                content_hash=content_hash,
            )

            if description is not None and description.strip():
                await asyncio.to_thread(
                    patch_enhanced,
                    img_id=int(img_id),
                    base_photo={
                        "filename": stored_filename,
                        "relative_path": relative_path,
                        "mime_type": upload_file.content_type,
                        "filesize": filesize,
                        "created_at": now,
                        "updated_at": now,
                        "description": None,
                    },
                    patch={"description": description.strip()},
                )

            new_photo_ids.append(int(img_id))
            added.append(
                {
                    "id": int(img_id),
                    "filename": stored_filename,
                    "original_filename": original_filename,
                    "description": (description.strip() if (description is not None and description.strip()) else None),
                    "url": f"/api/photos/{img_id}/file",
                    "created_at": now.isoformat(),
                    "updated_at": now.isoformat(),
                }
            )

        if new_photo_ids:
            background_tasks.add_task(pre_process_vision_descriptions, new_photo_ids)
            background_tasks.add_task(index_editor_photos, new_photo_ids)
            background_tasks.add_task(pre_process_face_people, new_photo_ids)

        return {"added": added, "duplicates": duplicates}

    for upload_file in files:
        original_filename = (upload_file.filename or "").strip() or "upload"
        if not upload_file.content_type or not upload_file.content_type.startswith("image/"):
            duplicates.append(
                {
                    "id": None,
                    "original_filename": original_filename,
                    "reason": "not an image",
                }
            )
            continue
        try:
            content, content_hash = await _read_upload_and_hash(upload_file)
        except HTTPException:
            duplicates.append(
                {
                    "id": None,
                    "original_filename": original_filename,
                    "reason": "file too large",
                }
            )
            continue

        existing = _photo_by_content_hash(content_hash)
        if existing:
            # Ensure mongo base document exists for duplicates too.
            if existing.id is not None:
                await asyncio.to_thread(
                    upsert_image_base,
                    img_id=int(existing.id),
                    filename=existing.filename,
                    relative_path=existing.relative_path,
                    mime_type=existing.mime_type,
                    filesize=existing.filesize,
                    created_at=existing.created_at,
                    updated_at=existing.updated_at,
                )
            duplicates.append(
                {
                    "id": int(existing.id) if existing.id is not None else None,
                    "original_filename": original_filename,
                    "reason": "duplicate",
                }
            )
            continue

        relative_path, stored_filename, filesize = _save_photo_file_from_bytes(
            content, original_filename
        )
        photo = await run_in_threadpool(
            _create_photo_record,
            relative_path,
            stored_filename,
            filesize,
            upload_file.content_type,
            description,
            content_hash,
        )

        if photo.id is not None:
            await asyncio.to_thread(
                upsert_image_base,
                img_id=int(photo.id),
                filename=photo.filename,
                relative_path=photo.relative_path,
                mime_type=photo.mime_type,
                filesize=photo.filesize,
                created_at=photo.created_at,
                updated_at=photo.updated_at,
            )

        if photo.id is not None:
            new_photo_ids.append(int(photo.id))
        added.append(
            {
                "id": photo.id,
                "filename": photo.filename,
                "original_filename": original_filename,
                "description": photo.description,
                "url": f"/api/photos/{photo.id}/file",
                "created_at": photo.created_at.isoformat(),
                "updated_at": photo.updated_at.isoformat(),
            }
        )

    # 上传成功后，后台静默预处理：生成 AI 视觉描述并写入同级 .json
    if new_photo_ids:
        background_tasks.add_task(pre_process_vision_descriptions, new_photo_ids)
        background_tasks.add_task(index_editor_photos, new_photo_ids)

    return {"added": added, "duplicates": duplicates}


@app.post("/api/covers")
async def upload_cover(
    background_tasks: BackgroundTasks,
    file: UploadFile = File(...),
):
    """
    Upload a cover image.

    Note: This is a lightweight placeholder endpoint used by the story editor.
    After upload succeeds, we trigger a background enhancement task. The task is
    non-blocking and must not interfere with the user's publish flow.
    """
    if not file.content_type or not file.content_type.startswith("image/"):
        raise HTTPException(status_code=400, detail="Only image uploads are supported.")

    if not USE_SQLITE:
        original_filename = (file.filename or "").strip() or "cover"
        content, content_hash = await _read_upload_and_hash(file)

        existing_id = await asyncio.to_thread(get_image_id_by_content_hash, content_hash)
        if existing_id is not None:
            # Fill filename from mongo (optional) for response compatibility.
            doc = await asyncio.to_thread(get_image_from_mongo, int(existing_id))
            return {
                "cover": {
                    "id": int(existing_id),
                    "filename": str(doc.get("filename") or "") if isinstance(doc, dict) else "",
                    "original_filename": original_filename,
                    "url": f"/api/photos/{int(existing_id)}/file",
                }
            }

        relative_path, stored_filename, filesize = _save_photo_file_from_bytes(
            content, original_filename
        )
        now = datetime.utcnow()
        img_id = await asyncio.to_thread(allocate_photo_id)
        await asyncio.to_thread(
            upsert_image_base,
            img_id=int(img_id),
            filename=stored_filename,
            relative_path=relative_path,
            mime_type=file.content_type,
            filesize=filesize,
            created_at=now,
            updated_at=now,
            content_hash=content_hash,
        )

        background_tasks.add_task(pre_process_vision_descriptions, [int(img_id)])
        background_tasks.add_task(index_editor_photos, [int(img_id)])
        background_tasks.add_task(pre_process_face_people, [int(img_id)])

        return {
            "cover": {
                "id": int(img_id),
                "filename": stored_filename,
                "original_filename": original_filename,
                "url": f"/api/photos/{int(img_id)}/file",
            }
        }

    original_filename = (file.filename or "").strip() or "cover"
    content, content_hash = await _read_upload_and_hash(file)

    relative_path, stored_filename, filesize = _save_photo_file_from_bytes(
        content, original_filename
    )
    photo = await run_in_threadpool(
        _create_photo_record,
        relative_path,
        stored_filename,
        filesize,
        file.content_type,
        "cover",
        content_hash,
    )

    if photo.id is not None:
        await asyncio.to_thread(
            upsert_image_base,
            img_id=int(photo.id),
            filename=photo.filename,
            relative_path=photo.relative_path,
            mime_type=photo.mime_type,
            filesize=photo.filesize,
            created_at=photo.created_at,
            updated_at=photo.updated_at,
        )

    if photo.id is not None:
        background_tasks.add_task(enhance_cover_image, int(photo.id))

    return {
        "cover": {
            "id": photo.id,
            "filename": photo.filename,
            "original_filename": original_filename,
            "url": f"/api/photos/{photo.id}/file",
        }
    }


# ==============================================================================
# Memory Cards API
# ==============================================================================

@app.get("/api/memory-cards", response_model=List[MemoryCardRead])
async def list_memory_cards(request: Request):
    # Mongo-first: card meta (including image references) should come from Mongo.
    if mongodb_available():
        docs = await asyncio.to_thread(list_memory_cards_from_mongo)
        if docs:
            base = str(request.base_url).rstrip('/')
            out: List[MemoryCardRead] = []
            for d in docs:
                try:
                    cid = int(d.get("card_id"))
                except Exception:
                    continue

                image_ids = d.get("image_ids") or []
                image_paths: List[str] = []
                if isinstance(image_ids, list):
                    for x in image_ids:
                        final = str(x).strip()
                        if not final:
                            continue
                        if final.isdigit():
                            image_paths.append(
                                f"{base}/api/photos/{final}/file"
                            )
                        else:
                            image_paths.append(final)
                out.append(
                    MemoryCardRead(
                        id=cid,
                        title=(d.get("title") or "").strip(),
                        content=(d.get("content") or "").strip(),
                        image_paths=image_paths,
                        created_at=d.get("created_at"),
                    )
                )
            return out

        if MONGODB_ONLY_READS:
            # Mongo 可用但没有数据：强制不回退 SQLite。
            return []

    # Fallback to SQLite (legacy / migration).
    with get_session() as session:
        rows = session.exec(select(MemoryCardDB).order_by(MemoryCardDB.id.desc())).all()
        result: List[MemoryCardRead] = []
        for r in rows:
            if r.id is None:
                continue
            result.append(
                MemoryCardRead(
                    id=r.id,
                    title=r.title or "",
                    content=r.content or "",
                    image_paths=_decode_image_paths(r.image_paths_json),
                    created_at=r.created_at,
                )
            )
        return result


@app.post("/api/memory-cards", response_model=MemoryCardRead)
async def create_memory_card(payload: MemoryCardCreate):
    if not USE_SQLITE:
        now = datetime.utcnow()
        card_id = await asyncio.to_thread(allocate_memory_card_id)
        image_paths = list(payload.image_paths or [])
        await asyncio.to_thread(
            upsert_memory_card,
            card_id=int(card_id),
            title=payload.title or "",
            content=payload.content or "",
            image_paths=image_paths,
            created_at=now,
            updated_at=now,
        )
        return MemoryCardRead(
            id=int(card_id),
            title=payload.title or "",
            content=payload.content or "",
            image_paths=image_paths,
            created_at=now,
        )

    now = datetime.utcnow()
    row = MemoryCardDB(
        title=(payload.title or ""),
        content=(payload.content or ""),
        image_paths_json=_encode_image_paths(payload.image_paths),
        created_at=now,
        updated_at=now,
    )
    with get_session() as session:
        session.add(row)
        session.commit()
        session.refresh(row)
        if row.id is None:
            raise HTTPException(status_code=500, detail="Failed to create memory card.")
        # Mongo: persist memory card meta (Mongo is source for card refs).
        if row.id is not None:
            image_paths = _decode_image_paths(row.image_paths_json)
            await asyncio.to_thread(
                upsert_memory_card,
                card_id=int(row.id),
                title=row.title or "",
                content=row.content or "",
                image_paths=image_paths,
                created_at=row.created_at,
                updated_at=row.updated_at,
            )

        return MemoryCardRead(
            id=row.id,
            title=row.title or "",
            content=row.content or "",
            image_paths=_decode_image_paths(row.image_paths_json),
            created_at=row.created_at,
        )


@app.put("/api/memory-cards/{card_id}", response_model=MemoryCardRead)
async def update_memory_card(card_id: int, payload: MemoryCardUpdate):
    # Update SQLite (existing) and Mongo (source-of-truth for enhanced/refs).
    if not USE_SQLITE:
        now = datetime.utcnow()
        doc = await asyncio.to_thread(get_memory_card_from_mongo, card_id)
        if not doc:
            raise HTTPException(status_code=404, detail="Memory card not found.")

        title = payload.title if payload.title is not None else (doc.get("title") or "")
        content = payload.content if payload.content is not None else (doc.get("content") or "")

        if payload.image_paths is not None:
            image_paths = list(payload.image_paths)
        else:
            image_ids = doc.get("image_ids") or []
            image_paths = [str(x) for x in image_ids] if isinstance(image_ids, list) else []

        created_at = doc.get("created_at") or now
        await asyncio.to_thread(
            upsert_memory_card,
            card_id=int(card_id),
            title=title or "",
            content=content or "",
            image_paths=image_paths,
            created_at=created_at,
            updated_at=now,
        )

        return MemoryCardRead(
            id=int(card_id),
            title=title or "",
            content=content or "",
            image_paths=image_paths,
            created_at=created_at,
        )

    with get_session() as session:
        row = session.get(MemoryCardDB, card_id)
        if row is None:
            raise HTTPException(status_code=404, detail="Memory card not found.")

        if payload.title is not None:
            row.title = payload.title
        if payload.content is not None:
            row.content = payload.content
        if payload.image_paths is not None:
            row.image_paths_json = _encode_image_paths(payload.image_paths)
        row.updated_at = datetime.utcnow()

        session.add(row)
        session.commit()
        session.refresh(row)

        if row.id is None:
            raise HTTPException(status_code=500, detail="Failed to update memory card.")

        image_paths = _decode_image_paths(row.image_paths_json)
        if mongodb_available():
            await asyncio.to_thread(
                upsert_memory_card,
                card_id=card_id,
                title=row.title or "",
                content=row.content or "",
                image_paths=image_paths,
                created_at=row.created_at,
                updated_at=row.updated_at,
            )

        return MemoryCardRead(
            id=row.id,
            title=row.title or "",
            content=row.content or "",
            image_paths=image_paths,
            created_at=row.created_at,
        )


@app.delete("/api/memory-cards/{card_id}")
async def delete_memory_card(card_id: int, background_tasks: BackgroundTasks):
    # 1) Mongo (soft delete) - UI 列表从 Mongo 读，所以这里必须做。
    if mongodb_available():
        await asyncio.to_thread(delete_memory_card_from_mongo, card_id)
    elif not USE_SQLITE:
        raise HTTPException(status_code=503, detail="MongoDB is not available.")

    # 2) SQLite (hard delete) - 你要求 db 也删除掉。
    if USE_SQLITE:
        with get_session() as session:
            row = session.get(MemoryCardDB, card_id)
            if row is not None:
                session.delete(row)
                session.commit()

    background_tasks.add_task(_purge_unused_images_and_files_background)
    return {"status": "ok"}


@app.get("/api/story-articles", response_model=List[StoryArticleRead])
async def list_story_articles():
    # Mongo-first: story card meta should come from Mongo.
    if mongodb_available():
        docs = await asyncio.to_thread(list_story_cards_from_mongo)
        if docs:
            out: List[StoryArticleRead] = []
            for d in docs:
                try:
                    cid = int(d.get("card_id"))
                except Exception:
                    continue

                cover_raw = d.get("cover_img_id")
                cover_id: Optional[int] = None
                if cover_raw is not None:
                    try:
                        cover_id = int(cover_raw)
                    except Exception:
                        cover_id = None

                image_ids_raw = d.get("image_ids") or []
                image_photo_ids: List[int] = []
                if isinstance(image_ids_raw, list):
                    for x in image_ids_raw:
                        try:
                            ix = int(x)
                            if ix > 0:
                                image_photo_ids.append(ix)
                        except Exception:
                            continue

                out.append(
                    StoryArticleRead(
                        id=cid,
                        title=(d.get("title") or "").strip(),
                        content=(d.get("content") or "").strip(),
                        cover_photo_id=cover_id,
                        image_photo_ids=image_photo_ids,
                        reading_minutes=int(d.get("reading_minutes") or 1),
                        created_at=d.get("created_at"),
                    )
                )
            return out

        if MONGODB_ONLY_READS:
            # Mongo 可用但没有数据：强制不回退 SQLite。
            return []

    # Fallback to SQLite.
    with get_session() as session:
        rows = session.exec(select(StoryArticleDB).order_by(StoryArticleDB.id.desc())).all()
        result: List[StoryArticleRead] = []
        for r in rows:
            if r.id is None:
                continue
            image_ids: List[int]
            try:
                parsed = json.loads(r.image_photo_ids_json or "[]")
                if isinstance(parsed, list):
                    image_ids = [int(x) for x in parsed if isinstance(x, (int, float, str)) and str(x).strip()]
                else:
                    image_ids = []
            except Exception:
                image_ids = []
            result.append(
                StoryArticleRead(
                    id=r.id,
                    title=r.title or "",
                    content=r.content or "",
                    cover_photo_id=r.cover_photo_id,
                    image_photo_ids=image_ids,
                    reading_minutes=r.reading_minutes or 1,
                    created_at=r.created_at,
                )
            )
        return result


@app.delete("/api/story-articles/{card_id}")
async def delete_story_article(card_id: int, background_tasks: BackgroundTasks):
    if mongodb_available():
        await asyncio.to_thread(delete_story_card_from_mongo, card_id)
    elif not USE_SQLITE:
        raise HTTPException(status_code=503, detail="MongoDB is not available.")

    if USE_SQLITE:
        with get_session() as session:
            row = session.get(StoryArticleDB, card_id)
            if row is not None:
                session.delete(row)
                session.commit()

    background_tasks.add_task(_purge_unused_images_and_files_background)
    return {"status": "ok"}


@app.post("/api/story-articles", response_model=StoryArticleRead)
async def create_story_article(payload: StoryArticleCreate):
    if not USE_SQLITE:
        now = datetime.utcnow()
        card_id = await asyncio.to_thread(allocate_story_card_id)
        image_ids = payload.image_photo_ids or []
        safe_ids: List[int] = []
        for x in image_ids:
            try:
                v = int(x)
                if v > 0:
                    safe_ids.append(v)
            except Exception:
                continue

        await asyncio.to_thread(
            upsert_story_card,
            card_id=int(card_id),
            title=payload.title or "",
            content=payload.content or "",
            cover_photo_id=payload.cover_photo_id,
            image_photo_ids=safe_ids,
            reading_minutes=payload.reading_minutes or 1,
            created_at=now,
            updated_at=now,
        )

        return StoryArticleRead(
            id=int(card_id),
            title=payload.title or "",
            content=payload.content or "",
            cover_photo_id=payload.cover_photo_id,
            image_photo_ids=safe_ids,
            reading_minutes=payload.reading_minutes or 1,
            created_at=now,
        )

    now = datetime.utcnow()
    image_ids = payload.image_photo_ids or []
    safe_ids: List[int] = []
    for x in image_ids:
        try:
            v = int(x)
            if v > 0:
                safe_ids.append(v)
        except Exception:
            continue

    row = StoryArticleDB(
        title=(payload.title or ""),
        content=(payload.content or ""),
        cover_photo_id=payload.cover_photo_id,
        image_photo_ids_json=json.dumps(safe_ids, ensure_ascii=False),
        reading_minutes=payload.reading_minutes or 1,
        created_at=now,
        updated_at=now,
    )

    with get_session() as session:
        session.add(row)
        session.commit()
        session.refresh(row)
        if row.id is None:
            raise HTTPException(status_code=500, detail="Failed to create story article.")

        # Mongo: persist story card meta
        if row.id is not None:
            await asyncio.to_thread(
                upsert_story_card,
                card_id=int(row.id),
                title=row.title or "",
                content=row.content or "",
                cover_photo_id=row.cover_photo_id,
                image_photo_ids=image_ids,
                reading_minutes=row.reading_minutes or 1,
                created_at=row.created_at,
                updated_at=row.updated_at,
            )

        return StoryArticleRead(
            id=row.id,
            title=row.title or "",
            content=row.content or "",
            cover_photo_id=row.cover_photo_id,
            image_photo_ids=safe_ids,
            reading_minutes=row.reading_minutes or 1,
            created_at=row.created_at,
        )


@app.post("/api/trips", response_model=TripRead)
async def create_trip(trip: TripCreate):
    title = (trip.title or "").strip()
    if not title:
        raise HTTPException(status_code=400, detail="Trip title is required.")
    if not trip.points:
        raise HTTPException(status_code=400, detail="At least one check-in point is required.")

    if not USE_SQLITE:
        now = datetime.utcnow()
        trip_id = await asyncio.to_thread(allocate_trip_id)

        loc_points: List[Dict[str, Any]] = []
        points_read: List[CheckInPointRead] = []

        for idx, p in enumerate(trip.points):
            photo_ids = _merge_checkin_photo_ids(p)

            if photo_ids:
                await asyncio.to_thread(
                    set_default_location_time_if_missing,
                    photo_ids=photo_ids,
                    default_location_name=(p.location_name or "").strip(),
                    default_taken_at=p.time,
                )

            point_id = f"pt_{len(loc_points)}"
            loc_points.append(
                {
                    "point_id": point_id,
                    "location_name": (p.location_name or "").strip(),
                    "latitude": float(p.latitude),
                    "longitude": float(p.longitude),
                    "coordinate_system": (p.coordinate_system or "GCJ-02").strip()
                    if p.coordinate_system is not None
                    else "GCJ-02",
                    "time": p.time,
                    "note": (p.note or "").strip(),
                    "image_ids": [str(x) for x in photo_ids if x is not None],
                }
            )
            points_read.append(
                CheckInPointRead(
                    id=idx,
                    location_name=(p.location_name or "").strip(),
                    latitude=float(p.latitude),
                    longitude=float(p.longitude),
                    coordinate_system=(p.coordinate_system or "GCJ-02").strip()
                    if p.coordinate_system is not None
                    else "GCJ-02",
                    note=(p.note or "").strip(),
                    photo_ids=photo_ids,
                    time=p.time,
                )
            )

        cover_img_id: Optional[int] = None
        if loc_points:
            img_ids = loc_points[0].get("image_ids") or []
            if isinstance(img_ids, list) and img_ids:
                first = img_ids[0]
                cover_img_id = int(first) if str(first).isdigit() else None

        await asyncio.to_thread(
            upsert_location_card,
            card_id=int(trip_id),
            title=title or "",
            points=loc_points,
            cover_img_id=cover_img_id,
            created_at=now,
            updated_at=now,
        )

        return TripRead(
            id=int(trip_id),
            title=title or "",
            points=points_read,
            created_at=now,
        )

    try:
        with get_session() as session:
            trip_row = TripDB(title=title, created_at=datetime.utcnow())
            session.add(trip_row)
            session.flush()
            if trip_row.id is None:
                session.rollback()
                raise HTTPException(status_code=500, detail="Failed to create trip record.")

            loc_points: List[Dict[str, Any]] = []
            for p in trip.points:
                photo_ids = _merge_checkin_photo_ids(p)
                point_id = f"pt_{len(loc_points)}"
                pt = CheckInPointDB(
                    trip_id=trip_row.id,
                    location_name=(p.location_name or "").strip(),
                    latitude=float(p.latitude),
                    longitude=float(p.longitude),
                    coordinate_system=(p.coordinate_system or "GCJ-02").strip() or "GCJ-02",
                    note=(p.note or "").strip(),
                    photo_ids_json=_encode_photo_ids(photo_ids),
                    time=p.time,
                )
                session.add(pt)

                # Keep Mongo enhanced metadata in sync for photos
                if photo_ids:
                    set_default_location_time_if_missing(
                        photo_ids=photo_ids,
                        default_location_name=(p.location_name or "").strip(),
                        default_taken_at=p.time,
                    )

                loc_points.append(
                    {
                        "point_id": point_id,
                        "location_name": (p.location_name or "").strip(),
                        "latitude": float(p.latitude),
                        "longitude": float(p.longitude),
                        "coordinate_system": (p.coordinate_system or "GCJ-02").strip()
                        if p.coordinate_system is not None
                        else "GCJ-02",
                        "time": p.time,
                        "note": (p.note or "").strip(),
                        "image_ids": [str(x) for x in photo_ids if x is not None],
                    }
                )

            session.commit()
            session.refresh(trip_row)
            # Mongo: persist location card meta
            if trip_row.id is not None:
                cover_img_id = None
                if loc_points:
                    final_first = loc_points[0]
                    img_ids = final_first.get("image_ids") or []
                    if isinstance(img_ids, list) and img_ids:
                        # img_ids are strings in our mongo schema
                        first = img_ids[0]
                        cover_img_id = int(first) if str(first).isdigit() else None

                await asyncio.to_thread(
                    upsert_location_card,
                    card_id=int(trip_row.id),
                    title=trip_row.title or "",
                    points=loc_points,
                    cover_img_id=cover_img_id,
                    created_at=trip_row.created_at,
                    updated_at=trip_row.created_at,
                )

            return _trip_to_read(session, trip_row)
    except HTTPException:
        raise
    except Exception as e:
        logger.exception("create_trip failed: %s", e)
        raise HTTPException(status_code=500, detail="Failed to create trip.") from e


@app.get("/api/trips", response_model=List[TripRead])
async def list_trips():
    """获取所有行程列表：Mongo-first（location_cards），回退 SQLite。"""
    if mongodb_available():
        docs = await asyncio.to_thread(list_location_cards_from_mongo)
        if docs:
            out: List[TripRead] = []
            for d in docs:
                try:
                    tid = int(d.get("card_id"))
                except Exception:
                    continue

                points_raw = d.get("points") or []
                points: List[CheckInPointRead] = []
                if isinstance(points_raw, list):
                    for i, p in enumerate(points_raw):
                        if not isinstance(p, dict):
                            continue
                        try:
                            pid = int(p.get("point_id")) if str(p.get("point_id", "")).isdigit() else i
                        except Exception:
                            pid = i

                        photo_ids: List[int] = []
                        ids_raw = p.get("image_ids") or []
                        if isinstance(ids_raw, list):
                            for x in ids_raw:
                                try:
                                    v = int(x)
                                    if v > 0:
                                        photo_ids.append(v)
                                except Exception:
                                    continue

                        points.append(
                            CheckInPointRead(
                                id=int(pid),
                                location_name=str(p.get("location_name") or ""),
                                latitude=float(p.get("latitude") or 0.0),
                                longitude=float(p.get("longitude") or 0.0),
                                coordinate_system=str(p.get("coordinate_system") or "GCJ-02"),
                                note=str(p.get("note") or ""),
                                photo_ids=photo_ids,
                                time=p.get("time"),
                            )
                        )

                out.append(
                    TripRead(
                        id=tid,
                        title=str(d.get("title") or ""),
                        points=points,
                        created_at=d.get("created_at"),
                    )
                )

            return out

        if MONGODB_ONLY_READS:
            # Mongo 可用但没有数据：强制不回退 SQLite。
            return []

    # Fallback SQLite
    with get_session() as session:
        rows = session.exec(select(TripDB).order_by(TripDB.id.desc())).all()
        return [_trip_to_read(session, row) for row in rows]


@app.get("/api/trips/{trip_id}", response_model=TripRead)
async def get_trip(trip_id: int):
    # Mongo-first
    if mongodb_available():
        doc = await asyncio.to_thread(get_location_card_from_mongo, trip_id)
        if doc:
            points_raw = doc.get("points") or []
            points: List[CheckInPointRead] = []
            if isinstance(points_raw, list):
                for i, p in enumerate(points_raw):
                    if not isinstance(p, dict):
                        continue
                    photo_ids: List[int] = []
                    ids_raw = p.get("image_ids") or []
                    if isinstance(ids_raw, list):
                        for x in ids_raw:
                            try:
                                v = int(x)
                                if v > 0:
                                    photo_ids.append(v)
                            except Exception:
                                continue

                    points.append(
                        CheckInPointRead(
                            id=i,
                            location_name=str(p.get("location_name") or ""),
                            latitude=float(p.get("latitude") or 0.0),
                            longitude=float(p.get("longitude") or 0.0),
                            coordinate_system=str(p.get("coordinate_system") or "GCJ-02"),
                            note=str(p.get("note") or ""),
                            photo_ids=photo_ids,
                            time=p.get("time"),
                        )
                    )

            return TripRead(
                id=int(doc.get("card_id")),
                title=str(doc.get("title") or ""),
                points=points,
                created_at=doc.get("created_at"),
            )

        if MONGODB_ONLY_READS:
            raise HTTPException(
                status_code=404,
                detail="Trip not found in MongoDB (MONGODB_ONLY_READS is enabled).",
            )

    # Fallback SQLite
    try:
        with get_session() as session:
            row = session.get(TripDB, trip_id)
            if row is None:
                raise HTTPException(status_code=404, detail="Trip not found.")
            return _trip_to_read(session, row)
    except HTTPException:
        raise
    except Exception as e:
        logger.exception("get_trip failed: %s", e)
        raise HTTPException(status_code=500, detail="Failed to load trip.") from e


@app.delete("/api/trips/{trip_id}")
async def delete_trip(trip_id: int, background_tasks: BackgroundTasks):
    if mongodb_available():
        await asyncio.to_thread(delete_location_card_from_mongo, trip_id)
    elif not USE_SQLITE:
        raise HTTPException(status_code=503, detail="MongoDB is not available.")

    if USE_SQLITE:
        # Explicitly delete child points first to avoid FK/cascade issues.
        with get_session() as session:
            session.exec(
                select(CheckInPointDB).where(CheckInPointDB.trip_id == trip_id)
            )  # keep session aware; selection not strictly needed
            pts = session.exec(
                select(CheckInPointDB).where(CheckInPointDB.trip_id == trip_id)
            ).all()
            for p in pts:
                session.delete(p)

            trip_row = session.get(TripDB, trip_id)
            if trip_row is not None:
                session.delete(trip_row)
            session.commit()

    background_tasks.add_task(_purge_unused_images_and_files_background)
    return {"status": "ok"}


async def enhance_cover_image(photo_id: int) -> None:
    """
    Placeholder: AI enhancement for a cover image.

    Must be non-blocking and safe to run multiple times. It writes a sidecar JSON
    next to the image, using atomic replace to avoid race conditions.
    """
    try:
        pid = int(photo_id)
    except Exception:
        return
    if pid <= 0:
        return

    try:
        with get_session() as session:
            photo: Optional[Photo] = session.get(Photo, pid)  # type: ignore[arg-type]
    except Exception as e:
        logger.error(f"Cover enhance failed: DB error: {e}", exc_info=True)
        return
    if not photo:
        return

    try:
        abs_path = _build_photo_path(photo.relative_path)
        if not abs_path.exists() or not abs_path.is_file():
            return

        sidecar_path = abs_path.with_suffix(".cover.json")
        if sidecar_path.exists():
            try:
                cached = json.loads(sidecar_path.read_text(encoding="utf-8"))
                done = bool(cached.get("enhanced"))
                if done:
                    return
            except Exception:
                pass

        payload = {
            "photo_id": photo.id,
            "filename": photo.filename,
            "relative_path": photo.relative_path,
            "url": f"/api/photos/{photo.id}/file",
            "enhanced": False,
            "message": "placeholder - enhancement not implemented yet",
            "generated_at": datetime.utcnow().isoformat(),
        }
        tmp_path = sidecar_path.with_suffix(".cover.json.tmp")
        tmp_path.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
        os.replace(tmp_path, sidecar_path)
    except Exception as e:
        logger.error(f"Cover enhance failed for photo_id={pid}: {e}", exc_info=True)

async def pre_process_vision_descriptions(photo_ids: List[int]) -> None:
    """
    After upload, generate AI vision descriptions for photos and write sidecar JSON files.
    Sidecar path: <photo_file>.json (same directory, same basename).
    """
    try:
        ids = [int(x) for x in photo_ids if isinstance(x, int) or (isinstance(x, str) and str(x).isdigit())]
    except Exception:
        ids = []
    ids = [x for x in ids if x > 0]
    if not ids:
        return

    api_key = os.environ.get("SILICONFLOW_API_KEY", "").strip()
    if not api_key:
        logger.info("Vision pre-process skipped: SILICONFLOW_API_KEY is not set.")
        return

    try:
        if USE_SQLITE:
            with get_session() as session:
                photos: List[Photo] = session.exec(
                    select(Photo).where(Photo.id.in_(ids))
                ).all()  # type: ignore[arg-type]
        else:
            from types import SimpleNamespace

            mongo_docs: Dict[str, Dict[str, Any]] = await asyncio.to_thread(
                get_enhanced_docs, ids
            )
            photos = []
            for pid_str, d in (mongo_docs or {}).items():
                try:
                    pid = int(pid_str)
                except Exception:
                    continue
                photos.append(
                    SimpleNamespace(
                        id=pid,
                        filename=d.get("filename") or "",
                        relative_path=d.get("relative_path") or "",
                        mime_type=d.get("mime_type") or "image/jpeg",
                        filesize=d.get("filesize") or 0,
                        created_at=d.get("created_at") or datetime.utcnow(),
                        updated_at=d.get("updated_at") or datetime.utcnow(),
                        description=merge_description(None, d),
                    )
                )
    except Exception as e:
        logger.error(f"Vision pre-process failed: DB query error: {e}", exc_info=True)
        return

    for photo in photos:
        try:
            abs_path = _build_photo_path(photo.relative_path)
            if not abs_path.exists() or not abs_path.is_file():
                logger.error(f"Vision pre-process skipped: file not found for photo_id={photo.id}: {abs_path}")
                continue

            sidecar_path = abs_path.with_suffix(".json")
            # 幂等性：如果 sidecar 已存在且包含 description，则跳过预处理，避免重复看图与竞态覆盖
            if sidecar_path.exists():
                try:
                    cached = json.loads(sidecar_path.read_text(encoding="utf-8"))
                    cached_desc = (cached.get("description") or "").strip()
                    if cached_desc:
                        # Sidecar 已有描述：Mongo 可能尚未写入（Mongo 启用较晚时常见）。
                        if mongodb_available() and photo.id is not None:
                            await asyncio.to_thread(
                                patch_enhanced,
                                img_id=int(photo.id),
                                base_photo={
                                    "filename": photo.filename,
                                    "relative_path": photo.relative_path,
                                    "mime_type": photo.mime_type,
                                    "filesize": photo.filesize,
                                    "created_at": photo.created_at,
                                    "updated_at": photo.updated_at,
                                    "description": photo.description,
                                },
                                patch={"description": cached_desc},
                            )
                        logger.info(
                            f"Skip vision pre-process: cache already exists for photo_id={photo.id}, json={sidecar_path}"
                        )
                        continue
                except Exception as e:
                    logger.info(
                        f"Vision pre-process: cache exists but invalid; will regenerate. photo_id={photo.id}, json={sidecar_path}, err={e}"
                    )

            content = abs_path.read_bytes()
            b64 = base64.b64encode(content).decode("utf-8")
            mime = (photo.mime_type or "image/jpeg").strip()
            image_data_url = f"data:{mime};base64,{b64}"

            # _call_siliconflow_vision is blocking (urllib); run in a thread.
            desc = await asyncio.to_thread(_call_siliconflow_vision, image_data_url, api_key)

            payload = {
                "photo_id": photo.id,
                "filename": photo.filename,
                "relative_path": photo.relative_path,
                "url": f"/api/photos/{photo.id}/file",
                "description": desc,
                "generated_at": datetime.utcnow().isoformat(),
                "provider": "siliconflow",
                "model": SILICONFLOW_VISION_MODEL,
            }
            # 原子写入：先写入临时文件，再 replace 为正式 sidecar，避免读到半截 JSON
            tmp_path = sidecar_path.with_suffix(".json.tmp")
            tmp_path.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
            os.replace(tmp_path, sidecar_path)

            # 同步写入 Mongo：让 Mongo 成为增强信息源（描述用于弹窗/排序等）。
            if mongodb_available() and photo.id is not None:
                await asyncio.to_thread(
                    patch_enhanced,
                    img_id=int(photo.id),
                    base_photo={
                        "filename": photo.filename,
                        "relative_path": photo.relative_path,
                        "mime_type": photo.mime_type,
                        "filesize": photo.filesize,
                        "created_at": photo.created_at,
                        "updated_at": photo.updated_at,
                        "description": photo.description,
                    },
                    patch={"description": desc},
                )
            logger.info(f"Vision pre-process success: photo_id={photo.id}, json={sidecar_path}")
        except Exception as e:
            logger.error(f"Vision pre-process failed for photo_id={getattr(photo, 'id', '?')}: {e}", exc_info=True)


async def pre_process_face_people(
    photo_ids: List[int],
    *,
    mode: str = "balanced",
    force: bool = False,
) -> None:
    """
    After upload, run face recognition and write people tags into Mongo (`img_people`).

    - Uses `ENCODINGS_FILE` as the source of enrolled identities.
    - Writes only when Mongo is available.
    - By default, does NOT overwrite existing non-empty `img_people` unless force=True.
    """
    if not mongodb_available():
        return

    # Fast exit when face_recognition isn't installed or no encodings exist.
    if getattr(organizer_logic, "face_recognition", None) is None:
        logger.info("Face pre-process skipped: face_recognition is not installed.")
        return

    try:
        enc_path = str(ENCODINGS_FILE)
        if not os.path.exists(enc_path) or os.path.getsize(enc_path) <= 0:
            logger.info("Face pre-process skipped: encodings file missing/empty.")
            return
    except Exception:
        return

    try:
        ids = [
            int(x)
            for x in photo_ids
            if isinstance(x, int) or (isinstance(x, str) and str(x).isdigit())
        ]
    except Exception:
        ids = []
    ids = [x for x in ids if x > 0]
    if not ids:
        return

    try:
        known_encodings, known_names = load_face_encodings(str(ENCODINGS_FILE))
    except Exception as e:
        logger.info(f"Face pre-process skipped: failed to load encodings: {e}")
        return

    if not known_encodings or not known_names:
        return

    mongo_docs: Dict[str, Dict[str, Any]] = await asyncio.to_thread(get_enhanced_docs, ids)

    for pid in ids:
        try:
            d = mongo_docs.get(str(pid)) or {}
            existing_people = extract_people(d) or []
            if (not force) and existing_people:
                continue

            rel = str(d.get("relative_path") or "")
            if not rel:
                base = await asyncio.to_thread(get_image_from_mongo, pid)
                rel = str((base or {}).get("relative_path") or "")
                if not rel:
                    continue

            abs_path = _build_photo_path(rel)
            if not abs_path.exists() or not abs_path.is_file():
                continue

            names = await asyncio.to_thread(
                recognize_faces, str(abs_path), known_encodings, known_names, mode
            )
            if not names:
                names = []
            # Normalize + drop unknown + unique
            final_names: List[str] = []
            seen: set[str] = set()
            for n in names:
                s = str(n).strip()
                if not s or s.lower() == "unknown":
                    continue
                if s not in seen:
                    seen.add(s)
                    final_names.append(s)

            base_photo = {
                "filename": str(d.get("filename") or ""),
                "relative_path": rel,
                "mime_type": d.get("mime_type", None),
                "filesize": d.get("filesize", None),
                "created_at": d.get("created_at") or datetime.utcnow(),
                "updated_at": d.get("updated_at") or datetime.utcnow(),
                "description": d.get("img_description", None),
            }
            await asyncio.to_thread(
                patch_enhanced,
                img_id=int(pid),
                base_photo=base_photo,
                patch={"person_names": final_names},
            )
        except Exception as e:
            logger.warning(f"Face pre-process failed for photo_id={pid}: {e}")


@app.get("/api/photos", response_model=List[PhotoRead])
async def list_photos(offset: int = 0, limit: int = 50):
    """List photos with basic pagination."""
    # Mongo-first
    if mongodb_available():
        docs = await asyncio.to_thread(list_images_from_mongo, offset, limit)
        if docs:
            out: List[PhotoRead] = []
            for d in docs:
                try:
                    pid = int(d.get("img_id"))
                except Exception:
                    continue
                out.append(
                    PhotoRead(
                        id=pid,
                        filename=str(d.get("filename") or ""),
                        description=merge_description(
                            None, d
                        ),
                        url=f"/api/photos/{pid}/file",
                        created_at=d.get("created_at"),
                        updated_at=d.get("updated_at"),
                    )
                )
            return out

        if MONGODB_ONLY_READS:
            # Mongo 可用但没有数据：强制不回退 SQLite。
            return []

    # Fallback to SQLite
    with get_session() as session:
        statement = (
            select(Photo)
            .order_by(Photo.created_at.desc())
            .offset(max(offset, 0))
            .limit(max(min(limit, 200), 1))
        )
        photos = session.exec(statement).all()

    return [
        PhotoRead(
            id=p.id,  # type: ignore[arg-type]
            filename=p.filename,
            description=p.description,
            url=f"/api/photos/{p.id}/file",  # type: ignore[union-attr]
            created_at=p.created_at,
            updated_at=p.updated_at,
        )
        for p in photos
    ]


@app.get("/api/photos-advanced", response_model=List[PhotoAdvancedRead])
async def list_photos_advanced(
    sort: str = "time",  # 'people' | 'location' | 'time'
    person: Optional[str] = None,
    offset: int = 0,
    limit: int = 200,
):
    """
    Returns photos enriched with people, location and taken_at metadata,
    supporting basic sorting and optional person filtering for the mobile gallery.
    """
    sort = (sort or "time").lower().strip()
    if sort not in {"people", "location", "time"}:
        sort = "time"

    target_person = (person or "").strip().lower()

    # Mongo-first: use Mongo docs for base + enhanced fields, no SQLite/EXIF/face fallback.
    if mongodb_available():
        docs = await asyncio.to_thread(list_images_from_mongo, offset, limit)
        enriched: List[PhotoAdvancedRead] = []

        for d in docs:
            try:
                pid = int(d.get("img_id"))
            except Exception:
                continue

            # Map Mongo document shape to API shape:
            # img_id, img_people, img_location.name, img_time.taken_at, created_at
            taken_at = extract_taken_at(d)
            created_at = d.get("created_at")
            if not isinstance(created_at, datetime):
                created_at = None
            taken_at_final = taken_at or created_at or datetime.fromtimestamp(0)

            location_raw = extract_location_name(d)
            location = (location_raw or "").strip() or None

            raw_people = extract_people(d) or []
            person_names: List[str] = []
            seen_people: set[str] = set()
            for p in raw_people:
                name = str(p).strip()
                if not name:
                    continue
                # Keep original display casing while deduping by lowercase.
                k = name.lower()
                if k in seen_people:
                    continue
                seen_people.add(k)
                person_names.append(name)

            if target_person:
                if not any(p.lower() == target_person for p in person_names):
                    continue

            enriched.append(
                PhotoAdvancedRead(
                    id=pid,
                    url=f"/api/photos/{pid}/file",
                    person_names=person_names,
                    location=location,
                    taken_at=taken_at_final,
                )
            )

        if sort == "location":
            enriched.sort(key=lambda p: (p.location or "").lower(), reverse=True)
        elif sort == "people":
            def _people_key(p: PhotoAdvancedRead):
                first = p.person_names[0].lower() if p.person_names else ""
                ts = p.taken_at.timestamp() if p.taken_at else 0.0
                return (first, -ts)

            enriched.sort(key=_people_key)
        else:  # time
            enriched.sort(key=lambda p: p.taken_at or datetime.fromtimestamp(0), reverse=True)

        return enriched

    # Fallback SQLite (only when Mongo is unavailable).
    if MONGODB_ONLY_READS:
        raise HTTPException(
            status_code=503,
            detail="MongoDB is required (MONGODB_ONLY_READS is enabled).",
        )
    with get_session() as session:
        statement = (
            select(Photo)
            .order_by(Photo.created_at.desc())
            .offset(max(offset, 0))
            .limit(max(min(limit, 500), 1))
        )
        photo_rows: List[Photo] = session.exec(statement).all()

    enriched: List[PhotoAdvancedRead] = []
    for row in photo_rows:
        if row.id is None:
            continue
        enriched.append(
            PhotoAdvancedRead(
                id=row.id,
                url=f"/api/photos/{row.id}/file",
                person_names=[],
                location=None,
                taken_at=row.created_at,
            )
        )
    return enriched


@app.get("/api/photos/{photo_id}", response_model=PhotoRead)
async def get_photo(photo_id: int):
    """Return metadata for a single photo."""
    # Mongo-first
    if mongodb_available():
        doc = await asyncio.to_thread(get_image_from_mongo, photo_id)
        if doc:
            return PhotoRead(
                id=photo_id,
                filename=str(doc.get("filename") or ""),
                description=merge_description(None, doc),
                url=f"/api/photos/{photo_id}/file",
                created_at=doc.get("created_at"),
                updated_at=doc.get("updated_at"),
            )

    # Fallback SQLite
    if MONGODB_ONLY_READS:
        raise HTTPException(
            status_code=503,
            detail="MongoDB is required (MONGODB_ONLY_READS is enabled).",
        )
    with get_session() as session:
        photo = session.get(Photo, photo_id)
        if not photo:
            raise HTTPException(status_code=404, detail="Photo not found.")

        mongo_docs: Dict[str, Dict[str, Any]] = {}
        if photo.id is not None:
            mongo_docs = await asyncio.to_thread(get_enhanced_docs, [photo.id])

        return PhotoRead(
            id=photo.id,  # type: ignore[arg-type]
            filename=photo.filename,
            description=merge_description(
                photo.description,
                mongo_docs.get(str(photo.id)) if photo.id is not None else None,
            ),
            url=f"/api/photos/{photo.id}/file",  # type: ignore[union-attr]
            created_at=photo.created_at,
            updated_at=photo.updated_at,
        )


@app.get("/api/photos/{photo_id}/file")
async def get_photo_file(photo_id: int):
    """Return the binary image data for a photo."""
    # Mongo-first
    if mongodb_available():
        doc = await asyncio.to_thread(get_image_from_mongo, photo_id)
        if doc and doc.get("relative_path"):
            relative_path = str(doc.get("relative_path"))
            absolute_path = _build_photo_path(relative_path)
            exists = absolute_path.exists() and absolute_path.is_file()

            _debug_log(
                "main.py:get_photo_file",
                "serving photo file (mongo)",
                {
                    "photo_id": photo_id,
                    "relative_path": relative_path,
                    "absolute_path": str(absolute_path),
                    "exists": exists,
                },
                hypothesis_id="H_image_request_path",
                run_id="pre-fix",
            )

            if not exists:
                raise HTTPException(
                    status_code=404, detail="Photo file not found on disk."
                )

            return FileResponse(
                absolute_path,
                media_type=str(doc.get("mime_type") or "image/jpeg"),
                filename=str(doc.get("filename") or "upload"),
            )

    # Fallback SQLite
    if MONGODB_ONLY_READS:
        raise HTTPException(
            status_code=503,
            detail="MongoDB is required (MONGODB_ONLY_READS is enabled).",
        )
    with get_session() as session:
        photo = session.get(Photo, photo_id)
        if not photo:
            # #region agent log
            _debug_log(
                "main.py:get_photo_file",
                "photo id not found in DB",
                {"photo_id": photo_id},
                hypothesis_id="H_missing_photo",
                run_id="pre-fix",
            )
            # #endregion
            raise HTTPException(status_code=404, detail="Photo not found.")

        absolute_path = _build_photo_path(photo.relative_path)
        exists = absolute_path.exists() and absolute_path.is_file()

        _debug_log(
            "main.py:get_photo_file",
            "serving photo file (sqlite)",
            {
                "photo_id": photo_id,
                "relative_path": photo.relative_path,
                "absolute_path": str(absolute_path),
                "exists": exists,
            },
            hypothesis_id="H_image_request_path",
            run_id="pre-fix",
        )

        if not exists:
            raise HTTPException(status_code=404, detail="Photo file not found on disk.")

        return FileResponse(
            absolute_path,
            media_type=photo.mime_type,
            filename=photo.filename,
        )


@app.patch("/api/photos/{photo_id}", response_model=PhotoRead)
async def update_photo(photo_id: int, payload: PhotoUpdate):
    """Update photo metadata such as description."""
    # Mongo-first (optional hard-mode via MONGODB_ONLY_READS).
    if mongodb_available():
        mongo_base = await asyncio.to_thread(get_image_from_mongo, photo_id)
        if mongo_base:
            description = payload.description
            if description is not None:
                created_at = mongo_base.get("created_at") or datetime.utcnow()
                updated_at = mongo_base.get("updated_at") or datetime.utcnow()
                await asyncio.to_thread(
                    patch_enhanced,
                    img_id=int(photo_id),
                    base_photo={
                        "filename": str(mongo_base.get("filename") or ""),
                        "relative_path": str(mongo_base.get("relative_path") or ""),
                        "mime_type": mongo_base.get("mime_type", None),
                        "filesize": mongo_base.get("filesize", None),
                        "created_at": created_at,
                        "updated_at": updated_at,
                        "description": mongo_base.get("img_description", None),
                    },
                    patch={"description": description},
                )

            mongo_docs = await asyncio.to_thread(get_enhanced_docs, [photo_id])
            mongo_doc = mongo_docs.get(str(photo_id))

            created_at = mongo_doc.get("created_at") if mongo_doc else mongo_base.get("created_at")
            updated_at = mongo_doc.get("updated_at") if mongo_doc else mongo_base.get("updated_at")

            # `PhotoRead` requires created_at/updated_at not-null.
            if created_at is None:
                created_at = datetime.utcnow()
            if updated_at is None:
                updated_at = datetime.utcnow()

            return PhotoRead(
                id=photo_id,
                filename=str(mongo_base.get("filename") or ""),
                description=merge_description(None, mongo_doc),
                url=f"/api/photos/{photo_id}/file",
                created_at=created_at,
                updated_at=updated_at,
            )

        if MONGODB_ONLY_READS:
            raise HTTPException(
                status_code=404,
                detail="Photo not found in MongoDB (MONGODB_ONLY_READS is enabled).",
            )

    # Fallback SQLite (only when Mongo exists but photo base doesn't, or read-only mode is disabled).
    with get_session() as session:
        photo = session.get(Photo, photo_id)
        if not photo:
            raise HTTPException(status_code=404, detail="Photo not found.")

        updated = False
        if payload.description is not None:
            photo.description = payload.description
            updated = True

        if updated:
            photo.updated_at = datetime.utcnow()
            session.add(photo)
            session.commit()
            session.refresh(photo)

    # Keep Mongo enhanced description in sync (Mongo is source of truth for enhanced photo fields).
    if payload.description is not None and photo.id is not None:
        await asyncio.to_thread(
            patch_enhanced,
            img_id=int(photo.id),
            base_photo={
                "filename": photo.filename,
                "relative_path": photo.relative_path,
                "mime_type": photo.mime_type,
                "filesize": photo.filesize,
                "created_at": photo.created_at,
                "updated_at": photo.updated_at,
            },
            patch={"description": payload.description},
        )

    mongo_docs: Dict[str, Dict[str, Any]] = {}
    if photo.id is not None:
        mongo_docs = await asyncio.to_thread(get_enhanced_docs, [photo.id])

    return PhotoRead(
        id=photo.id,  # type: ignore[arg-type]
        filename=photo.filename,
        description=merge_description(
            photo.description,
            mongo_docs.get(str(photo.id)) if photo.id is not None else None,
        ),
        url=f"/api/photos/{photo.id}/file",  # type: ignore[union-attr]
        created_at=photo.created_at,
        updated_at=photo.updated_at,
    )


class PhotoEnhancedRead(BaseModel):
    person_names: List[str] = []
    location: Optional[str] = None
    taken_at: Optional[datetime] = None
    description: Optional[str] = None


class PhotoEnhancedUpdate(BaseModel):
    person_names: Optional[List[str]] = None
    taken_at: Optional[datetime] = None
    location: Optional[str] = None
    description: Optional[str] = None


@app.get("/api/photos/{photo_id}/enhanced", response_model=PhotoEnhancedRead)
async def get_photo_enhanced(photo_id: int):
    if mongodb_available():
        mongo_docs = await asyncio.to_thread(get_enhanced_docs, [photo_id])
        mongo_doc = mongo_docs.get(str(photo_id))
        if mongo_doc:
            return PhotoEnhancedRead(
                person_names=extract_people(mongo_doc) or [],
                location=extract_location_name(mongo_doc),
                taken_at=extract_taken_at(mongo_doc),
                description=merge_description(None, mongo_doc),
            )

        if MONGODB_ONLY_READS:
            raise HTTPException(
                status_code=404,
                detail="Photo not found in MongoDB (MONGODB_ONLY_READS is enabled).",
            )

    # Fallback SQLite for legacy mode.
    with get_session() as session:
        photo = session.get(Photo, photo_id)
        if not photo:
            raise HTTPException(status_code=404, detail="Photo not found.")

    mongo_docs: Dict[str, Dict[str, Any]] = {}
    if photo.id is not None:
        mongo_docs = await asyncio.to_thread(get_enhanced_docs, [photo.id])

    mongo_doc = mongo_docs.get(str(photo.id)) if photo.id is not None else None

    return PhotoEnhancedRead(
        person_names=extract_people(mongo_doc) or [],
        location=extract_location_name(mongo_doc),
        taken_at=extract_taken_at(mongo_doc) or photo.created_at,
        description=merge_description(photo.description, mongo_doc),
    )


@app.patch("/api/photos/{photo_id}/enhanced", response_model=PhotoEnhancedRead)
async def patch_photo_enhanced(photo_id: int, payload: PhotoEnhancedUpdate):
    payload_map: Dict[str, Any]
    if hasattr(payload, "model_dump"):
        payload_map = payload.model_dump(exclude_unset=True)  # type: ignore[attr-defined]
    else:
        payload_map = payload.dict(exclude_unset=True)  # type: ignore[call-arg]

    patch: Dict[str, Any] = {}
    for k in ["person_names", "taken_at", "location", "description"]:
        if k in payload_map:
            patch[k] = payload_map.get(k)

    if not patch:
        return await get_photo_enhanced(photo_id)

    # Mongo-first patch path.
    if mongodb_available():
        mongo_base = await asyncio.to_thread(get_image_from_mongo, photo_id)
        if mongo_base:
            created_at = mongo_base.get("created_at") or datetime.utcnow()
            updated_at = mongo_base.get("updated_at") or datetime.utcnow()
            photo_base = {
                "filename": str(mongo_base.get("filename") or ""),
                "relative_path": str(mongo_base.get("relative_path") or ""),
                "mime_type": mongo_base.get("mime_type", None),
                "filesize": mongo_base.get("filesize", None),
                "description": mongo_base.get("img_description", None),
                "created_at": created_at,
                "updated_at": updated_at,
            }

            await asyncio.to_thread(
                patch_enhanced,
                img_id=int(photo_id),
                base_photo=photo_base,
                patch=patch,
            )

            mongo_docs: Dict[str, Dict[str, Any]] = await asyncio.to_thread(
                get_enhanced_docs, [photo_id]
            )
            mongo_doc = mongo_docs.get(str(photo_id))

            return PhotoEnhancedRead(
                person_names=extract_people(mongo_doc) or [],
                location=extract_location_name(mongo_doc),
                taken_at=extract_taken_at(mongo_doc),
                description=merge_description(None, mongo_doc),
            )

        if MONGODB_ONLY_READS:
            raise HTTPException(
                status_code=404,
                detail="Photo not found in MongoDB (MONGODB_ONLY_READS is enabled).",
            )

    # Fallback SQLite patch path (legacy mode).
    with get_session() as session:
        photo = session.get(Photo, photo_id)
        if not photo:
            raise HTTPException(status_code=404, detail="Photo not found.")

        photo_base = {
            "filename": photo.filename,
            "relative_path": photo.relative_path,
            "mime_type": photo.mime_type,
            "filesize": photo.filesize,
            "description": photo.description,
            "created_at": photo.created_at,
            "updated_at": photo.updated_at,
        }

    await asyncio.to_thread(
        patch_enhanced,
        img_id=int(photo_id),
        base_photo=photo_base,
        patch=patch,
    )

    mongo_docs: Dict[str, Dict[str, Any]] = await asyncio.to_thread(
        get_enhanced_docs, [photo_id]
    )
    mongo_doc = mongo_docs.get(str(photo_id))

    return PhotoEnhancedRead(
        person_names=extract_people(mongo_doc) or [],
        location=extract_location_name(mongo_doc),
        taken_at=extract_taken_at(mongo_doc),
        description=merge_description(photo_base.get("description"), mongo_doc),
    )


@app.delete("/api/photos/{photo_id}")
async def delete_photo(photo_id: int):
    """Delete a photo and its file."""
    if mongodb_available():
        doc = await asyncio.to_thread(get_image_from_mongo, photo_id)
        if not doc:
            raise HTTPException(status_code=404, detail="Photo not found in MongoDB.")

        relative_path = doc.get("relative_path") or ""
        if str(relative_path).strip():
            delete_photo_file(str(relative_path))

        await asyncio.to_thread(delete_image_from_mongo, photo_id)

    if USE_SQLITE:
        # Best-effort: keep sqlite table in sync (only if sqlite is enabled).
        with get_session() as session:
            photo = session.get(Photo, photo_id)
            if photo:
                delete_photo_file(photo.relative_path)
                session.delete(photo)
                session.commit()

    return {"status": "ok"}


# UPDATED: Endpoint now handles batch enrollment of multiple people.
@app.post("/api/add-person")
async def add_person_endpoint(request: BatchEnrollmentRequest, background_tasks: BackgroundTasks):
    """
    Accepts a batch of people and their images, copies them to the
    enrollment directory, and then triggers the background enrollment task.
    """
    from enrollment_logic import update_encodings
    newly_created_dirs = []
    try:
        for person_data in request.people_to_enroll:
            person_name = person_data.person_name
            # Sanitize person_name to create a valid directory name
            sanitized_name = "".join(c for c in person_name if c.isalnum() or c in (' ', '_', '-')).rstrip()
            if not sanitized_name:
                raise HTTPException(status_code=400, detail=f"Invalid person name provided: {person_name}")

            person_dir = os.path.join(ENROLLMENT_FOLDER, sanitized_name)
            os.makedirs(person_dir, exist_ok=True)
            newly_created_dirs.append(person_dir)

            for image_path in person_data.image_paths:
                if os.path.exists(image_path):
                    shutil.copy(image_path, person_dir)
                else:
                    # Log a warning but don't stop the whole batch
                    print(f"Warning: Image path not found, skipping: {image_path}")

        # Start the background task, passing the list of directories to be cleaned up on abort.
        background_tasks.add_task(run_enrollment_task, newly_created_dirs)

        return {"message": "Batch enrollment process started successfully."}
    except Exception as e:
        # If setup fails, clean up any directories that were created
        for d in newly_created_dirs:
            if os.path.isdir(d):
                shutil.rmtree(d)
        raise HTTPException(status_code=500, detail=f"Failed to prepare for enrollment: {e}")


@app.post("/api/enrollment/upload-person")
async def upload_person_for_enrollment(
    background_tasks: BackgroundTasks,
    person_name: str = Form(...),
    images: List[UploadFile] = File(...),
):
    """
    移动端专用的人脸录入接口：

    - 通过 multipart/form-data 上传若干张图片
    - 将图片保存到 ENROLLMENT_FOLDER/<person_name> 目录下
    - 触发异步的 AI 录入任务（update_encodings）
    """
    newly_created_dirs: List[str] = []
    try:
        # 与批量接口保持一致的姓名清洗规则
        sanitized_name = "".join(c for c in person_name if c.isalnum() or c in (' ', '_', '-')).rstrip()
        if not sanitized_name:
            raise HTTPException(status_code=400, detail=f"Invalid person name provided: {person_name}")

        person_dir = os.path.join(ENROLLMENT_FOLDER, sanitized_name)
        os.makedirs(person_dir, exist_ok=True)
        newly_created_dirs.append(person_dir)

        if not images:
            raise HTTPException(status_code=400, detail="No images were uploaded for enrollment.")

        for upload in images:
            filename = upload.filename or "image.jpg"
            # 简单防御：避免路径穿越
            filename = os.path.basename(filename)
            target_path = os.path.join(person_dir, filename)

            with open(target_path, "wb") as f:
                content = await upload.read()
                f.write(content)

        # 触发后台录入任务
        background_tasks.add_task(run_enrollment_task, newly_created_dirs)

        return {"message": f"Upload received for '{sanitized_name}'. Enrollment started."}
    except HTTPException:
        # 直接抛出上面的 HTTPException
        raise
    except Exception as e:
        for d in newly_created_dirs:
            if os.path.isdir(d):
                shutil.rmtree(d, ignore_errors=True)
        raise HTTPException(status_code=500, detail=f"Failed to upload enrollment images: {e}")


# --- SiliconFlow Chat Completions (OpenAI 兼容) ---
# 文档: https://docs.siliconflow.cn/cn/api-reference/chat-completions/chat-completions
SILICONFLOW_BASE_URL = "https://api.siliconflow.cn/v1"
SILICONFLOW_CHAT_MODEL = "Pro/zai-org/GLM-4.7"
# 视觉模型，用于多图描述提取（看图）
# 阿里开源的最新视觉大模型，识别极其精准
SILICONFLOW_VISION_MODEL = "Qwen/Qwen2-VL-72B-Instruct"

VISION_SYSTEM_PROMPT = "你是一个敏锐的观察者。请详细描述这张照片中的内容、人物状态、环境氛围、天气和光线。仅输出描述文本。"

STORY_SYSTEM_PROMPT = """你是一个顶级的内容创作者和散文作家。
你的任务是根据【用户指令】创作或润色文章。

【绝对规则】：
1. 你必须将【照片细节】作为你创作的核心事实依据。请将照片中提到的环境、光线、物品、人物动作等视觉元素，巧妙且具象地融入到你的字里行间，让读者产生强烈的画面感。
2. 如果用户提供了【当前已有草稿】，请保留原作者的核心情感和意图，但必须把【照片细节】作为新的补充信息交织进去。
3. 不要像机器一样罗列元素，要用充满情绪价值的文学语言包装它们（例如日记、游记或散文风格）。
4. 直接输出最终正文，绝对不要包含“这是一篇为您撰写的文章”等废话前后缀。"""


def _call_siliconflow_vision(image_data_url: str, api_key: str) -> str:
    """同步调用 SiliconFlow chat/completions（视觉模型），传入单张图片 Data URL，返回描述文本。"""
    import urllib.request
    import urllib.error
    # OpenAI 兼容格式：content 为数组，包含 image_url + text
    messages = [
        {"role": "system", "content": VISION_SYSTEM_PROMPT},
        {
            "role": "user",
            "content": [
                {"type": "image_url", "image_url": {"url": image_data_url, "detail": "high"}},
                {"type": "text", "text": "请描述这张照片。"},
            ],
        },
    ]
    req_body = json.dumps({
        "model": SILICONFLOW_VISION_MODEL,
        "messages": messages,
        "max_tokens": 1024,
        "temperature": 0.3,
    }).encode("utf-8")
    req = urllib.request.Request(
        f"{SILICONFLOW_BASE_URL}/chat/completions",
        data=req_body,
        headers={
            "Content-Type": "application/json",
            "Authorization": f"Bearer {api_key}",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            data = json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8") if e.fp else ""
        logger.error(f"SiliconFlow Vision API HTTPError: {body or str(e)}")
        raise HTTPException(status_code=500, detail=f"SiliconFlow Vision API 错误: {body or str(e)}")
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"SiliconFlow Vision 请求失败（如网络错误）: {e}")
    choices = data.get("choices") or []
    if not choices:
        raise HTTPException(status_code=500, detail="SiliconFlow Vision 未返回有效内容。")
    content = (choices[0].get("message") or {}).get("content") or ""
    return content.strip()


def _call_siliconflow_chat(messages: List[Dict], api_key: str) -> str:
    """同步调用 SiliconFlow chat/completions，返回 assistant 的 content。"""
    import urllib.request
    import urllib.error
    import socket
    req_body = json.dumps({
        "model": SILICONFLOW_CHAT_MODEL,
        "messages": messages,
        "max_tokens": 2048,
        "temperature": 0.7,
    }).encode("utf-8")
    req = urllib.request.Request(
        f"{SILICONFLOW_BASE_URL}/chat/completions",
        data=req_body,
        headers={
            "Content-Type": "application/json",
            "Authorization": f"Bearer {api_key}",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            raw = resp.read()
            text = raw.decode("utf-8", errors="replace")
            try:
                data = json.loads(text)
            except json.JSONDecodeError as je:
                logger.error(
                    f"SiliconFlow chat JSON decode failed: status={getattr(resp, 'status', None)} body={text}",
                    exc_info=True,
                )
                raise HTTPException(
                    status_code=502,
                    detail="SiliconFlow chat 返回非 JSON 响应（详见后端日志）",
                )
    except urllib.error.HTTPError as e:
        body = ""
        try:
            body = e.read().decode("utf-8", errors="replace") if getattr(e, "fp", None) else ""
        except Exception:
            body = ""
        logger.error(
            f"SiliconFlow chat HTTPError: status={getattr(e, 'code', None)}, body={body}",
            exc_info=True,
        )
        raise HTTPException(
            status_code=502,
            detail=f"SiliconFlow chat HTTPError: status={getattr(e, 'code', None)}（详见后端日志）",
        )
    except (urllib.error.URLError, socket.timeout) as e:
        logger.error(f"SiliconFlow chat network error: {e}", exc_info=True)
        raise HTTPException(status_code=502, detail="SiliconFlow chat 网络错误/超时（详见后端日志）")
    except Exception as e:
        logger.error(f"SiliconFlow chat unexpected error: {e}", exc_info=True)
        raise HTTPException(status_code=500, detail="SiliconFlow chat 调用异常（详见后端日志）")
    choices = data.get("choices") or []
    if not choices:
        logger.error(f"SiliconFlow returned no choices. raw={json.dumps(data, ensure_ascii=False)[:2000]}")
        raise HTTPException(status_code=502, detail="SiliconFlow returned no choices（详见后端日志）")
    content = (choices[0].get("message") or {}).get("content") or ""
    return content


def _looks_like_photo_search(text: str) -> bool:
    t = (text or "").strip().lower()
    if not t:
        return False
    keywords = [
        "找",
        "寻找",
        "搜索",
        "查找",
        "帮我找",
        "给我找",
        "找出",
        "照片",
        "图片",
        "相片",
        "图",
        "image",
        "photo",
        "pics",
        "picture",
    ]
    return any(k in t for k in keywords)


def _extract_json_id_list(raw: str) -> List[int]:
    """
    Best-effort extraction of a JSON array of ids from model output.
    Accepts formats like: [1,2,3] or {"ids":[1,2]} or text with a JSON snippet inside.
    """
    s = (raw or "").strip()
    if not s:
        return []

    def _parse(obj: Any) -> List[int]:
        if isinstance(obj, list):
            out: List[int] = []
            for x in obj:
                try:
                    v = int(x)
                    if v > 0:
                        out.append(v)
                except Exception:
                    continue
            return out
        if isinstance(obj, dict):
            for key in ("ids", "img_ids", "image_ids", "photo_ids"):
                if key in obj:
                    return _parse(obj.get(key))
        return []

    try:
        return _parse(json.loads(s))
    except Exception:
        pass

    try:
        import re

        m = re.search(r"\[[\s\S]*?\]", s)
        if m:
            return _parse(json.loads(m.group(0)))
    except Exception:
        pass

    try:
        import re

        m2 = re.search(r"\{[\s\S]*\}", s)
        if m2:
            return _parse(json.loads(m2.group(0)))
    except Exception:
        pass
    return []


async def _ai_smart_search_photos(
    *,
    user_query: str,
    api_key: str,
    top_k: int = 8,
    max_scan: int = 20000,
) -> List[SmartSearchPhoto]:
    if not mongodb_available():
        raise HTTPException(status_code=503, detail="MongoDB is not available.")

    all_items: List[Dict[str, Any]] = []
    offset = 0
    page_size = 2000
    while offset < max_scan:
        page = await asyncio.to_thread(
            list_image_search_items_from_mongo,
            offset=offset,
            limit=page_size,
        )
        if not page:
            break
        all_items.extend(page)
        offset += len(page)
        if len(page) < page_size:
            break

    if not all_items:
        return []

    q = (user_query or "").strip()
    q_terms = [t for t in q.replace("，", " ").replace(",", " ").split() if t.strip()]
    if not q_terms and q:
        q_terms = [q]

    def _item_text(d: Dict[str, Any]) -> str:
        desc = (d.get("img_description") or "") if isinstance(d, dict) else ""
        people = d.get("img_people") if isinstance(d, dict) else None
        loc = d.get("img_location") if isinstance(d, dict) else None
        loc_name = ""
        if isinstance(loc, dict):
            loc_name = str(loc.get("name") or "")
        ppl = ""
        if isinstance(people, list):
            ppl = " ".join(str(x) for x in people if x is not None)
        fn = str(d.get("filename") or "")
        return " ".join(x for x in [str(desc), ppl, loc_name, fn] if x)

    filtered: List[Dict[str, Any]] = []
    if q_terms:
        for d in all_items:
            txt = _item_text(d)
            if not txt:
                continue
            if any(term in txt for term in q_terms if term):
                filtered.append(d)

    candidates = filtered if filtered else all_items
    candidates = candidates[:2000]

    chunk_size = 80
    chunks: List[List[Dict[str, Any]]] = [
        candidates[i : i + chunk_size] for i in range(0, len(candidates), chunk_size)
    ]

    system_prompt = (
        "你是一个照片检索助手。用户会提出找图请求，你会在候选图片的【描述文本/人物/地点/文件名】里挑选最匹配的图片。\n"
        "输出必须是严格 JSON：只输出一个数组，元素为匹配的 img_id（整数）。不要输出任何额外文字。\n"
        "规则：宁缺毋滥；如果没有匹配就输出空数组 []。\n"
        f"尽量返回最相关的前 {int(top_k)} 个。"
    )

    chosen_ids: List[int] = []
    seen: Set[int] = set()

    for ch in chunks:
        lines: List[str] = []
        for d in ch:
            img_id = d.get("img_id")
            try:
                pid = int(img_id)
            except Exception:
                continue
            desc = d.get("img_description")
            if desc is None:
                desc = ""
            desc = str(desc).replace("\n", " ").strip()
            people = d.get("img_people")
            ppl = ""
            if isinstance(people, list) and people:
                ppl = ",".join(str(x) for x in people if x is not None)[:120]
            loc = d.get("img_location")
            loc_name = ""
            if isinstance(loc, dict):
                loc_name = str(loc.get("name") or "")
            filename = str(d.get("filename") or "")
            lines.append(
                f"- img_id={pid}; people={ppl}; location={loc_name}; filename={filename}; desc={desc[:220]}"
            )

        if not lines:
            continue

        user_content = "用户请求：\n" + q + "\n\n候选图片：\n" + "\n".join(lines)
        raw = await asyncio.to_thread(
            _call_siliconflow_chat,
            [
                {"role": "system", "content": system_prompt},
                {"role": "user", "content": user_content},
            ],
            api_key,
        )
        ids = _extract_json_id_list(raw)
        for pid in ids:
            if pid not in seen:
                chosen_ids.append(pid)
                seen.add(pid)
            if len(chosen_ids) >= top_k:
                break
        if len(chosen_ids) >= top_k:
            break

    if not chosen_ids:
        return []

    index_by_id: Dict[int, Dict[str, Any]] = {}
    for d in candidates:
        try:
            pid = int(d.get("img_id"))
        except Exception:
            continue
        if pid not in index_by_id:
            index_by_id[pid] = d

    out: List[SmartSearchPhoto] = []
    for pid in chosen_ids[:top_k]:
        d = index_by_id.get(pid, {})
        desc = d.get("img_description") if isinstance(d, dict) else None
        people = d.get("img_people") if isinstance(d, dict) else None
        loc = d.get("img_location") if isinstance(d, dict) else None
        t = d.get("img_time") if isinstance(d, dict) else None
        taken_at = None
        if isinstance(t, dict):
            v = t.get("taken_at")
            if isinstance(v, datetime):
                taken_at = v
        loc_name = None
        if isinstance(loc, dict):
            loc_name = str(loc.get("name") or "") if loc.get("name") is not None else None
        person_names: List[str] = []
        if isinstance(people, list):
            person_names = [str(x) for x in people if x is not None]

        out.append(
            SmartSearchPhoto(
                id=int(pid),
                url=f"/api/photos/{int(pid)}/file",
                description=(str(desc).strip() if desc is not None else None),
                person_names=person_names,
                location=loc_name,
                taken_at=taken_at,
            )
        )
    return out


@app.post("/api/ai/chat")
async def ai_chat(request: AIChatRequest) -> AIChatResponse:
    """
    代理到 SiliconFlow 的 chat/completions，用于 AI 助手对话。
    需要环境变量 SILICONFLOW_API_KEY。
    """
    api_key = os.environ.get("SILICONFLOW_API_KEY", "").strip()
    if not api_key:
        raise HTTPException(
            status_code=503,
            detail="SILICONFLOW_API_KEY is not set. Please set it in the environment or backend config.",
        )
    messages = [{"role": m.role, "content": m.content} for m in request.messages]

    latest_user_text = ""
    for m in reversed(request.messages or []):
        if (m.role or "").lower() == "user":
            latest_user_text = m.content or ""
            break
    if _looks_like_photo_search(latest_user_text):
        try:
            photos = await _ai_smart_search_photos(
                user_query=latest_user_text,
                api_key=api_key,
                top_k=8,
            )
        except HTTPException:
            raise
        except Exception as e:
            logger.error(f"Smart search failed: {e}", exc_info=True)
            photos = []

        if photos:
            brief_lines: List[str] = []
            for p in photos:
                d = (p.description or "").strip()
                if d and len(d) > 60:
                    d = d[:60] + "…"
                brief_lines.append(f"- #{p.id} {d}".rstrip())
            brief = "我找到了这些可能匹配的照片：\n" + "\n".join(brief_lines)
            return AIChatResponse(content=brief, photos=photos)
        return AIChatResponse(
            content="我在当前图库的描述信息里没有找到明确匹配的照片。你可以再补充一些特征（时间/地点/人物/动作/颜色等）我再帮你找。",
            photos=[],
        )

    if request.person_context:
        system_content = (
            f"你是 MemoirsCore 照片整理应用的 AI 助手。当前用户正在询问关于「{request.person_context}」这位人物的照片或相关需求，请结合照片整理、人脸识别等场景友好回答。"
        )
        messages = [{"role": "system", "content": system_content}] + messages
    else:
        messages = [
            {"role": "system", "content": "你是 MemoirsCore 照片整理应用的 AI 助手，可以帮用户找照片、生成描述、给出整理建议。请简洁友好地回答。"},
        ] + messages
    try:
        content = await asyncio.to_thread(_call_siliconflow_chat, messages, api_key)
    except HTTPException:
        raise
    return AIChatResponse(content=content)


@app.post("/api/ai/generate-story")
async def generate_story(
    user_prompt: str = Form(..., description="用户指令，用于指导故事风格或重点"),
    time_context: str = Form(default="", description="发生时间等时间语境"),
    existing_text: str = Form(default="", description="已有草稿，用于润色或续写"),
    existing_image_ids: str = Form(default="", description="已有照片的 ID 列表，逗号分隔"),
    files: List[UploadFile] = File(default=[], description="多张图片，用于视觉描述"),
):
    """
    两步链式调用：先对多图做 Vision 描述（可选人脸识别），再融合时间与用户指令生成回忆散文。
    返回 JSON: {"generated_text": "..."}。
    异常时返回 500 及清晰错误信息（如无 API key、网络错误）。
    """
    api_key = os.environ.get("SILICONFLOW_API_KEY", "").strip()
    if not api_key:
        raise HTTPException(
            status_code=500,
            detail="SILICONFLOW_API_KEY 未设置，请在环境变量或后端配置中设置。",
        )

    vision_context = ""
    try:
        # Step 1: 多图描述提取 (Vision)
        parts: List[str] = []

        # 1) 新上传的图片 files
        if files:
            for upload in files:
                if not upload.content_type or not upload.content_type.startswith("image/"):
                    continue
                raw = await upload.read()
                if not raw:
                    continue
                mime_type = upload.content_type or "image/jpeg"
                b64_data = base64.b64encode(raw).decode("utf-8")
                image_payload = f"data:{mime_type};base64,{b64_data}"
                try:
                    desc = await asyncio.to_thread(_call_siliconflow_vision, image_payload, api_key)
                except HTTPException as he:
                    logger.error(f"Vision API 调用失败（上传图片）: {he.detail}")
                    continue

                filename = upload.filename or "upload"
                parts.append(f"【图】{desc}")

                # 写入同名 JSON 元数据（此处上传图片路径未知，记录在系统临时目录）
                try:
                    meta = {
                        "filename": filename,
                        "description": desc,
                        "time": datetime.utcnow().isoformat(),
                    }
                    tmp_dir = Path(tempfile.gettempdir())
                    json_path = tmp_dir / f"{Path(filename).stem}.json"
                    json_path.write_text(json.dumps(meta, ensure_ascii=False, indent=2), encoding="utf-8")
                    logger.info(f"📸 照片 [{filename}] Vision 描述已生成并写入: {json_path} -> {desc}")
                except Exception as e:
                    logger.error(f"写入上传图片元数据 JSON 失败 [{filename}]: {e}")

        # 2) 依据 existing_image_ids 读取已有照片文件
        ids: List[int] = []
        if existing_image_ids.strip():
            try:
                ids = [int(x) for x in existing_image_ids.split(",") if x.strip().isdigit()]
            except Exception:
                ids = []

        if ids:
            if USE_SQLITE:
                with get_session() as session:
                    photo_rows = session.exec(select(Photo).where(Photo.id.in_(ids))).all()
            else:
                from types import SimpleNamespace

                mongo_docs: Dict[str, Dict[str, Any]] = (
                    await asyncio.to_thread(get_enhanced_docs, ids)
                )
                photo_rows = []
                for pid in ids:
                    d = mongo_docs.get(str(pid))
                    if not d:
                        continue
                    photo_rows.append(
                        SimpleNamespace(
                            id=pid,
                            filename=d.get("filename") or "",
                            relative_path=d.get("relative_path") or "",
                            mime_type=d.get("mime_type") or "image/jpeg",
                        )
                    )

            for photo in photo_rows:
                try:
                    # 核心修复：直接使用全局的 PHOTOS_DIR 拼接 relative_path
                    image_path = (PHOTOS_DIR / photo.relative_path).resolve()
                    
                    if not image_path.is_file():
                        logger.error(f"existing_image_ids 中的文件不存在: {image_path}")
                        continue

                    json_path = image_path.with_suffix(".json")
                    
                    # 检查缓存：如果存在同名 JSON，直接读取并跳过 Vision API
                    if json_path.exists():
                        try:
                            cached = json.loads(json_path.read_text(encoding="utf-8"))
                            cached_desc = (cached.get("description") or "").strip()
                            if cached_desc:
                                logger.info(f"⚡ 命中缓存: 已从 {json_path.name} 读取 [{photo.filename}] 的描述")
                                parts.append(f"【图】{cached_desc}")
                                continue
                        except Exception as e:
                            logger.error(f"读取/解析缓存 JSON 失败，将重新走 Vision [{photo.filename}]: {e}")

                    # 如果没有命中缓存，则重新调用 Vision
                    raw = image_path.read_bytes()
                    if not raw:
                        continue
                    mime_type = photo.mime_type or "image/jpeg"
                    b64_data = base64.b64encode(raw).decode("utf-8")
                    image_payload = f"data:{mime_type};base64,{b64_data}"
                    
                    try:
                        desc = await asyncio.to_thread(_call_siliconflow_vision, image_payload, api_key)
                    except HTTPException as he:
                        logger.error(f"Vision API 调用失败（已有图片 ID={photo.id}）: {he.detail}")
                        continue

                    parts.append(f"【图】{desc}")

                    # 重新生成并覆盖 JSON 元数据
                    try:
                        meta = {
                            "photo_id": photo.id,
                            "filename": photo.filename,
                            "relative_path": photo.relative_path,
                            "url": f"/api/photos/{photo.id}/file",
                            "description": desc,
                            "generated_at": datetime.utcnow().isoformat(),
                        }
                        json_path.write_text(json.dumps(meta, ensure_ascii=False, indent=2), encoding="utf-8")
                        logger.info(f"📸 缓存未命中，重新生成并写入: {json_path.name}")
                    except Exception as e:
                        logger.error(f"写入图片 JSON 失败 [id={photo.id}]: {e}")
                
                except Exception as e:
                    logger.error(f"处理 existing_image_ids 中的照片失败 [id={getattr(photo, 'id', '?')}]: {e}")

        vision_context = "\n".join(parts) if parts else ""

        logger.info(f"[DEBUG] Vision 解析结果: {vision_context}")

        # Step 2: 语境融合与风格化写作 (Text Generation)
        user_message = f"""【发生时间】: {time_context or '未提供'}
【照片细节】: {vision_context or '无'}
【当前已有草稿】: {existing_text or '无'}
【用户指令】: {user_prompt}"""
        messages = [
            {"role": "system", "content": STORY_SYSTEM_PROMPT},
            {"role": "user", "content": user_message},
        ]
        try:
            content = await asyncio.to_thread(_call_siliconflow_chat, messages, api_key)
        except HTTPException as he:
            logger.error(
                f"generate_story failed during chat: status={he.status_code} detail={he.detail}",
                exc_info=True,
            )
            raise HTTPException(status_code=500, detail=f"生成故事失败（详见后端日志）：{he.detail}")
        except Exception as e:
            logger.error(f"generate_story crashed during chat: {e}", exc_info=True)
            raise HTTPException(status_code=500, detail="生成故事失败（详见后端日志）")

        return {"generated_text": (content or "").strip()}
    except HTTPException as he:
        logger.error(
            f"generate_story HTTPException: status={he.status_code} detail={he.detail}",
            exc_info=True,
        )
        raise
    except Exception as e:
        logger.error(f"generate_story unexpected error: {e}", exc_info=True)
        raise HTTPException(status_code=500, detail="生成故事时发生未知错误（详见后端日志）")


@app.post("/api/abort-process")
async def abort_process():
    """Sets all cancellation events and sends an immediate confirmation to the UI."""
    print("ABORT REQUEST RECEIVED: Setting cancellation events.")
    for event in cancellation_events.values():
        event.set()
    
    # Immediately send a confirmation back to the UI via the log stream
    # This provides instant feedback that the signal was received.
    update_status_callback({
        "progress": 100, 
        "message": "Abort signal received by backend. Awaiting task termination...", 
        "status": "warning",
        "source": "system" # Use a neutral source
    })
    return {"status": "success", "message": "Abort signal sent to all running tasks."}

@app.get("/api/health")
async def health_check():
    """Simple health check endpoint to verify the server is ready to accept requests."""
    return {"status": "ok"}

@app.get("/api/check-dependencies")
async def check_dependencies():
    """Checks for the presence of optional heavy dependencies like face_recognition."""
    # MODIFIED: Access the variable through the module to get its current state.
    return {"face_recognition_installed": organizer_logic.face_recognition is not None}

@app.get("/api/enrollment-status")
async def get_enrollment_status():
    """Checks if a face encodings file exists and returns the number of enrolled people."""
    if os.path.exists(ENCODINGS_FILE) and os.path.getsize(ENCODINGS_FILE) > 0:
        try:
            _, known_names = load_face_encodings(ENCODINGS_FILE)
            enrolled_count = len(set(known_names))
            return {"is_enrolled": enrolled_count > 0, "enrolled_count": enrolled_count}
        except Exception as e:
            # If file is corrupt or invalid
            print(f"Error reading encodings file: {e}")
            return {"is_enrolled": False, "enrolled_count": 0}
    return {"is_enrolled": False, "enrolled_count": 0}

@app.get("/api/enrolled-faces")
async def get_enrolled_faces():
    """
    Scans the enrollment directory and returns a list of enrolled people
    with the count of their images.
    """
    enrolled_data = []
    if not os.path.isdir(ENROLLMENT_FOLDER):
        return {"enrolled_faces": []}

    try:
        for person_name in os.listdir(ENROLLMENT_FOLDER):
            person_dir = os.path.join(ENROLLMENT_FOLDER, person_name)
            if os.path.isdir(person_dir):
                # Count only files, ignore potential subdirectories
                image_count = len([
                    f for f in os.listdir(person_dir)
                    if os.path.isfile(os.path.join(person_dir, f))
                ])
                enrolled_data.append({"name": person_name, "count": image_count})
        
        # Sort by name for a consistent order in the UI
        enrolled_data.sort(key=lambda x: x['name'].lower())
        return {"enrolled_faces": enrolled_data}
    except Exception as e:
        print(f"Error scanning enrollment folder: {e}")
        raise HTTPException(status_code=500, detail="Failed to retrieve enrolled faces.")


@app.get("/api/enrolled-faces/{person_name}/images")
async def get_enrolled_person_images(person_name: str):
    """
    返回某个已录入人物下所有原始图片的文件名和可访问 URL。
    """
    # 与录入时相同的姓名清洗规则，确保目录一致
    sanitized_name = "".join(c for c in person_name if c.isalnum() or c in (' ', '_', '-')).rstrip()
    target_dir = os.path.join(ENROLLMENT_FOLDER, sanitized_name)

    # 防止路径穿越
    if not os.path.abspath(target_dir).startswith(os.path.abspath(ENROLLMENT_FOLDER)):
        raise HTTPException(status_code=403, detail="Access to this folder is forbidden.")

    if not os.path.isdir(target_dir):
        raise HTTPException(status_code=404, detail=f"Directory for '{person_name}' not found.")

    try:
        files = [
            f for f in os.listdir(target_dir)
            if os.path.isfile(os.path.join(target_dir, f))
        ]
        # 为每个文件生成一个通过后端访问的 URL
        images = [
            {
                "filename": f,
                "url": f"/api/enrollment/image/{sanitized_name}/{f}",
            }
            for f in files
        ]
        return {"images": images}
    except Exception as e:
        print(f"Error listing images for enrolled face '{person_name}': {e}")
        raise HTTPException(status_code=500, detail="Failed to list enrolled images.")


@app.get("/api/enrollment/image/{person_name}/{filename}")
async def get_enrollment_image(person_name: str, filename: str):
    """
    返回某个已录入人物的一张原始图片二进制数据。
    """
    sanitized_name = "".join(c for c in person_name if c.isalnum() or c in (' ', '_', '-')).rstrip()
    safe_filename = os.path.basename(filename)
    target_path = os.path.join(ENROLLMENT_FOLDER, sanitized_name, safe_filename)

    # 防止路径穿越
    if not os.path.abspath(target_path).startswith(os.path.abspath(ENROLLMENT_FOLDER)):
        raise HTTPException(status_code=403, detail="Access to this file is forbidden.")

    if not os.path.exists(target_path) or not os.path.isfile(target_path):
        raise HTTPException(status_code=404, detail="Image file not found.")

    # 简单根据扩展名推断图片类型
    ext = os.path.splitext(safe_filename)[1].lower()
    media_type = "image/jpeg"
    if ext == ".png":
        media_type = "image/png"
    elif ext in {".gif"}:
        media_type = "image/gif"
    elif ext in {".webp"}:
        media_type = "image/webp"

    return FileResponse(target_path, media_type=media_type, filename=safe_filename)

@app.post("/api/validate-path")
async def validate_path(path: str = Body(..., embed=True)):
    """Validates if a given path is an accessible directory."""
    if not path or not os.path.isdir(path):
        raise HTTPException(status_code=404, detail=f"Path not found or is not a directory: {path}")
    return {"status": "ok", "path": path}

@app.get("/api/config/load")
async def load_last_config():
    """Loads the last used configuration from a file."""
    if not LAST_CONFIG_FILE.exists():
        # 没有历史配置时，也返回当前固定图库根目录相关信息，方便前端直接使用。
        paths = resolve_library_paths(str(PHOTOS_DIR))
        return {
            "library_root": str(paths["root"]),
            "source_folder": str(paths["source_folder"]),
            "destination_folder": str(paths["destination_folder"]),
            "ignored_subfolders": [str(paths["system_base"])],
        }
    try:
        with open(LAST_CONFIG_FILE, 'r', encoding='utf-8') as f:
            config = json.load(f)

        # 无论历史配置里是否有 library_root，统一强制使用后端固定图库根目录。
        paths = resolve_library_paths(str(PHOTOS_DIR))
        config["library_root"] = str(paths["root"])
        config["source_folder"] = str(paths["source_folder"])
        config["destination_folder"] = str(paths["destination_folder"])

        ignored = config.get("ignored_subfolders") or []
        if not isinstance(ignored, list):
            ignored = []
        system_dir = str(paths["system_base"])
        if system_dir not in ignored:
            ignored.append(system_dir)
        config["ignored_subfolders"] = ignored

        return config
    except (json.JSONDecodeError, IOError) as e:
        print(f"Error loading last config: {e}")
        raise HTTPException(status_code=500, detail="Failed to load last configuration.")

@app.post("/api/config/save")
async def save_last_config(config: LastConfig):
    """Saves the current configuration to a file."""
    try:
        config_dict = config.dict()

        # 无论前端传什么 library_root，这里都强制写入固定图库根目录，
        # 并规范化 source/destination，同时忽略内部 `.MemoirsCore` 目录。
        paths = resolve_library_paths(str(PHOTOS_DIR))
        config_dict["library_root"] = str(paths["root"])
        config_dict["source_folder"] = str(paths["source_folder"])
        config_dict["destination_folder"] = str(paths["destination_folder"])

        ignored = config_dict.get("ignored_subfolders") or []
        if not isinstance(ignored, list):
            ignored = []
        system_dir = str(paths["system_base"])
        if system_dir not in ignored:
            ignored.append(system_dir)
        config_dict["ignored_subfolders"] = ignored

        with open(LAST_CONFIG_FILE, 'w', encoding='utf-8') as f:
            json.dump(config_dict, f, indent=4)
        return {"status": "success", "message": "Configuration saved."}
    except IOError as e:
        print(f"Error saving last config: {e}")
        raise HTTPException(status_code=500, detail="Failed to save configuration.")

@app.get("/api/presets/paths")
async def get_path_presets():
    """Loads and returns saved source/destination path configurations."""
    if not PATH_PRESETS_FILE.exists():
        return {}
    try:
        with open(PATH_PRESETS_FILE, 'r') as f:
            return json.load(f)
    except (json.JSONDecodeError, IOError):
        return {}

# FIX: Renamed from /api/save-preset and updated logic
@app.post("/api/presets/paths")
async def save_path_preset(preset: PathPreset):
    """Saves or updates a path preset."""
    try:
        presets = await get_path_presets()
        presets[preset.name] = {"source": preset.source, "destination": preset.destination}
        with open(PATH_PRESETS_FILE, 'w') as f:
            json.dump(presets, f, indent=4)
        return {"status": "success", "name": preset.name}
    except IOError:
        raise HTTPException(status_code=500, detail="Failed to save preset file.")

@app.delete("/api/presets/paths/{preset_name}")
async def delete_path_preset(preset_name: str):
    """Deletes a path preset by name."""
    try:
        presets = await get_path_presets()
        if preset_name not in presets:
            raise HTTPException(status_code=404, detail=f"Preset '{preset_name}' not found.")
        del presets[preset_name]
        with open(PATH_PRESETS_FILE, 'w') as f:
            json.dump(presets, f, indent=4)
        return {"status": "success", "message": f"Preset '{preset_name}' deleted."}
    except IOError:
        raise HTTPException(status_code=500, detail="Failed to delete preset.")

@app.post("/api/open-enrolled-folder")
async def open_enrolled_folder(request: OpenEnrolledFolderRequest):
    """Opens the folder for a specific enrolled person."""
    person_name = request.person_name
    
    # Security check to prevent path traversal attacks
    target_dir = os.path.join(ENROLLMENT_FOLDER, person_name)
    if not os.path.abspath(target_dir).startswith(os.path.abspath(ENROLLMENT_FOLDER)):
        raise HTTPException(status_code=403, detail="Access to this folder is forbidden.")

    if not os.path.isdir(target_dir):
        raise HTTPException(status_code=404, detail=f"Directory for '{person_name}' not found.")
    
    try:
        folder_path = os.path.realpath(target_dir)
        if sys.platform == "win32":
            subprocess.run(['explorer', folder_path])
        elif sys.platform == "darwin":
            subprocess.run(["open", folder_path], check=True)
        else:
            subprocess.run(["xdg-open", folder_path], check=True)
        return {"status": "success", "message": f"Opened folder for '{person_name}'."}
    except Exception as e:
        print(f"Error opening enrolled folder: {e}")
        raise HTTPException(status_code=500, detail=f"Failed to open folder: {str(e)}")

@app.post("/api/open-folder")
async def open_folder(request: OpenFolderRequest):
    """Opens a given folder path in the system's file explorer."""
    folder_path = os.path.realpath(request.folder_path)
    if not os.path.isdir(folder_path):
        raise HTTPException(status_code=404, detail=f"Directory not found: {folder_path}")
    try:
        if sys.platform == "win32":
            # FIX: Removed check=True as explorer.exe can return 1 on success.
            subprocess.run(['explorer', folder_path])
        elif sys.platform == "darwin":
            subprocess.run(["open", folder_path], check=True)
        else:
            subprocess.run(["xdg-open", folder_path], check=True)
        return {"status": "success", "message": f"Opened '{os.path.basename(folder_path)}' in file explorer."}
    except Exception as e:
        print(f"Error opening folder: {e}")
        raise HTTPException(status_code=500, detail=f"Failed to open folder via OS command: {str(e)}")

@app.post("/api/delete-enrolled-face")
async def delete_enrolled_face(request: OpenEnrolledFolderRequest):
    """
    Deletes the encoding and folder for a specific enrolled person.
    """
    person_name = request.person_name

    # Security check to prevent path traversal attacks
    target_dir = os.path.join(ENROLLMENT_FOLDER, person_name)
    if not os.path.abspath(target_dir).startswith(os.path.abspath(ENROLLMENT_FOLDER)):
        raise HTTPException(status_code=403, detail="Access to this folder is forbidden.")

    if not os.path.isdir(target_dir):
        raise HTTPException(status_code=404, detail=f"Directory for '{person_name}' not found.")

    try:
        # Remove the person's folder
        shutil.rmtree(target_dir)

        # Update the encodings file
        if os.path.exists(ENCODINGS_FILE):
            with open(ENCODINGS_FILE, "rb") as f:
                data = pickle.load(f)

            encodings = data.get("encodings", [])
            names = data.get("names", [])
            paths = data.get("paths", [])

            # Filter out the person's data
            updated_encodings = [e for e, n in zip(encodings, names) if n != person_name]
            updated_names = [n for n in names if n != person_name]
            updated_paths = [p for p, n in zip(paths, names) if n != person_name]

            # Save the updated encodings file
            with open(ENCODINGS_FILE, "wb") as f:
                pickle.dump({
                    "encodings": updated_encodings,
                    "names": updated_names,
                    "paths": updated_paths
                }, f)

        return {"status": "success", "message": f"Successfully deleted '{person_name}'."}  
    except Exception as e:
        print(f"Error deleting enrolled face: {e}")
        raise HTTPException(status_code=500, detail=f"Failed to delete '{person_name}': {str(e)}")


@app.post("/api/delete-enrolled-images")
async def delete_enrolled_images(request: DeleteEnrolledImagesRequest):
    """
    Deletes one or more enrolled images for a specific person and updates the encodings file.
    """
    person_name = request.person_name
    filenames = request.filenames or []
    if not filenames:
        return {"status": "no-op", "message": "No filenames provided.", "deleted_files": 0, "removed_encodings": 0}

    # Reuse the same name sanitization rule as enrollment/listing.
    sanitized_name = "".join(c for c in person_name if c.isalnum() or c in (' ', '_', '-')).rstrip()
    target_dir = os.path.join(ENROLLMENT_FOLDER, sanitized_name)

    # Prevent path traversal.
    if not os.path.abspath(target_dir).startswith(os.path.abspath(ENROLLMENT_FOLDER)):
        raise HTTPException(status_code=403, detail="Access to this folder is forbidden.")

    if not os.path.isdir(target_dir):
        raise HTTPException(status_code=404, detail=f"Directory for '{person_name}' not found.")

    deleted_paths: List[str] = []
    for name in filenames:
        safe_name = os.path.basename(name)
        image_path = os.path.join(target_dir, safe_name)
        try:
            if os.path.isfile(image_path):
                os.remove(image_path)
                deleted_paths.append(os.path.abspath(image_path))
        except Exception as e:
            print(f"Error deleting enrolled image '{image_path}': {e}")

    removed_encodings = 0
    # Update encodings file to remove references to deleted images.
    if deleted_paths and os.path.exists(ENCODINGS_FILE):
        try:
            with open(ENCODINGS_FILE, "rb") as f:
                data = pickle.load(f)

            encodings = data.get("encodings", [])
            names = data.get("names", [])
            paths = data.get("paths", [])

            if paths:
                keep_indices = [i for i, p in enumerate(paths) if os.path.abspath(p) not in deleted_paths]
                removed_encodings = len(paths) - len(keep_indices)

                encodings = [encodings[i] for i in keep_indices]
                names = [names[i] for i in keep_indices]
                paths = [paths[i] for i in keep_indices]

                with open(ENCODINGS_FILE, "wb") as f:
                    pickle.dump(
                        {
                            "encodings": encodings,
                            "names": names,
                            "paths": paths,
                        },
                        f,
                    )
        except Exception as e:
            print(f"Error updating encodings file during enrolled image deletion: {e}")

    return {
        "status": "success",
        "message": f"Deleted {len(deleted_paths)} image(s) for '{person_name}'.",
        "deleted_files": len(deleted_paths),
        "removed_encodings": removed_encodings,
    }

# NEW: Endpoint to gracefully shut down the server
@app.post("/api/shutdown")
async def shutdown_server():
    """
    A dedicated endpoint to gracefully shut down the Uvicorn server.
    This is called by the Tauri frontend just before exiting.
    """
    print("Shutdown signal received. Server is terminating.")
    # A small delay can help ensure the HTTP response is sent before shutdown.
    await asyncio.sleep(0.1) 
    
    # This is a common way to stop the server from within an endpoint.
    # It might cause a clean exit or raise an exception that the runner handles.
    os.kill(os.getpid(), signal.SIGTERM)
    return {"status": "shutting down"}


# --- Static File Serving ---
# This should point to the build output of your frontend
if os.path.exists(FRONTEND_DIR):
    app.mount("/", StaticFiles(directory=FRONTEND_DIR, html=True), name="static")

# ==============================================================================
#  Main Execution Block
# ==============================================================================
if __name__ == "__main__":
    # This is CRITICAL for PyInstaller on Windows to prevent infinite subprocesses.
    multiprocessing.freeze_support()

    # FIX: Re-implement the port discovery logic for Tauri.
    # We need to run the server in a way that we can get the port number.
    
    host = os.getenv("MEMOIRS_HOST", "127.0.0.1").strip() or "127.0.0.1"
    if getattr(sys, 'frozen', False):
        # Desktop bundles can keep their automatic port, while a mobile client
        # can opt into a stable port with MEMOIRS_PORT=8000.
        configured_port = os.getenv("MEMOIRS_PORT", "").strip()
        if configured_port:
            port = int(configured_port)
        else:
            import socket
            with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
                s.bind(('', 0))
                _, port = s.getsockname()
    else:
        # Mobile devices need a LAN-reachable backend, so configure the
        # listen address/port without editing source code.
        port = int(os.getenv("MEMOIRS_PORT", "8000"))

    # Print the port for the Tauri shell to capture. This is the crucial link.
    print(f"PYTHON_BACKEND_PORT:{port}", flush=True)

    # Now run Uvicorn on the specific port we found.
    uvicorn.run(
        app,
        host=host,
        port=port, # Use the dynamically found free port
        reload=False,
        log_level="info"
    )
