import os
from datetime import datetime
from typing import Any, Dict, List, Optional, Tuple
import re

try:
    from pymongo import MongoClient  # type: ignore
    from pymongo.collection import Collection  # type: ignore
    from pymongo import ReturnDocument  # type: ignore
except Exception:  # pragma: no cover
    MongoClient = None
    Collection = None  # type: ignore
    ReturnDocument = None  # type: ignore


MONGODB_URI = os.getenv("MONGODB_URI", "mongodb://127.0.0.1:27017")
MONGODB_DB_NAME = os.getenv("MONGODB_DB_NAME", "MemoirsCore")

_mongo_client = None


def mongodb_available() -> bool:
    return MongoClient is not None


def _get_images_collection():
    global _mongo_client
    if not mongodb_available():
        raise RuntimeError("MongoDB is not available (pymongo import failed).")
    if _mongo_client is None:
        _mongo_client = MongoClient(MONGODB_URI, serverSelectionTimeoutMS=5000)
        # Fail fast if server isn't reachable.
        _mongo_client.admin.command("ping")
    db = _mongo_client[MONGODB_DB_NAME]
    return db.images


def upsert_image_base(
    *,
    img_id: int,
    filename: str,
    relative_path: str,
    mime_type: Optional[str],
    filesize: Optional[int],
    created_at: datetime,
    updated_at: datetime,
    content_hash: Optional[str] = None,
    default_people_empty: bool = True,
    default_location_name: str = "",
) -> None:
    """
    Upsert the base mongo document for a photo (img_id as unique key).

    NOTE: This is the "Mongo is source of truth for enhanced metadata" foundation.
    """

    if not mongodb_available():
        return
    if img_id is None:
        return

    col = _get_images_collection()
    img_id_str = str(img_id)

    doc_set = {
        "img_id": img_id_str,
        "filename": filename,
        "relative_path": relative_path,
        "mime_type": mime_type,
        "filesize": filesize,
        "created_at": created_at,
        "updated_at": updated_at,
    }

    # Only apply defaults on first insert; never overwrite manual edits.
    doc_set_on_insert: Dict[str, Any] = {}
    if default_people_empty:
        doc_set_on_insert["img_people"] = []

    doc_set_on_insert["img_time"] = {"taken_at": created_at, "source": "upload"}
    doc_set_on_insert["img_location"] = {"name": default_location_name}
    # Canonical field: img_description (correct spelling)
    doc_set_on_insert["img_description"] = None
    if content_hash is not None:
        doc_set_on_insert["img_content_hash"] = str(content_hash)

    col.update_one(
        {"img_id": img_id_str},
        {"$set": doc_set, "$setOnInsert": doc_set_on_insert},
        upsert=True,
    )


def get_enhanced_docs(photo_ids: List[int]) -> Dict[str, Dict[str, Any]]:
    if not mongodb_available():
        return {}
    if not photo_ids:
        return {}
    col = _get_images_collection()
    ids = [str(int(x)) for x in photo_ids if x is not None]
    if not ids:
        return {}

    out: Dict[str, Dict[str, Any]] = {}
    for d in col.find({"img_id": {"$in": ids}}):
        img_id = d.get("img_id")
        if isinstance(img_id, str):
            out[img_id] = d
    return out


def merge_description(sqlite_description: Optional[str], mongo_doc: Optional[Dict[str, Any]]) -> Optional[str]:
    if mongo_doc is None:
        return sqlite_description
    # Prefer correct spelling only.
    if "img_description" in mongo_doc:
        val = mongo_doc.get("img_description")
        return val if val is not None else sqlite_description
    return sqlite_description


def extract_people(mongo_doc: Optional[Dict[str, Any]]) -> Optional[List[str]]:
    if mongo_doc is None:
        return None
    val = mongo_doc.get("img_people", None)
    if val is None:
        return None
    if isinstance(val, list):
        return [str(x) for x in val if x is not None]
    return None


