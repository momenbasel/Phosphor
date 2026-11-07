"""One-hour bounded disk previews. Cache paths and sources never reach the UI."""

from __future__ import annotations

import hashlib
import os
from pathlib import Path
import re
import sqlite3
import stat
import threading
import time
from typing import Callable
import uuid
import weakref

CHUNK = 1024 * 1024
DEFAULT_BUDGET = 512 * CHUNK
DEFAULT_TTL = 3600
_instances = weakref.WeakValueDictionary()
_instances_guard = threading.RLock()
_cleanup_started = False


def _hash(value: object) -> str:
    return hashlib.sha256(str(value).encode("utf-8")).hexdigest()


def _cleanup() -> None:
    while True:
        time.sleep(60)
        with _instances_guard:
            caches = list(_instances.values())
        for cache in caches:
            try:
                cache.prune()
            except (OSError, sqlite3.Error):
                pass
        caches.clear()


class PreviewCache:
    def __new__(cls, data_dir, *, ttl=DEFAULT_TTL, max_bytes=DEFAULT_BUDGET, clock=time.time):
        global _cleanup_started
        identity = (str(Path(data_dir).resolve()), float(ttl), int(max_bytes), id(clock))
        with _instances_guard:
            existing = _instances.get(identity)
            if existing is not None:
                return existing
            instance = super().__new__(cls)
            instance._init_guard = threading.RLock()
            _instances[identity] = instance
            if not _cleanup_started:
                threading.Thread(
                    target=_cleanup, name="Phosphor preview expiry", daemon=True
                ).start()
                _cleanup_started = True
            return instance

    def __init__(self, data_dir, *, ttl=DEFAULT_TTL, max_bytes=DEFAULT_BUDGET, clock=time.time):
        with self._init_guard:
            if getattr(self, "_ready", False):
                return
            self.root = Path(data_dir) / "previews"
            if self.root.is_symlink() or (
                hasattr(self.root, "is_junction") and self.root.is_junction()
            ):
                raise ValueError("The preview cache cannot be a link or junction.")
            self.root.mkdir(parents=True, exist_ok=True)
            self.root = self.root.resolve()
            self.ttl, self.max_bytes, self.clock = float(ttl), int(max_bytes), clock
            if not 0 < self.ttl <= 3600 or self.max_bytes <= 0:
                raise ValueError(
                    "Choose a positive preview cache budget and an expiry of at most one hour."
                )
            self.guard = threading.RLock()
            self.db = sqlite3.connect(self.root / "index.sqlite", check_same_thread=False)
            self.db.row_factory = sqlite3.Row
            self.db.execute("PRAGMA journal_mode=WAL")
            self.db.execute(
                "CREATE TABLE IF NOT EXISTS previews(id TEXT PRIMARY KEY, scope TEXT, filename TEXT, size INTEGER, access REAL, expires REAL)"
            )
            self.db.execute("CREATE INDEX IF NOT EXISTS preview_scopes ON previews(scope)")
            self.db.commit()
            self._last_prune = 0.0
            self._ready = True
            self.prune(startup=True)

    def _path(self, filename: str) -> Path:
        if not re.fullmatch(r"[a-f0-9]{64}\.[a-z0-9]{1,12}", filename):
            raise ValueError("Invalid cache entry.")
        path = self.root / filename
        if path.is_symlink() or (hasattr(path, "is_junction") and path.is_junction()):
            raise ValueError("The cached preview is no longer a regular file.")
        return path

    def _delete(self, row) -> None:
        try:
            path = self._path(row["filename"])
            if path.exists() and stat.S_ISREG(path.lstat().st_mode):
                path.unlink()
        except (OSError, ValueError):
            pass
        self.db.execute("DELETE FROM previews WHERE id=?", (row["id"],))

    def prune(self, *, startup=False) -> None:
        with self.guard:
            now = self.clock()
            for row in self.db.execute(
                "SELECT * FROM previews WHERE expires<=? OR (? AND filename LIKE '%.source')",
                (now, int(startup)),
            ).fetchall():
                self._delete(row)
            total = self.db.execute("SELECT COALESCE(SUM(size),0) FROM previews").fetchone()[0]
            if total > self.max_bytes:
                for row in self.db.execute("SELECT * FROM previews ORDER BY access, id").fetchall():
                    self._delete(row)
                    total -= row["size"]
                    if total <= self.max_bytes:
                        break
            self.db.commit()
            self._last_prune = now
            # Remove expired interrupted stages/orphaned generated entries only.
            # Never traverse another directory or follow a source link.
            known = {row[0] for row in self.db.execute("SELECT filename FROM previews")}
            for path in self.root.iterdir():
                if not (
                    re.fullmatch(r"[a-f0-9]{64}\.[a-z0-9]{1,12}", path.name)
                    or re.fullmatch(r"\.stage-[a-f0-9]{32}", path.name)
                ):
                    continue
                try:
                    info = path.lstat()
                    expired_or_transient = (
                        info.st_mtime < now - self.ttl
                        or startup
                        and (path.name.startswith(".stage-") or path.suffix == ".source")
                    )
                    if (
                        stat.S_ISREG(info.st_mode)
                        and path.name not in known
                        and expired_or_transient
                    ):
                        path.unlink()
                except OSError:
                    pass

    def get(self, scope: object, key: object) -> Path | None:
        identity = _hash(str(scope) + "\0" + str(key))
        with self.guard:
            now = self.clock()
            if now - self._last_prune >= 60:
                self.prune()
            row = self.db.execute(
                "SELECT * FROM previews WHERE id=? AND scope=?", (identity, _hash(scope))
            ).fetchone()
            if row is None:
                return None
            try:
                path = self._path(row["filename"])
                info = path.lstat()
                valid = (
                    stat.S_ISREG(info.st_mode)
                    and info.st_size == row["size"]
                    and row["expires"] > now
                )
            except (OSError, ValueError):
                valid = False
            if not valid:
                self._delete(row)
                self.db.commit()
                return None
            self.db.execute(
                "UPDATE previews SET access=?,expires=? WHERE id=?", (now, now + self.ttl, identity)
            )
            self.db.commit()
            return path

    def put(
        self,
        scope: object,
        key: object,
        writer: Callable[[Path], None],
        *,
        suffix=".jpg",
        max_item_bytes=256 * CHUNK,
    ) -> Path:
        if not re.fullmatch(r"\.[a-z0-9]{1,12}", suffix):
            raise ValueError("Invalid preview cache format.")
        maximum = min(int(max_item_bytes), self.max_bytes)
        if maximum <= 0:
            raise ValueError("Invalid preview file limit.")
        with self.guard:
            cached = self.get(scope, key)
            if cached is not None:
                return cached
            identity = _hash(str(scope) + "\0" + str(key))
            destination = self._path(identity + suffix)
            stage = self.root / (".stage-" + uuid.uuid4().hex)
            try:
                writer(stage)
                info = stage.lstat()
                if not stat.S_ISREG(info.st_mode) or stage.is_symlink() or info.st_nlink != 1:
                    raise ValueError("The preview writer must produce a regular cache file.")
                if info.st_size > maximum:
                    raise ValueError("The generated preview exceeds its disk cache limit.")
                old = self.db.execute("SELECT * FROM previews WHERE id=?", (identity,)).fetchone()
                if old:
                    self._delete(old)
                os.replace(stage, destination)
                now = self.clock()
                self.db.execute(
                    "INSERT OR REPLACE INTO previews VALUES(?,?,?,?,?,?)",
                    (identity, _hash(scope), destination.name, info.st_size, now, now + self.ttl),
                )
                self.db.commit()
                self.prune()
                return destination
            finally:
                stage.unlink(missing_ok=True)

    def materialize(
        self,
        scope: object,
        key: object,
        size: int,
        reader: Callable[[int, int], bytes],
        *,
        suffix=".source",
        max_item_bytes=256 * CHUNK,
    ) -> Path:
        size = int(size)
        if size < 0 or size > min(int(max_item_bytes), self.max_bytes):
            raise ValueError("This file exceeds the source size limit for conversion.")

        def write(path: Path) -> None:
            with path.open("xb") as output:
                for offset in range(0, size, CHUNK):
                    requested = min(CHUNK, size - offset)
                    data = reader(offset, requested)
                    if not isinstance(data, bytes) or len(data) != requested:
                        raise ValueError(
                            "The preview source changed or its transfer was incomplete."
                        )
                    output.write(data)

        return self.put(scope, key, write, suffix=suffix, max_item_bytes=max_item_bytes)

    def read(self, path: Path, offset=0, length=CHUNK) -> bytes:
        path = Path(path).absolute()
        if path.parent != self.root:
            raise ValueError("The preview path leaves the cache.")
        offset, length = int(offset), int(length)
        if offset < 0 or not 0 <= length <= CHUNK:
            raise ValueError("Invalid cached preview range.")
        with self.guard:
            row = self.db.execute(
                "SELECT * FROM previews WHERE filename=?", (path.name,)
            ).fetchone()
            if row is None or row["expires"] <= self.clock():
                raise ValueError("This cached preview expired. Open it again.")
            checked = self._path(path.name)
            info = checked.lstat()
            if not stat.S_ISREG(info.st_mode) or info.st_size != row["size"]:
                raise ValueError("This cached preview changed. Open it again.")
            with checked.open("rb") as handle:
                handle.seek(offset)
                result = handle.read(min(length, max(0, row["size"] - offset)))
            now = self.clock()
            if now - row["access"] >= 60:
                self.db.execute(
                    "UPDATE previews SET access=?,expires=? WHERE id=?",
                    (now, now + self.ttl, row["id"]),
                )
                self.db.commit()
            return result

    def remove(self, path: Path) -> None:
        path = Path(path).absolute()
        if path.parent != self.root:
            raise ValueError("The preview path leaves the cache.")
        with self.guard:
            self._path(path.name)
            row = self.db.execute(
                "SELECT * FROM previews WHERE filename=?", (path.name,)
            ).fetchone()
            if row is not None:
                self._delete(row)
                self.db.commit()

    def invalidate(self, scope: object | None = None) -> None:
        with self.guard:
            query, args = (
                ("SELECT * FROM previews", ())
                if scope is None
                else ("SELECT * FROM previews WHERE scope=?", (_hash(scope),))
            )
            for row in self.db.execute(query, args).fetchall():
                self._delete(row)
            self.db.commit()
