"""Cached physical measurements and logical storage breakdowns.

The catalog never deletes a backup. Logical sizes require an unlocked manifest;
physical measurements can inspect encrypted snapshots without secrets.
"""

import json
import os
import threading
import time
from collections import OrderedDict
from datetime import datetime, timezone
from pathlib import Path

from backup import archive_metadata, load_plist

CATEGORIES = {
    "photos": "Photos",
    "videos": "Videos",
    "messages": "Messages",
    "whatsapp": "WhatsApp",
    "contacts": "Contacts",
    "calendar": "Calendar",
    "notes": "Notes",
    "calls": "Call history",
    "safari": "Safari",
    "audio": "Music & audio",
    "health": "Health",
    "watch": "Apple Watch",
    "keychain": "Keychain",
    "settings": "Settings",
    "appdata": "Other app data",
    "system": "Other device data",
}
IMAGE_EXT = {".jpg", ".jpeg", ".png", ".heic", ".heif", ".gif", ".tif", ".tiff", ".webp", ".dng"}
VIDEO_EXT = {".mov", ".mp4", ".m4v"}
AUDIO_EXT = {".mp3", ".m4a", ".m4r", ".wav", ".aac", ".aiff", ".flac", ".ogg"}


def category(domain, path):
    domain = str(domain or "").lower()
    path = str(path or "").replace("\\", "/").lower()
    suffix = Path(path).suffix
    if (
        "whatsapp" in domain
        or "whatsapp" in path
        or path.rsplit("/", 1)[-1]
        in ("chatstorage.sqlite", "chatstorage.db", "chatstorage.sqlite.enc")
    ):
        return "whatsapp"
    for needle, kind in (
        ("/sms/", "messages"),
        ("/addressbook/", "contacts"),
        ("/calendar/", "calendar"),
        ("/notes/", "notes"),
        ("/callhistory", "calls"),
        ("/safari/", "safari"),
        ("/health/", "health"),
        ("/watch/", "watch"),
    ):
        if needle in "/" + path:
            return kind
    if "com.apple.notes" in domain:
        return "notes"
    if "health" in domain:
        return "health"
    if "watch" in domain:
        return "watch"
    if "keychain" in domain or "keychain" in path:
        return "keychain"
    if domain in ("camerarolldomain", "mediadomain") and suffix in VIDEO_EXT:
        return "videos"
    if domain == "camerarolldomain" or domain == "mediadomain" and suffix in IMAGE_EXT:
        return "photos"
    if suffix in AUDIO_EXT:
        return "audio"
    if domain.startswith("appdomain"):
        return "appdata"
    if "/preferences/" in "/" + path or "settings" in domain:
        return "settings"
    return "system"


def _fingerprint(path):
    values = []
    for name in ("", "Manifest.db", "Manifest.plist", "Info.plist", "Status.plist"):
        try:
            stat = (path / name).stat()
            values.append([name, stat.st_size, stat.st_mtime_ns])
        except OSError:
            values.append([name, None, None])
    return values


def _linked(path):
    return path.is_symlink() or (hasattr(path, "is_junction") and path.is_junction())