def extract_taken_at(mongo_doc: Optional[Dict[str, Any]]) -> Optional[datetime]:
    if mongo_doc is None:
        return None
    t = mongo_doc.get("img_time", None)
    if not isinstance(t, dict):
        return None
    taken_at = t.get("taken_at", None)
    if isinstance(taken_at, datetime):
        return taken_at
    return None


def extract_location_name(mongo_doc: Optional[Dict[str, Any]]) -> Optional[str]:
    if mongo_doc is None:
        return None
    loc = mongo_doc.get("img_location", None)
    if not isinstance(loc, dict):
        return None
    name = loc.get("name", None)
    # allow empty string to be a "real override"
    if name is None:
        return None
    return str(name)


def patch_enhanced(
    *,
    img_id: int,
    base_photo: Dict[str, Any],
    patch: Dict[str, Any],
) -> None:
    """
    Patch enhanced fields in `images` collection.

    base_photo: dict should contain keys:
      filename, relative_path, mime_type, filesize, created_at, updated_at
    """
    if not mongodb_available():
        return

    col = _get_images_collection()
    img_id_str = str(img_id)

    # Ensure base doc exists so required fields validate.
    upsert_image_base(
        img_id=img_id,
        filename=base_photo["filename"],
        relative_path=base_photo["relative_path"],
        mime_type=base_photo.get("mime_type", None),
        filesize=base_photo.get("filesize", None),
        created_at=base_photo["created_at"],
        updated_at=base_photo["updated_at"],
        default_location_name="",
    )

    # Map UI payload fields -> Mongo schema fields.
    set_ops: Dict[str, Any] = {}
    if "person_names" in patch:
        set_ops["img_people"] = [str(x) for x in (patch.get("person_names") or [])]
    if "taken_at" in patch:
        set_ops["img_time"] = {"taken_at": patch.get("taken_at"), "source": "manual"}
    if "location" in patch:
        set_ops["img_location"] = {"name": patch.get("location")}
    if "description" in patch:
        set_ops["img_description"] = patch.get("description")

    if not set_ops:
        return

    # Always update updated_at.
    set_ops["updated_at"] = datetime.utcnow()
    col.update_one({"img_id": img_id_str}, {"$set": set_ops}, upsert=True)


def set_default_location_time_if_missing(
    *,
    photo_ids: List[int],
    default_location_name: str,
    default_taken_at: datetime,
) -> None:
    """
    Apply defaults only if:
      - mongo doc doesn't exist OR
      - img_location.name is missing/empty AND img_time.taken_at is missing/null.
    """
    if not mongodb_available():
        return
    if not photo_ids:
        return
    docs = get_enhanced_docs(photo_ids)
    col = _get_images_collection()

    for pid in photo_ids:
        pid_str = str(pid)
        doc = docs.get(pid_str)

        should_set_loc = True
        should_set_time = True
        if doc is not None:
            loc = extract_location_name(doc)
            taken_at = extract_taken_at(doc)
            if loc is not None and loc != "":
                should_set_loc = False
            if taken_at is not None:
                should_set_time = False

        set_ops: Dict[str, Any] = {}
        if should_set_loc:
            set_ops["img_location"] = {"name": default_location_name}
        if should_set_time:
            set_ops["img_time"] = {"taken_at": default_taken_at, "source": "upload"}

        if set_ops:
            set_ops["updated_at"] = datetime.utcnow()
            col.update_one({"img_id": pid_str}, {"$set": set_ops}, upsert=False)


def _get_cards_collections():
    if not mongodb_available():
        raise RuntimeError("MongoDB is not available (pymongo import failed).")
    global _mongo_client
    if _mongo_client is None:
        _mongo_client = MongoClient(MONGODB_URI, serverSelectionTimeoutMS=5000)
        _mongo_client.admin.command("ping")
    db = _mongo_client[MONGODB_DB_NAME]
    return db.memory_cards, db.story_cards, db.location_cards


