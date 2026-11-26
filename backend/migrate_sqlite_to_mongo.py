"""
One-time migration: copy legacy SQLite data into MongoDB.

Target collections (per mongo_enhanced.py helpers):
  - images
  - memory_cards
  - story_cards
  - location_cards

Usage (from backend folder):
  python migrate_sqlite_to_mongo.py --photos --memory-cards --story-cards --trips
"""

from __future__ import annotations

import argparse
import json
from typing import Any, Dict, List, Optional

from sqlmodel import Session, select

import main as backend_main
from mongo_enhanced import (
    mongodb_available,
    upsert_image_base,
    upsert_memory_card,
    upsert_story_card,
    upsert_location_card,
    patch_enhanced,
    get_enhanced_docs,
)


def _parse_int_list(raw: str) -> List[int]:
    try:
        data = json.loads(raw or "[]")
        if isinstance(data, list):
            out: List[int] = []
            for x in data:
                try:
                    v = int(x)
                    if v > 0:
                        out.append(v)
                except Exception:
                    continue
            return out
    except Exception:
        pass
    return []


def _parse_str_list(raw: str) -> List[str]:
    try:
        data = json.loads(raw or "[]")
        if isinstance(data, list):
            return [str(x) for x in data]
    except Exception:
        pass
    return []


def migrate_photos(session: Session, batch_size: int = 200) -> None:
    rows = session.exec(select(backend_main.Photo)).all()
    if not rows:
        print("[migrate] no photos in sqlite")
        return

    print(f"[migrate] photos: {len(rows)}")
    for i in range(0, len(rows), batch_size):
        chunk = rows[i : i + batch_size]
        ids = [r.id for r in chunk if r.id is not None]
        mongo_existing = get_enhanced_docs([int(x) for x in ids]) if ids else {}

        for p in chunk:
            if p.id is None:
                continue

            upsert_image_base(
                img_id=int(p.id),
                filename=p.filename,
                relative_path=p.relative_path,
                mime_type=p.mime_type,
                filesize=p.filesize,
                created_at=p.created_at,
                updated_at=p.updated_at,
                default_people_empty=True,
                default_location_name="",
            )

            # Sync legacy sqlite photo.description into Mongo image description field,
            # only if Mongo doesn't have it yet.
            desc = (p.description or "").strip()
            if not desc:
                continue

            mongo_doc = mongo_existing.get(str(int(p.id)))
            current_mongo_desc = None
            if mongo_doc is not None:
                current_mongo_desc = mongo_doc.get("img_description", None)

            if current_mongo_desc is not None and str(current_mongo_desc).strip():
                continue

            patch_enhanced(
                img_id=int(p.id),
                base_photo={
                    "filename": p.filename,
                    "relative_path": p.relative_path,
                    "mime_type": p.mime_type,
                    "filesize": p.filesize,
                    "created_at": p.created_at,
                    "updated_at": p.updated_at,
                    "description": p.description,
                },
                patch={"description": desc},
            )


def migrate_memory_cards(session: Session) -> None:
    rows = session.exec(select(backend_main.MemoryCardDB)).all()
    if not rows:
        print("[migrate] no memory cards in sqlite")
        return
    print(f"[migrate] memory cards: {len(rows)}")

    for r in rows:
        if r.id is None:
            continue
        image_paths = backend_main._decode_image_paths(r.image_paths_json)
        upsert_memory_card(
            card_id=int(r.id),
            title=r.title or "",
            content=r.content or "",
            image_paths=image_paths,
            created_at=r.created_at,
            updated_at=r.updated_at,
        )


def migrate_story_cards(session: Session) -> None:
    rows = session.exec(select(backend_main.StoryArticleDB)).all()
    if not rows:
        print("[migrate] no story cards in sqlite")
        return
    print(f"[migrate] story cards: {len(rows)}")

    for r in rows:
        if r.id is None:
            continue
        image_ids = _parse_int_list(r.image_photo_ids_json)
        upsert_story_card(
            card_id=int(r.id),
            title=r.title or "",
            content=r.content or "",
            cover_photo_id=r.cover_photo_id,
            image_photo_ids=image_ids,
            reading_minutes=int(r.reading_minutes or 1),
            created_at=r.created_at,
            updated_at=r.updated_at,
        )


def migrate_trips(session: Session) -> None:
    trips = session.exec(select(backend_main.TripDB)).all()
    if not trips:
        print("[migrate] no trips in sqlite")
        return
    print(f"[migrate] trips: {len(trips)}")

    for t in trips:
        if t.id is None:
            continue
        point_rows = session.exec(
            select(backend_main.CheckInPointDB).where(
                backend_main.CheckInPointDB.trip_id == int(t.id)
            )
        ).all()
        # Deterministic ordering for stable "pt_0/pt_1/..."
        point_rows.sort(key=lambda x: (x.id if x.id is not None else 0))

        loc_points: List[Dict[str, Any]] = []
        cover_img_id: Optional[int] = None

        for idx, p in enumerate(point_rows):
            photo_ids = _parse_int_list(p.photo_ids_json)
            if cover_img_id is None and photo_ids:
                cover_img_id = photo_ids[0]

            loc_points.append(
                {
                    "point_id": f"pt_{idx}",
                    "location_name": (p.location_name or "").strip(),
                    "latitude": float(p.latitude or 0.0),
                    "longitude": float(p.longitude or 0.0),
                    "coordinate_system": (p.coordinate_system or "GCJ-02").strip() or "GCJ-02",
                    "time": p.time,
                    "note": (p.note or "").strip(),
                    "image_ids": [str(x) for x in photo_ids],
                }
            )

        upsert_location_card(
            card_id=int(t.id),
            title=t.title or "",
            points=loc_points,
            cover_img_id=cover_img_id,
            created_at=t.created_at,
            updated_at=t.created_at,
        )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--photos", action="store_true", help="migrate Photo -> images")
    parser.add_argument("--memory-cards", action="store_true", help="migrate MemoryCardDB -> memory_cards")
    parser.add_argument("--story-cards", action="store_true", help="migrate StoryArticleDB -> story_cards")
    parser.add_argument("--trips", action="store_true", help="migrate TripDB/CheckInPointDB -> location_cards")
    parser.add_argument("--batch-size", type=int, default=200)
    args = parser.parse_args()

    if not mongodb_available():
        raise SystemExit("MongoDB is not available. Check pymongo/MONGODB_URI/MONGODB_DB_NAME.")

    if not (args.photos or args.memory_cards or args.story_cards or args.trips):
        raise SystemExit("Select at least one target: --photos / --memory-cards / --story-cards / --trips")

    # Ensure SQLModel metadata/tables are available (read-only usage).
    with Session(backend_main.engine) as session:
        if args.photos:
            migrate_photos(session, batch_size=args.batch_size)
        if args.memory_cards:
            migrate_memory_cards(session)
        if args.story_cards:
            migrate_story_cards(session)
        if args.trips:
            migrate_trips(session)

    print("[migrate] done")


if __name__ == "__main__":
    main()

