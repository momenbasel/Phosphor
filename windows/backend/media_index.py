"""Reusable in-memory indexes of backup media metadata, without decrypting media."""

import json
import re
import sqlite3
import threading
from collections import OrderedDict
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path

from backup import archive_metadata, DatasetUnavailable
from data_queries import columns, date_bound

PHOTO_SUFFIXES = (
    ".jpg",
    ".jpeg",
    ".png",
    ".heic",
    ".heif",
    ".gif",
    ".tif",
    ".tiff",
    ".webp",
    ".dng",
    ".mov",
    ".mp4",
    ".m4v",
)
VIDEO_SUFFIXES = (".mov", ".mp4", ".m4v")


def metadata_date(value):
    try:
        if isinstance(value, datetime):
            return (
                value.replace(tzinfo=timezone.utc).isoformat()
                if value.tzinfo is None
                else value.astimezone(timezone.utc).isoformat()
            )
        if isinstance(value, dict) and "NS.time" in value:
            value = float(value["NS.time"]) + 978307200
        if isinstance(value, (float, int)) and value > 0:
            return datetime.fromtimestamp(value, timezone.utc).isoformat()
    except (ValueError, OverflowError, OSError, TypeError):
        pass
    return ""


class MediaIndexes:
    def __init__(self, store):
        self.store = store
        self.cache = OrderedDict()
        self.lock = threading.RLock()
        self.builds = 0

    def clear(self, backup=None):
        path = str(self.store.path(backup)) if backup is not None else None
        with self.lock:
            for key in list(self.cache):
                if path is None or key[0] == path:
                    self.cache.pop(key).close()

    @contextmanager
    def connection(self, backup):
        key = (str(self.store.path(backup)), self.store.generation(backup))
        # Validate that an encrypted snapshot remains unlocked before serving a
        # derived index. Locking invalidates it even if an old caller kept an ID.
        with self.store.connection(backup):
            pass
        with self.lock:
            for old in list(self.cache):
                if old[0] == key[0] and old != key:
                    self.cache.pop(old).close()
            db = self.cache.get(key)
            if db is None:
                db = self._build(backup)
                self.cache[key] = db
                self.builds += 1
                while len(self.cache) > 2:
                    self.cache.popitem(last=False)[1].close()
            self.cache.move_to_end(key)
            yield db

    def _build(self, backup):
        db = sqlite3.connect(":memory:", check_same_thread=False)
        db.row_factory = sqlite3.Row
        db.execute(
            "CREATE TABLE media (id TEXT PRIMARY KEY,name TEXT,path TEXT,domain TEXT,video INTEGER,size INTEGER,date TEXT,dateSource TEXT,width INTEGER,height INTEGER)"
        )
        try:
            root = self.store.path(backup)
            with self.store.connection(backup) as manifest:
                predicate = " OR ".join("lower(relativePath) LIKE ?" for _ in PHOTO_SUFFIXES)
                cursor = manifest.execute(
                    "SELECT fileID,relativePath,domain,file FROM Files WHERE flags=1 AND domain IN ('CameraRollDomain','MediaDomain') AND ("
                    + predicate
                    + ")",
                    ["%" + suffix for suffix in PHOTO_SUFFIXES],
                )
                batch = []
                for entry in cursor:
                    if not isinstance(entry["fileID"], str) or not re.fullmatch(
                        r"[a-fA-F0-9]{40}", entry["fileID"]
                    ):
                        continue
                    path = entry["relativePath"]
                    metadata = archive_metadata(entry["file"])
                    size = metadata.get("Size")
                    if not isinstance(size, int) or size < 0:
                        source = root / entry["fileID"][:2] / entry["fileID"]
                        if not source.exists():
                            source = root / entry["fileID"]
                        size = (
                            source.stat().st_size
                            if source.is_file()
                            and not source.is_symlink()
                            and source.resolve().is_relative_to(root)
                            else None
                        )
                    created = metadata_date(metadata.get("Birth"))
                    modified = metadata_date(metadata.get("LastModified"))
                    batch.append(
                        (
                            entry["fileID"],
                            Path(path).name,
                            path,
                            entry["domain"],
                            int(Path(path).suffix.lower() in VIDEO_SUFFIXES),
                            size,
                            created or modified,
                            "fileCreated" if created else "fileModified" if modified else "unknown",
                            None,
                            None,
                        )
                    )
                    if len(batch) >= 512:
                        db.executemany("INSERT INTO media VALUES (?,?,?,?,?,?,?,?,?,?)", batch)
                        batch.clear()
                if batch:
                    db.executemany("INSERT INTO media VALUES (?,?,?,?,?,?,?,?,?,?)", batch)
            self._capture_dates(backup, db)
            db.executescript(
                "CREATE INDEX media_date ON media(date,id); CREATE INDEX media_size ON media(size,id); CREATE INDEX media_name ON media(name COLLATE NOCASE,id);"
            )
            db.commit()
            db.execute("PRAGMA query_only=ON")
            return db
        except Exception:
            db.close()
            raise

    def _capture_dates(self, backup, index):
        # Photos.sqlite is optional. Its asset metadata provides capture dates;
        # filesystem dates remain explicitly labelled as a fallback.
        try:
            with self.store.database(
                backup, "Photos.sqlite", ("ZASSET",), ("CameraRollDomain",), ("PhotoData/",)
            ) as photos:
                c = columns(photos, "ZASSET")
                if not {"ZFILENAME", "ZDATECREATED"} <= c:
                    return
                fields = ["ZFILENAME", "ZDATECREATED"] + [
                    n for n in ("ZDIRECTORY", "ZWIDTH", "ZHEIGHT") if n in c
                ]
                names = {
                    r["name"]: r["count"]
                    for r in index.execute("SELECT name,COUNT(*) AS count FROM media GROUP BY name")
                }
                for row in photos.execute("SELECT " + ",".join(fields) + " FROM ZASSET"):
                    value = row["ZDATECREATED"]
                    if not isinstance(value, (float, int)):
                        continue
                    date = metadata_date(value + 978307200)
                    if not date:
                        continue
                    filename = row["ZFILENAME"]
                    directory = row["ZDIRECTORY"] if "ZDIRECTORY" in c else ""
                    size_fields = tuple(
                        (
                            row[name]
                            if name in c and isinstance(row[name], int) and 0 < row[name] <= 100000
                            else None
                        )
                        for name in ("ZWIDTH", "ZHEIGHT")
                    )
                    if directory:
                        suffix = (str(directory).strip("/") + "/" + str(filename)).replace(
                            "\\", "/"
                        )
                        index.execute(
                            "UPDATE media SET date=?,dateSource='capture',width=?,height=? WHERE path=? OR path=?",
                            [date, *size_fields, suffix, "Media/" + suffix],
                        )
                    elif names.get(filename) == 1:
                        index.execute(
                            "UPDATE media SET date=?,dateSource='capture',width=?,height=? WHERE name=?",
                            [date, *size_fields, filename],
                        )
        except (DatasetUnavailable, sqlite3.DatabaseError, ValueError, OSError):
            pass

    def read(self, backup, query="", offset=0, limit=100, filters=None, sort=None, order=None):
        filters = filters or {}
        where = []
        args = []
        if query:
            where.append("path LIKE ? ESCAPE '\\'")
            args.append(
                "%" + str(query).replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_") + "%"
            )
        media_type = filters.get("mediaType", filters.get("type"))
        if media_type in ("photos", "photo", "image"):
            where.append("video=0")
        elif media_type in ("videos", "video"):
            where.append("video=1")
        for name, operator in (("dateFrom", ">="), ("dateTo", "<")):
            bound = date_bound(filters.get(name), name == "dateTo")
            if bound is not None:
                where.append("date<>'' AND date" + operator + "?")
                args.append(datetime.fromtimestamp(bound, timezone.utc).isoformat())
        for key, operator in (("minSize", ">="), ("maxSize", "<=")):
            if filters.get(key) not in (None, ""):
                value = int(filters[key])
                if value < 0:
                    raise ValueError("Storage size cannot be negative.")
                where.append("size" + operator + "?")
                args.append(value)
        for key, negated in (("ids", False), ("excludeIds", True)):
            if key in filters:
                values = filters[key]
                if not isinstance(values, list) or len(values) > 200000:
                    raise ValueError("Invalid gallery selection.")
                where.append(
                    "id "
                    + ("NOT IN" if negated else "IN")
                    + " (SELECT CAST(value AS TEXT) FROM json_each(?))"
                )
                args.append(json.dumps(values))
        key = sort.get("key") if isinstance(sort, dict) else sort
        direction = sort.get("direction", order) if isinstance(sort, dict) else order
        key = key if key in ("id", "name", "date", "size", "path") else "date"
        direction = (
            "ASC"
            if str(direction or ("asc" if key in ("name", "path", "id") else "desc")).lower()
            == "asc"
            else "DESC"
        )
        predicate = " WHERE " + " AND ".join(where) if where else ""
        with self.connection(backup) as db:
            total = db.execute("SELECT COUNT(*) FROM media" + predicate, args).fetchone()[0]
            rows = [
                dict(r)
                for r in db.execute(
                    "SELECT * FROM media"
                    + predicate
                    + f" ORDER BY {key} IS NULL,{key} COLLATE NOCASE {direction},id {direction} LIMIT ? OFFSET ?",
                    [*args, limit, offset],
                )
            ]
        for row in rows:
            row["video"] = bool(row["video"])
            row["detail"] = row["domain"]
        return {
            "rows": rows,
            "total": total,
            "columns": ["name", "date", "size"],
            "available": True,
            "availability": {"status": "available", "message": ""},
        }