def _get_counters_collection() -> "Collection":
    if not mongodb_available():
        raise RuntimeError("MongoDB is not available (pymongo import failed).")
    global _mongo_client
    if _mongo_client is None:
        _mongo_client = MongoClient(MONGODB_URI, serverSelectionTimeoutMS=5000)
        _mongo_client.admin.command("ping")
    db = _mongo_client[MONGODB_DB_NAME]
    return db.counters


def _max_int_from_collection(collection: "Collection", field: str) -> int:
    """
    Reads max numeric value from a collection field.
    Field might be stored as string; this helper is defensive.
    """
    # Always scan to avoid lexicographic issues when field is stored as string.
    mx = 0
    try:
        cursor = collection.find({}, {field: 1}).limit(200000)
        for d in cursor:
            v = d.get(field)
            if v is None:
                continue
            try:
                iv = int(v)
                if iv > mx:
                    mx = iv
            except Exception:
                continue
    except Exception:
        return 0
    return mx


def _seed_counter_if_needed(counter_name: str, max_value: int) -> None:
    """
    Ensure counters[counter_name].seq >= max_value + 1.
    """
    col = _get_counters_collection()
    # If missing, we set seq=max_value+1.
    doc = col.find_one({"name": counter_name}) or {}
    cur_seq = doc.get("seq", None)
    try:
        cur_seq_int = int(cur_seq) if cur_seq is not None else None
    except Exception:
        cur_seq_int = None
    target = max_value + 1
    if cur_seq_int is None or cur_seq_int < target:
        col.update_one(
            {"name": counter_name},
            {"$set": {"seq": target}},
            upsert=True,
        )


def _next_seq(counter_name: str, *, seed_from: Optional[Tuple[str, str]] = None) -> int:
    """
    Generate next integer sequence from a counter document.
    Optionally seeds the counter from a (collection_name, field_name) max value.
    """
    if seed_from is not None:
        col_name, field_name = seed_from
        if col_name == "images":
            mc = _get_images_collection()
        elif col_name == "memory_cards":
            mc, _, _ = _get_cards_collections()
        elif col_name == "story_cards":
            _, sc, _ = _get_cards_collections()
            mc = sc
        elif col_name == "location_cards":
            _, _, lc = _get_cards_collections()
            mc = lc
        else:
            mc = None
        if mc is not None:
            max_value = _max_int_from_collection(mc, field_name)
            _seed_counter_if_needed(counter_name, max_value)

    counters = _get_counters_collection()
    doc = counters.find_one_and_update(
        {"name": counter_name},
        {"$inc": {"seq": 1}},
        upsert=True,
        return_document=ReturnDocument.AFTER,
    )
    seq_val = int((doc or {}).get("seq", 1))
    return seq_val


def allocate_photo_id() -> int:
    # img_id stored as string in Mongo; we still generate int IDs for URLs.
    return _next_seq("photo_img_id", seed_from=("images", "img_id"))


def allocate_memory_card_id() -> int:
    return _next_seq("memory_card_id", seed_from=("memory_cards", "card_id"))


def allocate_story_card_id() -> int:
    return _next_seq("story_card_id", seed_from=("story_cards", "card_id"))


def allocate_trip_id() -> int:
    return _next_seq("trip_card_id", seed_from=("location_cards", "card_id"))


def _extract_photo_id_from_url(s: str) -> Optional[int]:
    if not s:
        return None
    m = re.search(r"/api/photos/(\d+)/file", s)
    if not m:
        m = re.search(r"photo_id=(\d+)", s)
    if not m:
        return None
    try:
        v = int(m.group(1))
        if v > 0:
            return v
    except Exception:
        return None
    return None


