"""Read-only gallery previews, reversible review decisions, and bounded duplicate scans.

Encrypted media is decrypted in small range requests in RAM. Review decisions are
local annotations; they never modify a backup or send commands to an iPhone.
"""

import base64
import hashlib
import io
import json
import mimetypes
import re
import secrets
import sqlite3
import threading
import time
from pathlib import Path

from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
from backup import archive_metadata
from preview_cache import PreviewCache
from media import image_preview, MAX_PREVIEW_SOURCE_BYTES

MAX_CHUNK = 1024 * 1024
MAX_IMAGE_BYTES = 32 * 1024 * 1024
MAX_SCAN_ITEMS = 100000
MAX_RESULT_GROUPS = 1000
PHOTO_SUFFIXES = {
    ".jpg",
    ".jpeg",
    ".png",
    ".heic",
    ".heif",
    ".webp",
    ".gif",
    ".tif",
    ".tiff",
    ".dng",
}
VIDEO_SUFFIXES = {".mov", ".mp4", ".m4v"}
MEDIA_SUFFIXES = PHOTO_SUFFIXES | VIDEO_SUFFIXES


def _preview_source(store, backup, file):
    entries = store.entries(backup, [file])
    if not entries:
        raise ValueError("This photo or video is not present in the selected backup.")
    entry = entries[0]
    suffix = Path(entry["relativePath"]).suffix.lower()
    if suffix not in MEDIA_SUFFIXES:
        raise ValueError("Only gallery photos and videos can be previewed.")
    file_id = entry["fileID"]
    if not re.fullmatch(r"[a-fA-F0-9]{40}", file_id):
        raise ValueError("Invalid backup file identifier.")
    base = store.path(backup)
    source = base / file_id[:2] / file_id
    if not source.exists():
        source = base / file_id
    if source.is_symlink() or not source.resolve().is_relative_to(base) or not source.is_file():
        raise ValueError("The gallery source file is missing or outside its backup.")
    meta = archive_metadata(entry.get("file"))
    size = source.stat().st_size
    with store.guard:
        session = store.unlocked.get(str(base))
    key = None
    if session:
        if not meta.get("EncryptionKey"):
            raise ValueError("The media file has no encryption key in this backup.")
        key = session[0].unwrap(meta["EncryptionKey"])
        if size % 16:
            raise ValueError("The encrypted media file is incomplete.")
        real_size = meta.get("Size")
        if not isinstance(real_size, int) or not 0 <= real_size <= size:
            raise ValueError("The encrypted media file has invalid size metadata.")
        size = real_size
    return {
        "source": source,
        "entry": entry,
        "key": key,
        "size": size,
        "mime": {
            ".heic": "image/heic",
            ".heif": "image/heif",
            ".mov": "video/quicktime",
            ".m4v": "video/mp4",
        }.get(suffix, mimetypes.guess_type("file" + suffix)[0] or "application/octet-stream"),
        "name": Path(entry["relativePath"]).name,
        "backup": str(base),
        "suffix": suffix,
    }