class BackupCatalog:
    def __init__(self, store, profile):
        self.store = store
        self.guard = threading.RLock()
        self.logical = OrderedDict()
        self.cache_file = Path(profile) / "backup-sizes.json"
        try:
            cached = json.loads(self.cache_file.read_text("utf-8"))
            self.sizes = cached if isinstance(cached, dict) else {}
        except (OSError, ValueError):
            self.sizes = {}

    def _save(self):
        self.cache_file.parent.mkdir(parents=True, exist_ok=True)
        target = self.cache_file.with_suffix(".tmp")
        target.write_text(json.dumps(self.sizes, separators=(",", ":")), "utf-8")
        os.replace(target, self.cache_file)

    def invalidate(self, backup=None):
        path = str(self.store.path(backup)) if backup is not None else None
        with self.guard:
            for key in list(self.logical):
                if path is None or key[0] == path:
                    self.logical.pop(key, None)
            if path is None:
                self.sizes.clear()
            else:
                self.sizes.pop(path, None)
            self._save()

    def clear_logical(self, backup=None):
        path = str(self.store.path(backup)) if backup is not None else None
        with self.guard:
            for key in list(self.logical):
                if path is None or key[0] == path:
                    self.logical.pop(key, None)

    def cached_size(self, backup):
        path = self.store.path(backup)
        with self.guard:
            value = self.sizes.get(str(path))
        if isinstance(value, dict) and value.get("fingerprint") == _fingerprint(path):
            return {k: v for k, v in value.items() if k != "fingerprint"} | {"cached": True}
        return {
            "bytes": None,
            "files": None,
            "status": "unmeasured",
            "checkedAt": None,
            "cached": False,
        }

    def physical_size(self, backup, job=None, refresh=False):
        path = self.store.path(backup)
        if _linked(path):
            raise ValueError("Measure the original backup folder rather than a link or junction.")
        cached = self.cached_size(backup)
        if not refresh and cached["status"] != "unmeasured":
            return cached
        total = files = directories = skipped = 0
        stack = [path]
        start = time.monotonic()
        last = start
        while stack:
            if job:
                job.check()
            current = stack.pop()
            if not current.resolve().is_relative_to(path) or _linked(current):
                skipped += 1
                continue
            try:
                with os.scandir(current) as entries:
                    for entry in entries:
                        if job:
                            job.check()
                        try:
                            source = Path(entry.path)
                            if entry.is_symlink() or _linked(source):
                                skipped += 1
                                continue
                            if entry.is_dir(follow_symlinks=False):
                                stack.append(source)
                                directories += 1
                            elif entry.is_file(follow_symlinks=False):
                                total += entry.stat(follow_symlinks=False).st_size
                                files += 1
                            else:
                                skipped += 1
                        except OSError:
                            skipped += 1
                        now = time.monotonic()
                        if job and now - last >= 0.5:
                            job.progress(
                                None, f"Measuring backup · {files:,} files · {total:,} bytes"
                            )
                            last = now
            except OSError:
                skipped += 1
        if job:
            job.check()
        result = {
            "bytes": total,
            "files": files,
            "directories": directories,
            "skipped": skipped,
            "status": "partial" if skipped else "complete",
            "checkedAt": datetime.now(timezone.utc).isoformat(),
            "elapsedSeconds": round(time.monotonic() - start, 3),
            "fingerprint": _fingerprint(path),
        }
        with self.guard:
            self.sizes[str(path)] = result
            while len(self.sizes) > 256:
                self.sizes.pop(next(iter(self.sizes)))
            self._save()
        return {k: v for k, v in result.items() if k != "fingerprint"} | {"cached": False}

    def breakdown(self, backup, job=None, refresh=False):
        path = self.store.path(backup)
        key = (str(path), self.store.generation(backup), json.dumps(_fingerprint(path)))
        with self.store.connection(backup):
            pass
        with self.guard:
            cached = self.logical.get(key)
            if cached is not None and not refresh:
                self.logical.move_to_end(key)
                return cached | {"cached": True}
        domains = {}
        categories = {}
        count = total = unknown = 0
        with self.store.connection(backup) as db:
            for entry in db.execute("SELECT domain,relativePath,file FROM Files WHERE flags=1"):
                if job:
                    job.check()
                meta = archive_metadata(entry["file"])
                size = meta.get("Size")
                known = isinstance(size, int) and not isinstance(size, bool) and size >= 0
                size = size if known else 0
                total += size
                count += 1
                unknown += not known
                domain = entry["domain"] or "Unknown domain"
                kind = category(domain, entry["relativePath"])
                for target, name in ((domains, domain), (categories, kind)):
                    row = target.setdefault(name, {"bytes": 0, "count": 0, "unknownCount": 0})
                    row["bytes"] += size
                    row["count"] += 1
                    row["unknownCount"] += not known
                if job and count % 1000 == 0:
                    job.progress(None, f"Reading storage metadata · {count:,} files")
            whatsapp_rows = [
                dict(row)
                for row in db.execute(
                    "SELECT domain,relativePath,flags,file FROM Files WHERE instr(lower(domain),'whatsapp')>0 OR instr(lower(relativePath),'whatsapp')>0 OR lower(relativePath) LIKE '%chatstorage%' "
                )
            ]
        if job:
            job.check()
        whatsapp_domains = sorted({row["domain"] for row in whatsapp_rows})
        chat = [
            {
                "domain": row["domain"],
                "path": row["relativePath"],
                "encryptedAppData": str(row["relativePath"]).lower().endswith(".enc"),
                "bytes": archive_metadata(row.get("file")).get("Size"),
                "emptyPlaceholder": archive_metadata(row.get("file")).get("Size") == 0,
            }
            for row in whatsapp_rows
            if row["flags"] == 1
            and "chatstorage" in str(row["relativePath"]).rsplit("/", 1)[-1].lower()
        ]
        empty = bool(chat) and all(row["emptyPlaceholder"] for row in chat)
        protected = bool(chat) and all(row["encryptedAppData"] for row in chat)
        whatsapp = {
            "status": (
                "empty-chat-placeholder"
                if empty
                else (
                    "app-protected-archive"
                    if protected
                    else (
                        "database-present"
                        if chat
                        else "files-present-no-database" if whatsapp_rows else "not-present"
                    )
                )
            ),
            "domains": whatsapp_domains,
            "chatDatabases": chat,
            "fileCount": sum(row["flags"] == 1 for row in whatsapp_rows),
            "message": (
                "Only empty ChatStorage placeholders (0 bytes) are recorded; chat contents are not included."
                if empty
                else (
                    "WhatsApp-protected ChatStorage archives are recorded; their presence does not mean the chat contents can be decoded."
                    if protected
                    else (
                        "Chat database names are recorded in this manifest; readability is checked in the WhatsApp section."
                        if chat
                        else (
                            "WhatsApp-related entries exist, but no ChatStorage database is recorded."
                            if whatsapp_rows
                            else "No WhatsApp-related domains or paths are recorded in this manifest."
                        )
                    )
                )
            ),
        }
        result = {
            "bytes": total,
            "count": count,
            "unknownCount": unknown,
            "sizeBasis": "manifest-logical",
            "completeSizes": unknown == 0,
            "domains": [
                {"name": name, **value}
                for name, value in sorted(
                    domains.items(), key=lambda item: item[1]["bytes"], reverse=True
                )
            ],
            "categories": [
                {"id": name, "name": CATEGORIES[name], **value}
                for name, value in sorted(
                    categories.items(), key=lambda item: item[1]["bytes"], reverse=True
                )
            ],
            "whatsapp": whatsapp,
            "cached": False,
        }
        with self.guard:
            self.logical[key] = result
            while len(self.logical) > 2:
                self.logical.popitem(last=False)
        return result

    def cached_breakdown(self, backup):
        path = self.store.path(backup)
        key = (str(path), self.store.generation(backup), json.dumps(_fingerprint(path)))
        with self.store.guard:
            if str(path) not in self.store.unlocked and load_plist(path / "Manifest.plist").get(
                "IsEncrypted", False
            ):
                return None
        with self.store.connection(backup):
            pass
        with self.guard:
            value = self.logical.get(key)
            if value is None:
                return None
            self.logical.move_to_end(key)
            return value | {"cached": True}