def upsert_memory_card(
    *,
    card_id: int,
    title: str,
    content: str,
    image_paths: List[str],
    created_at: datetime,
    updated_at: datetime,
) -> None:
    if not mongodb_available():
        return
    mem_col, _, _ = _get_cards_collections()
    # NOTE: 前端 MemoryCard 使用 `imagePaths` 作为可直接展示的引用（通常是完整 url）。
    # 因此这里把 image_paths 原样存入 `image_ids` 字段（Mongo validator 只要求 string 类型）。
    image_ids: List[str] = [str(p).strip() for p in image_paths if str(p).strip()]

    doc = {
        "card_id": str(card_id),
        "title": title,
        "content": content,
        "image_ids": image_ids,
        "cover_img_id": None,
        "reading_minutes": None,
        "is_deleted": None,
        "created_at": created_at,
        "updated_at": updated_at,
    }

    mem_col.update_one(
        {"card_id": str(card_id)},
        {"$set": doc},
        upsert=True,
    )


def upsert_story_card(
    *,
    card_id: int,
    title: str,
    content: str,
    cover_photo_id: Optional[int],
    image_photo_ids: List[int],
    reading_minutes: int,
    created_at: datetime,
    updated_at: datetime,
) -> None:
    if not mongodb_available():
        return
    _, story_col, _ = _get_cards_collections()

    doc = {
        "card_id": str(card_id),
        "title": title,
        "content": content,
        "image_ids": [str(x) for x in image_photo_ids if x is not None],
        "cover_img_id": str(cover_photo_id) if cover_photo_id is not None else None,
        "reading_minutes": reading_minutes,
        "status": None,
        "is_deleted": None,
        "created_at": created_at,
        "updated_at": updated_at,
    }

    story_col.update_one(
        {"card_id": str(card_id)},
        {"$set": doc},
        upsert=True,
    )


def upsert_location_card(
    *,
    card_id: int,
    title: str,
    points: List[Dict[str, Any]],
    cover_img_id: Optional[int],
    created_at: datetime,
    updated_at: datetime,
) -> None:
    if not mongodb_available():
        return
    _, _, loc_col = _get_cards_collections()

    doc = {
        "card_id": str(card_id),
        "title": title,
        "point_count": len(points),
        "cover_img_id": str(cover_img_id) if cover_img_id is not None else None,
        "points": points,
        "is_deleted": None,
        "created_at": created_at,
        "updated_at": updated_at,
    }

    loc_col.update_one(
        {"card_id": str(card_id)},
        {"$set": doc},
        upsert=True,
    )


def list_memory_cards_from_mongo() -> List[Dict[str, Any]]:
    if not mongodb_available():
        return []
    mem_col, _, _ = _get_cards_collections()
    # Keep newest first for consistent UI ordering.
    docs = list(mem_col.find({}).sort("created_at", -1))
    return docs


def list_story_cards_from_mongo() -> List[Dict[str, Any]]:
    if not mongodb_available():
        return []
    _, story_col, _ = _get_cards_collections()
    docs = list(story_col.find({}).sort("created_at", -1))
    return docs


def list_location_cards_from_mongo() -> List[Dict[str, Any]]:
    if not mongodb_available():
        return []
    _, _, loc_col = _get_cards_collections()
    docs = list(loc_col.find({}).sort("created_at", -1))
    return docs


def get_location_card_from_mongo(card_id: int) -> Optional[Dict[str, Any]]:
    if not mongodb_available():
        return None
    _, _, loc_col = _get_cards_collections()
    doc = loc_col.find_one({"card_id": str(card_id)})
    return doc


def get_memory_card_from_mongo(card_id: int) -> Optional[Dict[str, Any]]:
    if not mongodb_available():
        return None
    mem_col, _, _ = _get_cards_collections()
    return mem_col.find_one({"card_id": str(card_id)})


def get_story_card_from_mongo(card_id: int) -> Optional[Dict[str, Any]]:
    if not mongodb_available():
        return None
    _, story_col, _ = _get_cards_collections()
    return story_col.find_one({"card_id": str(card_id)})