def read_range(source, offset=0, length=MAX_CHUNK):
    """Seek CBC ciphertext using its previous block as IV; return only requested bytes."""
    offset, length = int(offset), int(length)
    if offset < 0 or length < 0 or length > MAX_CHUNK:
        raise ValueError("Invalid media range.")
    size = source["size"]
    length = min(length, max(0, size - offset))
    if not length:
        return b""
    if source.get("backup") and (
        source["source"].is_symlink()
        or not source["source"].resolve().is_relative_to(Path(source["backup"]))
    ):
        raise ValueError("The media file is outside its backup.")
    key = source.get("key")
    if not key:
        with source["source"].open("rb") as handle:
            handle.seek(offset)
            result = handle.read(length)
    else:
        aligned = offset // 16 * 16
        end = ((offset + length + 15) // 16) * 16
        with source["source"].open("rb") as handle:
            if aligned:
                handle.seek(aligned - 16)
                iv = handle.read(16)
            else:
                iv = bytes(16)
            handle.seek(aligned)
            ciphertext = handle.read(end - aligned)
        if len(iv) != 16 or len(ciphertext) != end - aligned:
            raise ValueError("This backup media file is incomplete.")
        ctx = Cipher(algorithms.AES(key), modes.CBC(iv)).decryptor()
        plain = ctx.update(ciphertext) + ctx.finalize()
        result = plain[offset - aligned : offset - aligned + length]
    if len(result) != length:
        raise ValueError("This backup media file is incomplete.")
    return result


class Gallery:
    def __init__(self, store, reader, profile):
        self.store, self.reader = store, reader
        self.guard = threading.RLock()
        self.profile = Path(profile) / "gallery"
        self.profile.mkdir(parents=True, exist_ok=True)
        self.state_file = self.profile / "review.json"
        try:
            self.state = json.loads(self.state_file.read_text("utf-8"))
            if not isinstance(self.state, dict):
                self.state = {}
        except (OSError, ValueError):
            self.state = {}
        self.tokens = {}
        self.results = {}
        self.preview_cache = PreviewCache(profile)
        # Hash metadata is separate from the bounded, expiring preview cache.
        self.cache_file = self.profile / "hashes.sqlite"
        with sqlite3.connect(self.cache_file) as db:
            db.execute(
                "CREATE TABLE IF NOT EXISTS hashes (scope TEXT, file TEXT, fingerprint TEXT, digest TEXT, visual TEXT, PRIMARY KEY(scope,file))"
            )

    def _scope(self, backup):
        path = self.store.path(backup)
        return hashlib.sha256(str(path).encode("utf-8")).hexdigest()

    def review_state(self, backup):
        scope = self._scope(backup)
        with self.guard:
            decisions = dict(self.state.get(scope, {}))
        return {
            "kept": sum(value == "keep" for value in decisions.values()),
            "bin": sum(value == "bin" for value in decisions.values()),
            "decisions": decisions,
        }

    def review_set(self, backup, files, decision):
        if decision not in ("keep", "bin", "reset"):
            raise ValueError("Choose keep, review bin, or reset.")
        if not isinstance(files, list) or not 1 <= len(files) <= 500:
            raise ValueError("Review between one and 500 gallery items at a time.")
        entries = self.store.entries(backup, files)
        valid = {
            entry["fileID"]
            for entry in entries
            if Path(entry["relativePath"]).suffix.lower() in MEDIA_SUFFIXES
        }
        if len(valid) != len(set(files)):
            raise ValueError("One or more selected gallery items are unavailable.")
        scope = self._scope(backup)
        with self.guard:
            decisions = self.state.setdefault(scope, {})
            for file in files:
                if decision == "reset":
                    decisions.pop(file, None)
                else:
                    decisions[file] = decision
            temporary = self.state_file.with_suffix(".tmp")
            temporary.write_text(json.dumps(self.state, separators=(",", ":")), "utf-8")
            temporary.replace(self.state_file)
        return self.review_state(backup)

    def list(self, backup, query="", offset=0, limit=120, filters=None, sort=None, review="all"):
        if review not in ("all", "unreviewed", "kept", "bin"):
            raise ValueError("Unknown gallery collection.")
        filters = dict(filters or {})
        state = self.review_state(backup)
        decisions = state.pop("decisions")
        if review in ("kept", "bin"):
            wanted = "keep" if review == "kept" else "bin"
            filters["ids"] = [key for key, value in decisions.items() if value == wanted]
        elif review == "unreviewed":
            filters["excludeIds"] = list(decisions)
        else:
            # Review-bin items remain in the original backup, but leave the main collection.
            filters["excludeIds"] = [key for key, value in decisions.items() if value == "bin"]
        result = self.reader.read(
            backup,
            "photos",
            query,
            max(0, int(offset)),
            min(120, max(1, int(limit))),
            filters=filters,
            sort=sort,
        )
        for row in result["rows"]:
            row["decision"] = decisions.get(row["id"], "")
        result["counts"] = state
        return result

    def _rendition(self, source, file, edge=4096, quality=90):
        scope = "backup:" + source["backup"]
        base = f"{file}:{self._fingerprint(source)}:image"
        key = f"{base}:{edge}:{quality}"
        cached = self.preview_cache.get(scope, key)
        if cached is not None:
            return cached
        if edge < 4096:
            full = self.preview_cache.get(scope, f"{base}:4096:90")
            if full is not None:
                return self.preview_cache.put(
                    scope,
                    key,
                    lambda target: image_preview(full, target, max_edge=edge, quality=quality),
                    max_item_bytes=32 * MAX_CHUNK,
                )
        original = self.preview_cache.materialize(
            scope,
            key + ":source",
            source["size"],
            lambda offset, length: read_range(source, offset, length),
            max_item_bytes=MAX_PREVIEW_SOURCE_BYTES,
        )
        try:
            return self.preview_cache.put(
                scope,
                key,
                lambda target: image_preview(
                    original, target, max_edge=edge, quality=quality, source_format=source["suffix"]
                ),
                max_item_bytes=32 * MAX_CHUNK,
            )
        finally:
            self.preview_cache.remove(original)

    def thumbnail(self, backup, file):
        source = _preview_source(self.store, backup, file)
        if source["suffix"] in VIDEO_SUFFIXES:
            return ""
        cached = self._rendition(source, file, 320, 78)
        return "data:image/jpeg;base64," + base64.b64encode(
            self.preview_cache.read(cached, 0, MAX_CHUNK)
        ).decode("ascii")

    def preview(self, backup, file):
        source = _preview_source(self.store, backup, file)
        if source["suffix"] in (".heic", ".heif", ".tif", ".tiff", ".dng"):
            cached = self._rendition(source, file)
            source["cachePath"] = cached
            source["size"] = cached.stat().st_size
            source["mime"] = "image/jpeg"
        token = secrets.token_urlsafe(32)
        source["expires"] = time.monotonic() + 3600
        with self.guard:
            self._expire_tokens()
            # At most eight preview handles. Video originals stay streamed.
            while len(self.tokens) >= 8:
                self.tokens.pop(next(iter(self.tokens)))
            self.tokens[token] = source
        return {key: source[key] for key in ("size", "mime", "name")} | {"token": token}

    def _expire_tokens(self):
        now = time.monotonic()
        for token in list(self.tokens):
            if self.tokens[token]["expires"] < now:
                del self.tokens[token]

    def _token(self, token):
        if not isinstance(token, str) or not re.fullmatch(r"[A-Za-z0-9_-]{43}", token):
            raise ValueError("Invalid preview token.")
        with self.guard:
            self._expire_tokens()
            source = self.tokens.get(token)
            if source is None:
                raise ValueError("This preview expired. Open the gallery item again.")
            # Unlock state is checked again so locking a backup revokes encrypted previews.
            if source.get("key") and source["backup"] not in self.store.unlocked:
                self.tokens.pop(token, None)
                raise ValueError("Unlock this backup to preview its media.")
            source["expires"] = time.monotonic() + 3600
            return source

    def preview_info(self, token):
        source = self._token(token)
        return {key: source[key] for key in ("size", "mime", "name")}

    def preview_chunk(self, token, offset=0, length=MAX_CHUNK):
        source = self._token(token)
        offset, length = int(offset), int(length)
        if offset < 0 or length < 0 or length > MAX_CHUNK:
            raise ValueError("Invalid media range.")
        data = (
            self.preview_cache.read(source["cachePath"], offset, length)
            if "cachePath" in source
            else (
                source["data"][offset : offset + length]
                if "data" in source
                else read_range(source, offset, length)
            )
        )
        return {
            "data": base64.b64encode(data).decode("ascii"),
            "next": offset + len(data),
            "eof": offset + len(data) >= source["size"],
        }

    def release(self, token=None, backup=None):
        with self.guard:
            if token is not None:
                self.tokens.pop(token, None)
            elif backup is not None:
                path = str(self.store.path(backup))
                for key in list(self.tokens):
                    if self.tokens[key]["backup"] == path:
                        del self.tokens[key]
            else:
                self.tokens.clear()

    def invalidate(self, backup):
        """Revoke keys and renditions before locking or deleting a backup."""
        self.release(backup=backup)
        self.preview_cache.invalidate("backup:" + str(self.store.path(backup)))
        scope = self._scope(backup)
        with self.guard:
            for key in list(self.results):
                if key[0] == scope:
                    del self.results[key]

    def _fingerprint(self, source):
        stat = source["source"].stat()
        return f"{source['size']}:{stat.st_size}:{stat.st_mtime_ns}"

    def _hash(self, backup, row, job, visual=False):
        source = _preview_source(self.store, backup, row["id"])
        scope = self._scope(backup)
        fingerprint = self._fingerprint(source)
        with sqlite3.connect(self.cache_file) as db:
            cached = db.execute(
                "SELECT digest, visual FROM hashes WHERE scope=? AND file=? AND fingerprint=?",
                [scope, row["id"], fingerprint],
            ).fetchone()
        if cached and cached[0] and (not visual or cached[1]):
            return cached
        digest = hashlib.sha256()
        raw = (
            bytearray()
            if visual and source["suffix"] in PHOTO_SUFFIXES and source["size"] <= MAX_IMAGE_BYTES
            else None
        )
        for offset in range(0, source["size"], MAX_CHUNK):
            job.check()
            chunk = read_range(source, offset, MAX_CHUNK)
            digest.update(chunk)
            if raw is not None:
                raw.extend(chunk)
        visual_hash = ""
        if raw is not None:
            from PIL import Image, ImageOps
            from pillow_heif import register_heif_opener

            register_heif_opener()
            try:
                image = Image.open(io.BytesIO(raw))
                if image.width * image.height <= 80_000_000:
                    image = ImageOps.exif_transpose(image).convert("L").resize((9, 8))
                    pixels = image.tobytes()
                    value = 0
                    for y in range(8):
                        for x in range(8):
                            value = (value << 1) | (pixels[y * 9 + x] > pixels[y * 9 + x + 1])
                    visual_hash = f"{value:016x}"
            except (ValueError, OSError, Image.DecompressionBombError):
                pass
        result = digest.hexdigest(), visual_hash
        with sqlite3.connect(self.cache_file) as db:
            db.execute(
                "INSERT OR REPLACE INTO hashes VALUES (?,?,?,?,?)",
                [scope, row["id"], fingerprint, *result],
            )
        return result

    def scan_duplicates(self, backup, job, mode="exact", max_items=20000):
        if mode not in ("exact", "similar"):
            raise ValueError("Choose exact duplicates or similar photos.")
        max_items = max(1, min(MAX_SCAN_ITEMS, int(max_items)))
        scope = self._scope(backup)
        rows, offset, total = [], 0, 0
        while len(rows) < max_items:
            job.check()
            page = self.reader.read(
                backup,
                "photos",
                offset=offset,
                limit=min(500, max_items - len(rows)),
                filters={"mediaType": "photos" if mode == "similar" else "all"},
                sort={"key": "name", "direction": "asc"},
            )
            total = page["total"]
            rows.extend(page["rows"])
            offset += len(page["rows"])
            if offset >= total or not page["rows"]:
                break
        # Equal-size candidates are necessary for byte-identical files. Avoid
        # hashing unique-size videos that cannot have exact duplicates.
        sizes = {}
        for row in rows:
            sizes.setdefault(row.get("size"), []).append(row)
        candidates = (
            rows
            if mode == "similar"
            else [
                row
                for size, items in sizes.items()
                if size is None or len(items) > 1
                for row in items
            ]
        )
        exact, visual_items, skipped = {}, [], 0
        for index, row in enumerate(candidates):
            job.check()
            job.progress(
                index / max(1, len(candidates)) * 95,
                f"Checking {index+1:,} of {len(candidates):,} candidate files",
            )
            try:
                digest, visual = self._hash(backup, row, job, mode == "similar")
                exact.setdefault(digest, []).append(row)
                if visual:
                    visual_items.append((int(visual, 16), row, digest))
            except (OSError, ValueError):
                skipped += 1
        groups = [
            {
                "id": digest,
                "kind": "exact",
                "items": items[:40],
                "itemCount": len(items),
                "bytesRecoverable": sum(row.get("size") or 0 for row in items[1:]),
            }
            for digest, items in exact.items()
            if len(items) > 1
        ]
        comparison_limited = False
        if mode == "similar":
            # Four 16-bit buckets make Hamming-distance <=3 candidates complete
            # without an O(n²) all-pairs comparison. Large uniform-image buckets
            # are capped, and approximate matches are always suggestions.
            buckets, pairs = {}, set()
            for index, (value, row, digest) in enumerate(visual_items):
                job.check()
                candidates_by_bucket = set()
                for segment in range(4):
                    key = (segment, value >> (segment * 16) & 0xFFFF)
                    candidates_by_bucket.update(buckets.get(key, ())[-200:])
                for other in candidates_by_bucket:
                    prior, prior_row, prior_digest = visual_items[other]
                    if prior_digest != digest and (value ^ prior).bit_count() <= 3:
                        pair = (prior_row["id"], row["id"])
                        if pair not in pairs and len(groups) < MAX_RESULT_GROUPS:
                            pairs.add(pair)
                            groups.append(
                                {
                                    "id": hashlib.sha256(("|".join(pair)).encode()).hexdigest(),
                                    "kind": "similar",
                                    "distance": (value ^ prior).bit_count(),
                                    "items": [prior_row, row],
                                    "itemCount": 2,
                                    "bytesRecoverable": 0,
                                }
                            )
                for segment in range(4):
                    key = (segment, value >> (segment * 16) & 0xFFFF)
                    bucket = buckets.setdefault(key, [])
                    bucket.append(index)
                    if len(bucket) > 200:
                        comparison_limited = True
                        del bucket[0]
        result = {
            "groups": groups[:MAX_RESULT_GROUPS],
            "mode": mode,
            "scanned": len(rows),
            "hashed": len(candidates) - skipped,
            "skipped": skipped,
            "total": total,
            "truncated": len(rows) < total or len(groups) > MAX_RESULT_GROUPS or comparison_limited,
            "comparisonLimited": comparison_limited,
            "similarSuggestions": mode == "similar",
            "finished": time.time(),
        }
        with self.guard:
            self.results[(scope, mode)] = result
        job.progress(99, f'Found {len(result["groups"]):,} duplicate groups')
        return {key: value for key, value in result.items() if key != "groups"}

    def groups(self, backup, mode="exact", offset=0, limit=40):
        scope = self._scope(backup)
        with self.guard:
            result = self.results.get((scope, mode))
            if result is None:
                return {"groups": [], "totalGroups": 0, "ready": False, "mode": mode}
            start = max(0, int(offset))
            result = dict(result)
            groups = result.pop("groups")
            decisions = self.state.get(scope, {})
            selected = [
                {
                    **group,
                    "items": [
                        {**row, "decision": decisions.get(row["id"], "")} for row in group["items"]
                    ],
                }
                for group in groups[start : start + min(100, max(1, int(limit)))]
            ]
            return result | {"groups": selected, "totalGroups": len(groups), "ready": True}
