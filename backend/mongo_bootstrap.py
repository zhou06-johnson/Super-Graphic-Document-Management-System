import os
from datetime import datetime

from pymongo import ASCENDING, DESCENDING, GEOSPHERE, MongoClient
from pymongo.errors import CollectionInvalid


MONGODB_URI = os.getenv("MONGODB_URI", "mongodb://127.0.0.1:27017")
MONGODB_DB_NAME = os.getenv("MONGODB_DB_NAME", "MemoirsCore")


def _create_collection_with_validator(db, name: str, validator: dict) -> None:
    try:
        db.create_collection(name, validator=validator)
        print(f"[mongo] created collection: {name}")
    except CollectionInvalid:
        db.command("collMod", name, validator=validator)
        print(f"[mongo] updated validator: {name}")


def bootstrap_mongodb() -> None:
    client = MongoClient(MONGODB_URI, serverSelectionTimeoutMS=5000)
    client.admin.command("ping")
    db = client[MONGODB_DB_NAME]

    images_validator = {
        "$jsonSchema": {
            "bsonType": "object",
            "required": ["img_id", "filename", "relative_path", "created_at", "updated_at"],
            "properties": {
                "img_id": {"bsonType": "string"},
                "filename": {"bsonType": "string"},
                "relative_path": {"bsonType": "string"},
                "mime_type": {"bsonType": ["string", "null"]},
                "filesize": {"bsonType": ["int", "long", "null"]},
                "img_people": {"bsonType": ["array", "null"], "items": {"bsonType": "string"}},
                "img_time": {
                    "bsonType": ["object", "null"],
                    "properties": {
                        "taken_at": {"bsonType": ["date", "null"]},
                        "source": {"bsonType": ["string", "null"]},
                        "timezone": {"bsonType": ["string", "null"]},
                    },
                },
                "img_location": {
                    "bsonType": ["object", "null"],
                    "properties": {
                        "name": {"bsonType": ["string", "null"]},
                        "geo": {
                            "bsonType": ["object", "null"],
                            "properties": {
                                "type": {"enum": ["Point"]},
                                "coordinates": {
                                    "bsonType": "array",
                                    "items": {"bsonType": "double"},
                                },
                            },
                        },
                        "coordinate_system": {"bsonType": ["string", "null"]},
                        "description": {"bsonType": ["string", "null"]},
                    },
                },
                # Correct spelling (new canonical field).
                "img_description": {"bsonType": ["string", "null"]},
                # Used for photo de-duplication when sqlite is removed.
                "img_content_hash": {"bsonType": ["string", "null"]},
                "card_refs": {
                    "bsonType": ["array", "null"],
                    "items": {
                        "bsonType": "object",
                        "required": ["card_type", "card_id"],
                        "properties": {
                            "card_type": {"enum": ["memory", "story", "location"]},
                            "card_id": {"bsonType": "objectId"},
                        },
                    },
                },
                "created_at": {"bsonType": "date"},
                "updated_at": {"bsonType": "date"},
            },
        }
    }

    memory_cards_validator = {
        "$jsonSchema": {
            "bsonType": "object",
            "required": ["title", "content", "image_ids", "created_at", "updated_at"],
            "properties": {
                "title": {"bsonType": "string"},
                "content": {"bsonType": "string"},
                "image_ids": {"bsonType": "array", "items": {"bsonType": "string"}},
                "cover_img_id": {"bsonType": ["string", "null"]},
                "reading_minutes": {"bsonType": ["int", "long", "null"]},
                "is_deleted": {"bsonType": ["bool", "null"]},
                "created_at": {"bsonType": "date"},
                "updated_at": {"bsonType": "date"},
            },
        }
    }

    story_cards_validator = {
        "$jsonSchema": {
            "bsonType": "object",
            "required": ["title", "content", "image_ids", "created_at", "updated_at"],
            "properties": {
                "title": {"bsonType": "string"},
                "content": {"bsonType": "string"},
                "cover_img_id": {"bsonType": ["string", "null"]},
                "image_ids": {"bsonType": "array", "items": {"bsonType": "string"}},
                "reading_minutes": {"bsonType": ["int", "long", "null"]},
                "status": {"bsonType": ["string", "null"]},
                "is_deleted": {"bsonType": ["bool", "null"]},
                "created_at": {"bsonType": "date"},
                "updated_at": {"bsonType": "date"},
            },
        }
    }

    location_cards_validator = {
        "$jsonSchema": {
            "bsonType": "object",
            "required": ["title", "points", "created_at", "updated_at"],
            "properties": {
                "title": {"bsonType": "string"},
                "point_count": {"bsonType": ["int", "long", "null"]},
                "cover_img_id": {"bsonType": ["string", "null"]},
                "points": {
                    "bsonType": "array",
                    "items": {
                        "bsonType": "object",
                        "required": ["point_id", "location_name", "time"],
                        "properties": {
                            "point_id": {"bsonType": "string"},
                            "location_name": {"bsonType": "string"},
                            "latitude": {"bsonType": ["double", "int", "long", "null"]},
                            "longitude": {"bsonType": ["double", "int", "long", "null"]},
                            "coordinate_system": {"bsonType": ["string", "null"]},
                            "time": {"bsonType": "date"},
                            "note": {"bsonType": ["string", "null"]},
                            "image_ids": {
                                "bsonType": ["array", "null"],
                                "items": {"bsonType": "string"},
                            },
                        },
                    },
                },
                "is_deleted": {"bsonType": ["bool", "null"]},
                "created_at": {"bsonType": "date"},
                "updated_at": {"bsonType": "date"},
            },
        }
    }

    _create_collection_with_validator(db, "images", images_validator)
    _create_collection_with_validator(db, "memory_cards", memory_cards_validator)
    _create_collection_with_validator(db, "story_cards", story_cards_validator)
    _create_collection_with_validator(db, "location_cards", location_cards_validator)

    db.images.create_index([("img_id", ASCENDING)], unique=True, name="uniq_img_id")
    db.images.create_index([("img_people", ASCENDING)], name="idx_img_people")
    db.images.create_index([("img_time.taken_at", DESCENDING)], name="idx_img_time")
    db.images.create_index([("img_location.geo", GEOSPHERE)], name="idx_img_geo")
    db.images.create_index([("img_content_hash", ASCENDING)], name="idx_img_content_hash")
    # (Removed legacy img_discription_* indexes; queue not used in current flow.)
    db.images.create_index(
        [("card_refs.card_type", ASCENDING), ("card_refs.card_id", ASCENDING)],
        name="idx_card_refs",
    )

    db.memory_cards.create_index([("created_at", DESCENDING)], name="idx_memory_created_at")
    db.memory_cards.create_index([("image_ids", ASCENDING)], name="idx_memory_image_ids")

    db.story_cards.create_index([("created_at", DESCENDING)], name="idx_story_created_at")
    db.story_cards.create_index([("cover_img_id", ASCENDING)], name="idx_story_cover")
    db.story_cards.create_index([("image_ids", ASCENDING)], name="idx_story_image_ids")

    db.location_cards.create_index([("created_at", DESCENDING)], name="idx_location_created_at")
    db.location_cards.create_index([("cover_img_id", ASCENDING)], name="idx_location_cover")
    db.location_cards.create_index([("points.location_name", ASCENDING)], name="idx_location_point_name")
    db.location_cards.create_index([("points.time", DESCENDING)], name="idx_location_point_time")

    now = datetime.utcnow()
    print(f"[mongo] bootstrap complete: db={MONGODB_DB_NAME}, time={now.isoformat()}Z")


if __name__ == "__main__":
    bootstrap_mongodb()