def delete_memory_card_from_mongo(card_id: int) -> None:
    if not mongodb_available():
        return
    mem_col, _, _ = _get_cards_collections()
    mem_col.delete_one({"card_id": str(card_id)})


def delete_story_card_from_mongo(card_id: int) -> None:
    if not mongodb_available():
        return
    _, story_col, _ = _get_cards_collections()
    story_col.delete_one({"card_id": str(card_id)})


def delete_location_card_from_mongo(card_id: int) -> None:
    if not mongodb_available():
        return
    _, _, loc_col = _get_cards_collections()
    loc_col.delete_one({"card_id": str(card_id)})


def purge_deleted_cards_from_mongo() -> Dict[str, int]:
    """
    Hard-purge all documents that were previously soft-deleted (is_deleted=true).
    Useful after we switch from soft-delete to hard-delete in an ongoing dev DB.
    """
    if not mongodb_available():
        return {"memory_cards": 0, "story_cards": 0, "location_cards": 0}

    mem_col, story_col, loc_col = _get_cards_collections()

    mem_res = mem_col.delete_many({"is_deleted": True})
    story_res = story_col.delete_many({"is_deleted": True})
    loc_res = loc_col.delete_many({"is_deleted": True})

    return {
        "memory_cards": int(getattr(mem_res, "deleted_count", 0)),
        "story_cards": int(getattr(story_res, "deleted_count", 0)),
        "location_cards": int(getattr(loc_res, "deleted_count", 0)),
    }


def get_image_id_by_content_hash(content_hash: str) -> Optional[int]:
    if not mongodb_available():
        return None
    col = _get_images_collection()
    if not content_hash:
        return None
    doc = col.find_one({"img_content_hash": content_hash})
    if not doc:
        return None
    try:
        return int(doc.get("img_id"))
    except Exception:
        return None


def delete_image_from_mongo(img_id: int) -> None:
    if not mongodb_available():
        return
    col = _get_images_collection()
    col.delete_one({"img_id": str(int(img_id))})


def _extract_img_id_from_ref(ref: Any) -> Optional[str]:
    """
    Normalize different kinds of image references into `img_id` string.

    Supported ref formats:
      - "123" / 123
      - "/api/photos/123/file" (full url may also work)
    """
    if ref is None:
        return None
    if isinstance(ref, int):
        return str(ref) if ref > 0 else None
    s = str(ref).strip()
    if not s:
        return None
    if s.isdigit():
        return s
    pid = _extract_photo_id_from_url(s)
    if pid is not None:
        return str(pid)
    # fallback: try any img/photo query pattern
    m = re.search(r"photos/(\d+)/file", s)
    if m:
        try:
            v = int(m.group(1))
            if v > 0:
                return str(v)
        except Exception:
            return None
    return None


def purge_unused_images_from_mongo() -> List[Dict[str, Any]]:
    """
    Delete images that are not referenced by any card document.
    Returns the deleted orphan image docs (for optional disk cleanup).
    """
    if not mongodb_available():
        return []

    mem_col, story_col, loc_col = _get_cards_collections()
    used_img_ids: set[str] = set()

    # memory_cards.image_ids may store full urls (UI), so extract img_id from ref.
    for m in mem_col.find({}):
        if m.get("is_deleted") is True:
            continue
        for ref in m.get("image_ids") or []:
            img_id = _extract_img_id_from_ref(ref)
            if img_id:
                used_img_ids.add(img_id)

    # story_cards
    for s in story_col.find({}):
        if s.get("is_deleted") is True:
            continue
        cover = _extract_img_id_from_ref(s.get("cover_img_id"))
        if cover:
            used_img_ids.add(cover)
        for ref in s.get("image_ids") or []:
            img_id = _extract_img_id_from_ref(ref)
            if img_id:
                used_img_ids.add(img_id)

    # location_cards
    for l in loc_col.find({}):
        if l.get("is_deleted") is True:
            continue
        cover = _extract_img_id_from_ref(l.get("cover_img_id"))
        if cover:
            used_img_ids.add(cover)
        for p in l.get("points") or []:
            for ref in p.get("image_ids") or []:
                img_id = _extract_img_id_from_ref(ref)
                if img_id:
                    used_img_ids.add(img_id)

    img_col = _get_images_collection()
    orphan_docs: List[Dict[str, Any]] = []
    orphan_ids: List[str] = []
    for d in img_col.find({}):
        img_id = str(d.get("img_id"))
        if not img_id or img_id not in used_img_ids:
            orphan_docs.append(d)
            orphan_ids.append(img_id)

    if orphan_ids:
        img_col.delete_many({"img_id": {"$in": orphan_ids}})

    return orphan_docs


def migrate_img_description_field() -> Dict[str, int]:
    """
    Migrate legacy field `img_discription` -> canonical field `img_description`,
    then hard-remove the legacy field for all updated documents.

    Migration rule:
      - If `img_description` is missing/null/empty, copy from `img_discription`.
      - After copying, unset `img_discription`.
    """
    if not mongodb_available():
        return {"scanned": 0, "updated": 0}

    col = _get_images_collection()
    # Iterate all docs that still have the legacy field.
    # We will only fill img_description when it's missing/null/whitespace,
    # but we will always remove img_discription after the loop.
    filter_q = {"img_discription": {"$type": "string"}}

    scanned = 0
    updated = 0
    # img_id is unique; we update by img_id.
    for d in col.find(filter_q, {"img_id": 1, "img_discription": 1, "img_description": 1}):
        scanned += 1
        img_id = d.get("img_id")
        legacy = d.get("img_discription")
        if not img_id or not isinstance(legacy, str):
            continue
        current = d.get("img_description")
        should_fill = (current is None) or (
            isinstance(current, str) and current.strip() == ""
        )
        if should_fill:
            col.update_one(
                {"img_id": img_id},
                {"$set": {"img_description": legacy}},
                upsert=False,
            )
            updated += 1

    # Hard-remove remaining legacy fields even if img_description already exists.
    remaining = col.update_many(
        {"img_discription": {"$exists": True}},
        {"$unset": {"img_discription": ""}},
    )
    return {"scanned": scanned, "filled_img_description": updated, "unset_img_discription": int(remaining.modified_count)}


def list_images_from_mongo(offset: int = 0, limit: int = 50) -> List[Dict[str, Any]]:
    if not mongodb_available():
        return []
    col = _get_images_collection()
    off = max(int(offset or 0), 0)
    lim = max(min(int(limit or 50), 200), 1)
    docs = list(col.find({}).sort("created_at", -1).skip(off).limit(lim))
    return docs


def get_image_from_mongo(img_id: int) -> Optional[Dict[str, Any]]:
    if not mongodb_available():
        return None
    col = _get_images_collection()
    return col.find_one({"img_id": str(int(img_id))})


def list_image_search_items_from_mongo(
    *,
    offset: int = 0,
    limit: int = 2000,
) -> List[Dict[str, Any]]:
    """
    Lightweight listing for AI/search use-cases.

    Returns a list of dict items with a stable subset of fields:
      - img_id (str)
      - img_description (str|None)
      - img_people (list|None)
      - img_location (dict|None)
      - img_time (dict|None)
      - filename/relative_path (str|None)
      - created_at (datetime|None)

    Notes:
    - Bounded limit to avoid huge memory usage.
    - Sorted by created_at desc for stable paging.
    """
    if not mongodb_available():
        return []
    col = _get_images_collection()
    off = max(int(offset or 0), 0)
    lim = max(min(int(limit or 2000), 5000), 1)
    projection = {
        "_id": 0,
        "img_id": 1,
        "img_description": 1,
        "img_people": 1,
        "img_location": 1,
        "img_time": 1,
        "filename": 1,
        "relative_path": 1,
        "created_at": 1,
    }
    return list(col.find({}, projection).sort("created_at", -1).skip(off).limit(lim))

