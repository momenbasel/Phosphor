"""Scoped file browsing: AFC Media, immutable backups, and selected PC folders.

Listing cloud placeholders reads metadata only. Phone operations share the worker's
device reservation; this module never discovers or pairs devices on its own.
"""

import asyncio
import base64
import io
import json
import mimetypes
import os
import posixpath
import re
import secrets
import shutil
import threading
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path

import device
from backup import archive_metadata, safe_component, safe_target
from backup_management import recycle
from document_preview import (
    OFFICE_SUFFIXES,
    MAX_TEXT_BYTES,
    office_preview,
    rtf_preview,
    text_preview,
)
from media import RAW_SUFFIXES, MAX_PREVIEW_SOURCE_BYTES, image_preview
from preview_cache import PreviewCache, CHUNK

TRASH = "/PhosphorTrash"
MAX_DIRECTORY = 5000
IMAGE_EXT = {
    ".jpg",
    ".jpeg",
    ".png",
    ".heic",
    ".heif",
    ".gif",
    ".webp",
    ".tif",
    ".tiff",
    ".bmp",
    ".avif",
    ".ico",
    ".icns",
    ".psd",
    ".tga",
    ".dds",
    ".jp2",
    ".j2k",
    ".pnm",
    ".ppm",
    ".pgm",
    ".pbm",
} | RAW_SUFFIXES
VIDEO_EXT = {".mov", ".mp4", ".m4v", ".avi", ".mkv"}
AUDIO_EXT = {".mp3", ".m4a", ".wav", ".aac", ".aiff", ".flac", ".ogg"}


def virtual_path(value="/"):
    value = str(value or "/")
    if (
        not value.startswith("/")
        or "\\" in value
        or "\x00" in value
        or any(p in (".", "..") for p in value.split("/"))
    ):
        raise ValueError("Use a path inside the selected source.")
    return "/" + "/".join(p for p in value.split("/") if p)


def filename(value):
    value = str(value or "").strip()
    if (
        not value
        or value in (".", "..")
        or len(value) > 180
        or re.search(r'[<>:"/\\|?*\x00-\x1f]', value)
        or value.endswith((".", " "))
        or re.match(r"^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)", value, re.I)
    ):
        raise ValueError("Use a valid file name without slashes or reserved Windows characters.")
    return value


def file_kind(name, directory=False):
    if directory:
        return "folder"
    suffix = Path(name).suffix.lower()
    return (
        "photo"
        if suffix in IMAGE_EXT
        else "video" if suffix in VIDEO_EXT else "audio" if suffix in AUDIO_EXT else "file"
    )


def timestamp(value):
    if isinstance(value, datetime):
        return value.replace(tzinfo=value.tzinfo or timezone.utc).isoformat()
    try:
        return datetime.fromtimestamp(float(value), timezone.utc).isoformat()
    except (ValueError, TypeError, OverflowError, OSError):
        return ""


def page_rows(
    rows,
    query="",
    kind="",
    sort="name",
    direction="asc",
    offset=0,
    limit=200,
    dateFrom="",
    dateTo="",
    **_,
):
    query = str(query).casefold()
    rows = [
        r
        for r in rows
        if (not query or query in r["name"].casefold())
        and (not kind or r["kind"] == kind)
        and (not dateFrom or r.get("date", "")[:10] >= dateFrom)
        and (not dateTo or r.get("date", "")[:10] <= dateTo)
    ]
    sort = sort if sort in ("name", "size", "date", "kind") else "name"
    reverse = direction == "desc"
    # Stable name tie-break, then sort folders separately from files.
    rows.sort(key=lambda r: r["name"].casefold())
    rows.sort(
        key=lambda r: (
            (r.get("size") or 0) if sort == "size" else str(r.get(sort) or "").casefold()
        ),
        reverse=reverse,
    )
    rows.sort(key=lambda r: not r["directory"])
    offset = max(0, int(offset))
    limit = max(1, min(500, int(limit)))
    return {
        "rows": rows[offset : offset + limit],
        "total": len(rows),
        "offset": offset,
        "limit": limit,
    }


def capabilities(source):
    return {
        "read": True,
        "download": True,
        "rename": source != "backup",
        "mkdir": source != "backup",
        "upload": source != "backup",
        "trash": source != "backup",
        "restore": source == "device",
        "purge": source == "device",
        "cloud": source == "icloud",
        "readOnly": source == "backup",
        "nativeRecentlyDeleted": False,
    }


def checked_local(root, virtual="/", allow_root=True):
    root = Path(root).absolute()
    virtual = virtual_path(virtual)
    target = root.joinpath(*[p for p in virtual.split("/") if p])
    if target == root and not allow_root:
        raise ValueError("The source root cannot be changed or deleted.")
    if not target.resolve().is_relative_to(root.resolve()):
        raise ValueError("The path leaves the selected source.")
    for p in (target, *target.parents):
        if p == root.parent:
            break
        if p.is_symlink() or (hasattr(p, "is_junction") and p.is_junction()):
            raise ValueError("Open links or junctions in File Explorer instead.")
    return target


class FileBrowser:
    def __init__(self, store, data_dir):
        self.store = store
        self.data_dir = Path(data_dir)
        self.roots = {}
        self.guard = threading.RLock()
        self.cache = {}
        self.preview_cache = PreviewCache(data_dir)
        self.tokens = {}

    def sources(self):
        # Conventional roots only. Custom iCloud locations are selected by the user.
        candidates = [Path.home() / "iCloudDrive", Path.home() / "iCloud Drive"]
        cloud = []
        for root in candidates:
            if (
                root.is_dir()
                and not root.is_symlink()
                and not (hasattr(root, "is_junction") and root.is_junction())
            ):
                cloud.append(self.register_local(str(root), "icloud"))
        with self.guard:
            registered = [
                {"root": token, "name": p.name, "source": source}
                for token, (p, source) in self.roots.items()
            ]
        return {
            "icloud": cloud,
            "roots": registered,
            "icloudSetup": "https://support.apple.com/guide/icloud-windows/set-up-icloud-drive-icw0144825a5/icloud",
            "icloudWeb": "https://www.icloud.com/iclouddrive",
            "icloudRecovery": "https://support.apple.com/guide/icloud-windows/recover-recently-deleted-files-icw27848c5a3/icloud",
        }

    def register_local(self, path, source="local"):
        path = Path(path).expanduser().absolute()
        if source not in ("local", "icloud"):
            raise ValueError("Choose a local folder or iCloud Drive folder.")
        if not path.is_dir():
            raise ValueError("Select an existing folder in the folder picker.")
        checked_local(path)
        with self.guard:
            token = (
                next((key for key, (p, s) in self.roots.items() if p == path and s == source), None)
                or uuid.uuid4().hex
            )
            self.roots[token] = (path, source)
        return {
            "root": token,
            "name": path.name,
            "source": source,
            "path": str(path),
            "capabilities": capabilities(source),
        }

    def local_root(self, token, source):
        with self.guard:
            entry = self.roots.get(str(token))
        if not entry or entry[1] != source:
            raise ValueError("Choose this folder in Phosphor before browsing it.")
        return entry[0]

    def _cached(self, key, loader, ttl):
        with self.guard:
            cached = self.cache.get(key)
        if cached and time.monotonic() - cached[0] < ttl:
            return cached[1]
        value = loader()
        with self.guard:
            if len(self.cache) > 48:
                self.cache.clear()
            self.cache[key] = (time.monotonic(), value)
        return value

    def invalidate(self, backup=None):
        with self.guard:
            if backup is None:
                self.cache.clear()
            else:
                key = str(Path(backup).resolve())
                self.cache = {k: v for k, v in self.cache.items() if k[2] not in (str(backup), key)}
                self.preview_cache.invalidate("backup:" + key)
                self.tokens = {
                    token: record
                    for token, record in self.tokens.items()
                    if record.get("backup") != key
                }

    def list(
        self,
        source="device",
        path="/",
        udid="",
        backup="",
        root="",
        trash=False,
        refresh=False,
        **options,
    ):
        path = virtual_path(path)
        key = (source, udid, backup, root, path, bool(trash))
        if refresh:
            with self.guard:
                self.cache.pop(key, None)
        if source == "device":
            device.validate_udid(udid)
            loader = lambda: asyncio.run(asyncio.wait_for(self._device_list(udid, path, trash), 90))
            base = self._cached(key, loader, 20)
        elif source == "backup":
            if trash:
                raise ValueError("Backup snapshots are read-only and have no file trash.")
            # Validate the current unlock state even when directory metadata is cached.
            with self.store.connection(backup):
                pass
            base = self._cached(key, lambda: self._backup_list(backup, path), 30)
        elif source in ("local", "icloud"):
            if trash:
                raise ValueError(
                    "Deleted PC files are in Windows Recycle Bin; cloud recovery is on iCloud.com."
                )
            location = checked_local(self.local_root(root, source), path)
            base = self._cached(key, lambda: self._local_list(location, path), 5)
        else:
            raise ValueError("Choose a file source.")
        return {
            **base,
            **page_rows(list(base["rows"]), **options),
            "path": path,
            "capabilities": capabilities(source),
            "source": source,
            "trash": bool(trash),
        }

    def _local_list(self, location, path):
        rows = []
        truncated = False
        with os.scandir(location) as scan:
            for entry in scan:
                if len(rows) >= MAX_DIRECTORY:
                    truncated = True
                    break
                try:
                    stat = entry.stat(follow_symlinks=False)
                    directory = entry.is_dir(follow_symlinks=False)
                    attrs = getattr(stat, "st_file_attributes", 0)
                    # Recall-on-open/recall-on-data-access/offline = cloud placeholder.
                    online = bool(attrs & (0x1000 | 0x40000 | 0x400000))
                    linked = (
                        entry.is_symlink()
                        or bool(attrs & 0x400)
                        and getattr(stat, "st_reparse_tag", 0) in (0xA000000C, 0xA0000003)
                    )
                    remote = posixpath.join(path, entry.name)
                    rows.append(
                        {
                            "id": remote,
                            "path": remote,
                            "name": entry.name,
                            "directory": directory,
                            "size": None if directory else stat.st_size,
                            "date": timestamp(stat.st_mtime),
                            "kind": file_kind(entry.name, directory),
                            "onlineOnly": online,
                            "link": linked,
                        }
                    )
                except OSError:
                    continue
        return {
            "rows": rows,
            "truncated": truncated,
            "limitNotice": (
                f"Only the first {MAX_DIRECTORY:,} entries are shown." if truncated else ""
            ),
        }

    def _backup_list(self, backup, path):
        self.store.path(backup)
        parts = [p for p in path.split("/") if p]
        with self.store.connection(backup) as db:
            if not parts:
                rows = [
                    {
                        "id": "/" + r["domain"],
                        "path": "/" + r["domain"],
                        "name": r["domain"],
                        "directory": True,
                        "size": None,
                        "date": "",
                        "kind": "folder",
                        "count": r["count"],
                    }
                    for r in db.execute(
                        "SELECT domain,COUNT(*) AS count FROM Files WHERE flags=1 GROUP BY domain ORDER BY domain"
                    )
                ]
                return {"rows": rows, "truncated": False}
            domain = parts[0]
            prefix = "/".join(parts[1:])
            prefix = prefix + "/" if prefix else ""
            # Range scan preserves literal %, _ and avoids searching other domains.
            entries = db.execute(
                "SELECT fileID,relativePath FROM Files WHERE flags=1 AND domain=? AND relativePath>=? AND relativePath<? ORDER BY relativePath LIMIT ?",
                (domain, prefix, prefix + "\uffff", 100001),
            )
            rows = {}
            truncated = False
            for index, entry in enumerate(entries):
                if index == 100000:
                    truncated = True
                    break
                relative = entry["relativePath"] or ""
                if not relative.startswith(prefix):
                    continue
                tail = relative[len(prefix) :]
                if not tail:
                    continue
                name = tail.split("/")[0]
                directory = "/" in tail
                target = posixpath.join(path, name)
                if name in rows and directory:
                    continue
                # Directory descendants need no archived metadata deserialization.
                blob = (
                    None
                    if directory
                    else db.execute(
                        "SELECT file FROM Files WHERE fileID=?", (entry["fileID"],)
                    ).fetchone()[0]
                )
                meta = {} if directory else archive_metadata(blob)
                rows[name] = {
                    "id": target,
                    "path": target,
                    "name": name,
                    "directory": directory,
                    "kind": file_kind(name, directory),
                    "size": None if directory else meta.get("Size"),
                    "date": timestamp(meta.get("LastModified")),
                    "fileId": None if directory else entry["fileID"],
                    "domain": domain,
                }
        return {
            "rows": list(rows.values()),
            "truncated": truncated,
            "limitNotice": "This folder is too large to list completely." if truncated else "",
        }

    async def _with_afc(self, udid, callback):
        from pymobiledevice3.lockdown import create_using_usbmux
        from pymobiledevice3.services.afc import AfcService

        transport = device.wireless.route(device.validate_udid(udid))
        lockdown = (
            await device.wireless.connect(transport["address"], udid)
            if transport
            else await create_using_usbmux(udid, autopair=False)
        )
        try:
            async with AfcService(lockdown=lockdown) as afc:
                return await callback(afc)
        finally:
            await lockdown.close()

    def _trash_file(self, udid):
        return self.data_dir / "file-trash" / (device.validate_udid(udid) + ".json")

    def _trash_records(self, udid):
        try:
            data = json.loads(self._trash_file(udid).read_text("utf-8"))
            return data if isinstance(data, dict) else {}
        except (OSError, ValueError):
            return {}

    def _save_trash(self, udid, records):
        target = self._trash_file(udid)
        target.parent.mkdir(parents=True, exist_ok=True)
        stage = target.with_suffix(".tmp")
        stage.write_text(json.dumps(records, ensure_ascii=False, indent=2), "utf-8")
        os.replace(stage, target)

    async def _device_list(self, udid, path, trash):
        async def load(afc):
            rows = []
            if trash:
                records = self._trash_records(udid)
                for token, item in list(records.items())[:MAX_DIRECTORY]:
                    if not re.fullmatch(r"[a-f0-9]{32}", token):
                        continue
                    target = virtual_path(item.get("target", "/"))
                    if not target.startswith(TRASH + "/"):
                        continue
                    if await afc.exists(target):
                        stat = await afc.stat(target)
                        directory = stat.get("st_ifmt") == "S_IFDIR"
                        rows.append(
                            {
                                "id": token,
                                "path": token,
                                "name": posixpath.basename(item["original"]),
                                "original": item["original"],
                                "directory": directory,
                                "kind": file_kind(item["original"], directory),
                                "size": stat.get("st_size"),
                                "date": item.get("deleted", ""),
                            }
                        )
                return {
                    "rows": rows,
                    "truncated": len(records) > MAX_DIRECTORY,
                    "limitNotice": (
                        "Too many trash entries; restore or remove a selection first."
                        if len(records) > MAX_DIRECTORY
                        else ""
                    ),
                }
            if path == TRASH or path.startswith(TRASH + "/"):
                raise ValueError("Open Phosphor Trash to manage deleted files.")
            await self._safe_afc(afc, path)
            names = [n for n in await afc.listdir(path) if n not in (".", "..", "PhosphorTrash")]
            for name in names[:MAX_DIRECTORY]:
                remote = virtual_path(posixpath.join(path, name))
                stat = await afc.stat(remote)
                directory = stat.get("st_ifmt") == "S_IFDIR"
                rows.append(
                    {
                        "id": remote,
                        "path": remote,
                        "name": name,
                        "directory": directory,
                        "size": None if directory else stat.get("st_size", 0),
                        "date": timestamp(stat.get("st_mtime")),
                        "kind": file_kind(name, directory),
                        "link": stat.get("st_ifmt") == "S_IFLNK",
                    }
                )
            return {
                "rows": rows,
                "truncated": len(names) > MAX_DIRECTORY,
                "limitNotice": (
                    f"Only the first {MAX_DIRECTORY:,} entries are shown."
                    if len(names) > MAX_DIRECTORY
                    else ""
                ),
            }

        return await self._with_afc(udid, load)

    async def _safe_afc(self, afc, path, write=False):
        path = virtual_path(path)
        if write and (path == "/" or path == TRASH or path.startswith(TRASH + "/")):
            raise ValueError("The Media root and Phosphor Trash cannot be changed directly.")
        if write and any(
            path == p or path.startswith(p + "/")
            for p in ("/DCIM", "/PhotoData", "/iTunes_Control")
        ):
            raise ValueError(
                "iOS manages this library folder. Export files here; manage the originals in Photos or Music on your iPhone."
            )
        parts = path.strip("/").split("/") if path != "/" else []
        for index in range(len(parts)):
            current = "/" + "/".join(parts[: index + 1])
            if await afc.exists(current) and (await afc.stat(current)).get("st_ifmt") == "S_IFLNK":
                raise ValueError("File operations through device links are not supported.")
        return path

    def operation(
        self,
        action,
        source="device",
        path="/",
        paths=None,
        udid="",
        backup="",
        root="",
        name="",
        localPath="",
        confirmed=False,
        job=None,
        **_,
    ):
        if action not in ("rename", "mkdir", "upload", "download", "trash", "restore", "purge"):
            raise ValueError("Choose a supported file action.")
        if paths is not None and not isinstance(paths, (list, tuple)):
            raise ValueError("Select files in the browser before this operation.")
        paths = list(dict.fromkeys(paths or []))
        if len(paths) > 200:
            raise ValueError("Select at most 200 items per operation.")
        if action in ("trash", "purge") and confirmed is not True:
            raise ValueError("Confirm the deletion first.")
        if action in ("rename", "mkdir"):
            name = filename(name)
        if action in ("download", "trash"):
            paths = [
                p
                for p in paths
                if not any(
                    p != parent and str(p).startswith(str(parent).rstrip("/") + "/")
                    for parent in paths
                )
            ]
        try:
            if source == "backup":
                if action != "download":
                    raise ValueError(
                        "Backup snapshots are read-only. Export files to change copies."
                    )
                ids = self._backup_ids(backup, paths)
                return self.store.extract(backup, ids, localPath, job)
            if source == "device":
                return asyncio.run(
                    asyncio.wait_for(
                        self._device_operation(
                            action, udid, virtual_path(path), paths, name, localPath, job
                        ),
                        3600,
                    )
                )
            if source in ("local", "icloud"):
                return self._local_operation(
                    action,
                    self.local_root(root, source),
                    virtual_path(path),
                    paths,
                    name,
                    localPath,
                    job,
                )
            raise ValueError("Choose a file source.")
        finally:
            self.invalidate()

    def _backup_ids(self, backup, paths):
        if not paths:
            raise ValueError("Select files or folders to export.")
        ids = []
        with self.store.connection(backup) as db:
            for path in paths:
                parts = virtual_path(path).strip("/").split("/")
                domain = parts[0]
                relative = "/".join(parts[1:])
                if relative:
                    ids.extend(
                        r[0]
                        for r in db.execute(
                            "SELECT fileID FROM Files WHERE flags=1 AND domain=? AND (relativePath=? OR (relativePath>=? AND relativePath<?)) LIMIT 10001",
                            (domain, relative, relative + "/", relative + "/\uffff"),
                        )
                    )
                else:
                    ids.extend(
                        r[0]
                        for r in db.execute(
                            "SELECT fileID FROM Files WHERE flags=1 AND domain=? LIMIT 10001",
                            (domain,),
                        )
                    )
        ids = list(dict.fromkeys(ids))
        if len(ids) > 10000:
            raise ValueError("Export at most 10,000 files at a time. Select a smaller folder.")
        if not ids:
            raise ValueError("No files in this selection can be exported.")
        return ids

    def _preview_source(self, source, path, udid, backup, root):
        record = {
            "sourceType": source,
            "path": path,
            "name": posixpath.basename(path),
            "udid": udid,
            "root": root,
        }
        if source == "backup":
            parts = path.strip("/").split("/")
            if len(parts) < 2:
                raise ValueError("Select a file inside a backup domain.")
            with self.store.connection(backup) as db:
                match = db.execute(
                    "SELECT fileID FROM Files WHERE flags=1 AND domain=? AND relativePath=? LIMIT 2",
                    (parts[0], "/".join(parts[1:])),
                ).fetchall()
            if len(match) != 1:
                raise ValueError("Select a single regular backup file to preview.")
            entry = self.store.entries(backup, [match[0][0]])[0]
            fid = entry["fileID"]
            if not re.fullmatch(r"[a-fA-F0-9]{40}", fid):
                raise ValueError("Invalid backup file identifier.")
            base = self.store.path(backup)
            blob = base / fid[:2] / fid
            if not blob.exists():
                blob = base / fid
            if blob.is_symlink() or not blob.resolve().is_relative_to(base) or not blob.is_file():
                raise ValueError("The preview source is missing or outside its backup.")
            info = blob.stat()
            meta = archive_metadata(entry.get("file"))
            size = info.st_size
            key = None
            with self.store.guard:
                session = self.store.unlocked.get(str(base))
            if session:
                if not meta.get("EncryptionKey"):
                    raise ValueError("This backup file has no encryption key.")
                key = session[0].unwrap(meta["EncryptionKey"])
                size = meta.get("Size")
                if not isinstance(size, int) or not 0 <= size <= info.st_size or info.st_size % 16:
                    raise ValueError("This encrypted file has invalid size metadata.")
            record.update(
                source=blob,
                backup=str(base),
                key=key,
                size=size,
                scope="backup:" + str(base),
                fingerprint=f"{fid}:{info.st_size}:{info.st_mtime_ns}:{size}",
            )
        elif source in ("local", "icloud"):
            target = checked_local(self.local_root(root, source), path, False)
            if not target.is_file():
                raise ValueError("Select a regular file to preview.")
            info = target.stat()
            record.update(
                source=target,
                size=info.st_size,
                scope="files:" + str(root),
                fingerprint=f"{path}:{info.st_size}:{info.st_mtime_ns}",
                mtime=info.st_mtime_ns,
            )
        elif source == "device":
            device.validate_udid(udid)

            async def metadata(afc):
                await self._safe_afc(afc, path)
                info = await afc.stat(path)
                if info.get("st_ifmt") != "S_IFREG":
                    raise ValueError("Select a regular iPhone file to preview.")
                return info

            info = asyncio.run(asyncio.wait_for(self._with_afc(udid, metadata), 60))
            size = int(info.get("st_size", 0))
            record.update(
                size=size,
                scope="device:" + udid,
                fingerprint=f'{path}:{size}:{info.get("st_mtime","")}',
                mtime=str(info.get("st_mtime", "")),
            )
        else:
            raise ValueError("Choose a file source.")
        if record["size"] < 0 or record["size"] > 10 * 1024**3:
            raise ValueError("The file is too large for the 10 GB streaming preview limit.")
        return record

    def _authorize_preview(self, record):
        if record["sourceType"] == "backup":
            with self.store.connection(record["backup"]):
                pass
        elif record["sourceType"] in ("local", "icloud"):
            target = checked_local(
                self.local_root(record["root"], record["sourceType"]), record["path"], False
            )
            info = target.stat()
            if (
                info.st_size != record.get("sourceSize", record["size"])
                or info.st_mtime_ns != record["mtime"]
            ):
                raise ValueError("This source file changed. Open its preview again.")
        else:
            device.validate_udid(record["udid"])

    def _device_range(self, record, offset, length):
        async def read(afc):
            await self._safe_afc(afc, record["path"])
            info = await afc.stat(record["path"])
            if (
                info.get("st_ifmt") != "S_IFREG"
                or int(info.get("st_size", 0)) != record["sourceSize"]
                or str(info.get("st_mtime", "")) != record["mtime"]
            ):
                raise ValueError("This iPhone file changed. Open its preview again.")
            handle = await afc.fopen(record["path"], "r")
            try:
                await afc.fseek(handle, offset)
                remaining = length
                output = bytearray()
                while remaining:
                    part = await afc.fread(handle, min(CHUNK, remaining))
                    if not part:
                        raise ValueError("This iPhone file transfer was incomplete.")
                    if len(part) > remaining:
                        raise ValueError("The iPhone returned an invalid preview range.")
                    output.extend(part)
                    remaining -= len(part)
                return bytes(output)
            finally:
                await afc.fclose(handle)

        return asyncio.run(asyncio.wait_for(self._with_afc(record["udid"], read), 90))

    def _read_preview(self, record, offset, length):
        length = min(length, max(0, record["size"] - offset))
        if not length:
            return b""
        if record.get("cachedPath"):
            return self.preview_cache.read(record["cachedPath"], offset, length)
        if record["sourceType"] == "backup":
            from gallery import read_range

            self._authorize_preview(record)
            return read_range(record, offset, length)
        if record["sourceType"] in ("local", "icloud"):
            self._authorize_preview(record)
            with record["source"].open("rb") as handle:
                handle.seek(offset)
                data = handle.read(length)
            if len(data) != length:
                raise ValueError("This file changed while reading its preview.")
            return data
        # Eight-MB disk blocks keep repeated seeks away from the Wi-Fi service.
        start = offset // (8 * CHUNK) * (8 * CHUNK)
        count = min(8 * CHUNK, record["size"] - start)
        key = record["fingerprint"] + f":block:{start}"

        def write(path):
            path.write_bytes(self._device_range(record, start, count))

        block = self.preview_cache.put(
            record["scope"], key, write, suffix=".block", max_item_bytes=8 * CHUNK
        )
        return self.preview_cache.read(block, offset - start, min(length, count - (offset - start)))

    def _materialize_preview(self, record):
        if record["sourceType"] in ("local", "icloud"):
            return record["source"], False
        if record["sourceSize"] > MAX_PREVIEW_SOURCE_BYTES:
            raise ValueError(
                "This file is too large for the 256 MB image/document conversion limit."
            )
        if record["sourceType"] == "device":

            async def transfer(afc, destination):
                await self._safe_afc(afc, record["path"])
                info = await afc.stat(record["path"])
                if (
                    info.get("st_ifmt") != "S_IFREG"
                    or int(info.get("st_size", 0)) != record["sourceSize"]
                    or str(info.get("st_mtime", "")) != record["mtime"]
                ):
                    raise ValueError("This iPhone file changed. Open its preview again.")
                handle = await afc.fopen(record["path"], "r")
                try:
                    remaining = record["sourceSize"]
                    with destination.open("xb") as output:
                        while remaining:
                            data = await afc.fread(handle, min(CHUNK, remaining))
                            if not data or len(data) > min(CHUNK, remaining):
                                raise ValueError("The iPhone preview transfer was incomplete.")
                            output.write(data)
                            remaining -= len(data)
                finally:
                    await afc.fclose(handle)

            def write(destination):
                asyncio.run(
                    asyncio.wait_for(
                        self._with_afc(record["udid"], lambda afc: transfer(afc, destination)), 300
                    )
                )

            source = self.preview_cache.put(
                record["scope"],
                record["fingerprint"] + ":source",
                write,
                suffix=".source",
                max_item_bytes=MAX_PREVIEW_SOURCE_BYTES,
            )
            return source, True
        source = self.preview_cache.materialize(
            record["scope"],
            record["fingerprint"] + ":source",
            record["sourceSize"],
            lambda offset, length: self._read_preview(record, offset, length),
            max_item_bytes=MAX_PREVIEW_SOURCE_BYTES,
        )
        return source, True

    def preview(self, source="device", path="/", udid="", backup="", root="", **_):
        path = virtual_path(path)
        record = self._preview_source(source, path, udid, backup, root)
        record["sourceSize"] = record["size"]
        name = record["name"]
        suffix = Path(name).suffix.lower()
        kind = file_kind(name)
        mime = mimetypes.guess_type(name)[0] or "application/octet-stream"
        if suffix == ".pdf":
            kind = "pdf"
            mime = "application/pdf"
        elif kind == "video":
            mime = {".mov": "video/quicktime", ".m4v": "video/mp4"}.get(suffix, mime)
        elif kind == "audio":
            pass
        elif kind == "photo":
            if record["size"] > MAX_PREVIEW_SOURCE_BYTES:
                raise ValueError("This image is too large for the 256 MB conversion limit.")
            key = record["fingerprint"] + ":image:4096:90:v1"
            rendered = self.preview_cache.get(record["scope"], key)
            if rendered is None:
                original, temporary = self._materialize_preview(record)
                try:
                    rendered = self.preview_cache.put(
                        record["scope"],
                        key,
                        lambda destination: image_preview(
                            original, destination, source_format=suffix
                        ),
                        max_item_bytes=32 * CHUNK,
                    )
                finally:
                    if temporary:
                        self.preview_cache.remove(original)
            record.update(cachedPath=rendered, size=rendered.stat().st_size)
            kind = "image"
            mime = "image/jpeg"
        else:
            key = record["fingerprint"] + ":document:v1"
            cached = self.preview_cache.get(record["scope"], key)
            if cached is not None:
                result = json.loads(cached.read_text("utf-8"))
            elif suffix in OFFICE_SUFFIXES:
                if record["size"] > MAX_PREVIEW_SOURCE_BYTES:
                    raise ValueError(
                        "This Office document exceeds the 256 MB structured preview limit. PDFs and media can stream larger files."
                    )
                original, temporary = self._materialize_preview(record)
                try:
                    result = office_preview(original, suffix)
                except Exception as error:
                    if isinstance(error, ValueError):
                        raise
                    raise ValueError(
                        "This document’s content could not be safely read. It may be encrypted, damaged, or use an unsupported format."
                    ) from None
                finally:
                    if temporary:
                        self.preview_cache.remove(original)
            else:
                data = bytearray()
                for offset in range(0, min(record["size"], MAX_TEXT_BYTES), CHUNK):
                    data.extend(
                        self._read_preview(
                            record, offset, min(CHUNK, min(record["size"], MAX_TEXT_BYTES) - offset)
                        )
                    )
                result = (
                    rtf_preview(bytes(data), total_size=record["size"])
                    if suffix == ".rtf"
                    else text_preview(bytes(data), total_size=record["size"])
                )
            if cached is None:
                self.preview_cache.put(
                    record["scope"],
                    key,
                    lambda destination: destination.write_text(
                        json.dumps(result, ensure_ascii=False), "utf-8"
                    ),
                    suffix=".json",
                    max_item_bytes=4 * CHUNK,
                )
            self._authorize_preview(record)
            return result | {"name": name, "sourceSize": record["sourceSize"], "cacheHours": 1}
        self._authorize_preview(record)
        record.update(kind=kind, mime=mime, expires=time.monotonic() + 3600)
        token = secrets.token_urlsafe(32)
        with self.guard:
            self.tokens = {
                key: value
                for key, value in self.tokens.items()
                if value["expires"] > time.monotonic()
            }
            while len(self.tokens) >= 16:
                self.tokens.pop(next(iter(self.tokens)))
            self.tokens[token] = record
        return {key: record[key] for key in ("kind", "mime", "size", "name", "sourceSize")} | {
            "token": token,
            "rendered": kind == "image",
            "raw": suffix in RAW_SUFFIXES,
            "cacheHours": 1,
        }

    def _preview_token(self, token):
        if not isinstance(token, str) or not re.fullmatch(r"[A-Za-z0-9_-]{43}", token):
            raise ValueError("Invalid file preview token.")
        with self.guard:
            record = self.tokens.get(token)
        if record is None or record["expires"] <= time.monotonic():
            raise ValueError("This file preview expired. Open it again.")
        self._authorize_preview(record)
        record["expires"] = time.monotonic() + 3600
        return record

    def token_udid(self, token):
        record = self._preview_token(token)
        return record.get("udid", "") if record["sourceType"] == "device" else ""

    def token_backup(self, token):
        return self._preview_token(token).get("backup", "")

    def preview_info(self, token):
        record = self._preview_token(token)
        return {key: record[key] for key in ("mime", "size", "name")}

    def preview_chunk(self, token, offset=0, length=CHUNK):
        record = self._preview_token(token)
        offset = int(offset)
        length = int(length)
        if offset < 0 or not 0 <= length <= CHUNK:
            raise ValueError("Invalid file preview range.")
        data = self._read_preview(record, offset, length)
        return {
            "data": base64.b64encode(data).decode("ascii"),
            "next": offset + len(data),
            "eof": offset + len(data) >= record["size"],
        }

    def release(self, token=None):
        with self.guard:
            if token is None:
                self.tokens.clear()
            else:
                self.tokens.pop(token, None)

    def _local_operation(self, action, root, path, paths, name, localPath, job):
        if action in ("restore", "purge"):
            raise ValueError(
                "Restore PC files in Windows Recycle Bin or cloud files on iCloud.com."
            )
        if action == "mkdir":
            target = checked_local(root, posixpath.join(path, name), False)
            target.mkdir()
            return {"count": 1}
        if action == "upload":
            origin = Path(localPath)
            if not origin.is_file() or origin.is_symlink():
                raise ValueError("Choose a regular file to upload.")
            origin = origin.resolve(strict=True)
            target = checked_local(root, posixpath.join(path, filename(origin.name)), False)
            self._copy_new(origin, target, job)
            return {"count": 1, "output": str(target)}
        if not paths:
            raise ValueError("Select a file or folder first.")
        targets = [checked_local(root, p, False) for p in paths]
        if action == "rename":
            if len(targets) != 1:
                raise ValueError("Select one item to rename.")
            target = checked_local(
                root, posixpath.join(posixpath.dirname(virtual_path(paths[0])), name), False
            )
            if target.exists():
                raise ValueError("A file or folder with this name already exists.")
            targets[0].rename(target)
            return {"count": 1}
        if action == "trash":
            for target in targets:
                if job:
                    job.check()
                recycle(target)
            return {"count": len(targets), "recycled": True}
        destination = Path(localPath).resolve(strict=True)
        if not destination.is_dir():
            raise ValueError("Choose an existing destination folder.")
        for index, target in enumerate(targets):
            if job:
                job.check()
            out = safe_target(destination, safe_component(target.name))
            if target.is_dir():
                self._copy_directory_new(target, out, job)
            else:
                self._copy_new(target, out, job)
            if job:
                job.progress((index + 1) / len(targets) * 100, "Copying selected files")
        return {"count": len(targets), "output": str(destination)}

    @staticmethod
    def _copy_new(source, target, job=None):
        target = Path(target)
        stage = target.with_name(".phosphor-" + uuid.uuid4().hex + ".partial")
        if target.exists():
            raise ValueError(
                "A file with this name already exists. Choose a different destination."
            )
        try:
            with Path(source).open("rb") as src, stage.open("xb") as out:
                while chunk := src.read(1024 * 1024):
                    if job:
                        job.check()
                    out.write(chunk)
            # Windows rename never replaces an existing target.
            if target.exists():
                raise FileExistsError("A file with this name appeared in the destination.")
            if os.name == "nt":
                stage.rename(target)
            else:
                os.link(stage, target)
                stage.unlink()
        finally:
            stage.unlink(missing_ok=True)

    def _copy_directory_new(self, source, target, job=None):
        source = Path(source)
        target = Path(target)
        if target.exists():
            raise ValueError(
                "A folder with this name already exists. Choose a different destination."
            )
        if target.parent.resolve().is_relative_to(source.resolve()):
            raise ValueError("Choose a destination outside the folder being copied.")
        stage = target.with_name(".phosphor-" + uuid.uuid4().hex + ".partial")
        stage.mkdir()
        count = [0]

        def copy_folder(origin, out, depth=0):
            if depth > 64:
                raise ValueError("This folder tree is too deep to copy safely.")
            for entry in os.scandir(origin):
                if job:
                    job.check()
                count[0] += 1
                if count[0] > 20000:
                    raise ValueError(
                        "Copy at most 20,000 entries at a time. Select a smaller folder."
                    )
                relative = Path(entry.path).relative_to(source).as_posix()
                item = checked_local(source, "/" + relative, False)
                destination = safe_target(out, safe_component(entry.name))
                if item.is_dir():
                    destination.mkdir()
                    copy_folder(item, destination, depth + 1)
                else:
                    self._copy_new(item, destination, job)

        try:
            copy_folder(source, stage)
            if target.exists():
                raise FileExistsError("A folder with this name appeared in the destination.")
            stage.rename(target)
        finally:
            # Cleanup only our unique staging directory under the chosen destination.
            if stage.exists() and stage.parent.resolve() == target.parent.resolve():
                shutil.rmtree(stage)

    async def _download_afc(self, afc, remote, target, job=None, depth=0, count=None):
        count = count if count is not None else [0]
        count[0] += 1
        if depth > 64 or count[0] > 20000:
            raise ValueError("Download at most 20,000 entries at a time. Choose a smaller folder.")
        if job:
            job.check()
        await self._safe_afc(afc, remote)
        stat = await afc.stat(remote)
        target = Path(target)
        if target.exists():
            raise ValueError("This file or folder already exists in the destination.")
        stage = target.with_name(".phosphor-" + uuid.uuid4().hex + ".partial")
        if stat.get("st_ifmt") == "S_IFDIR":
            stage.mkdir()
            try:
                for name in await afc.listdir(remote):
                    if name in (".", ".."):
                        continue
                    child = virtual_path(posixpath.join(remote, name))
                    local = safe_target(stage, safe_component(name))
                    await self._download_afc(afc, child, local, job, depth + 1, count)
                if target.exists():
                    raise FileExistsError("This folder appeared in the destination.")
                stage.rename(target)
            finally:
                if stage.exists() and stage.parent.resolve() == target.parent.resolve():
                    shutil.rmtree(stage)
            return
        if stat.get("st_ifmt") != "S_IFREG":
            raise ValueError("Links and special device files cannot be downloaded.")
        handle = await afc.fopen(remote)
        try:
            with stage.open("xb") as out:
                remaining = int(stat.get("st_size", 0))
                size = remaining
                while remaining:
                    if job:
                        job.check()
                    chunk = await afc.fread(handle, min(1024 * 1024, remaining))
                    if not chunk:
                        raise ValueError(
                            "The device stopped sending this file. Retry the download."
                        )
                    out.write(chunk)
                    remaining -= len(chunk)
                    if job:
                        job.progress(
                            None,
                            "Downloading "
                            + posixpath.basename(remote)
                            + " · "
                            + str(round((size - remaining) / max(1, size) * 100))
                            + "%",
                        )
            if target.exists():
                raise FileExistsError("This file appeared in the destination.")
            if os.name == "nt":
                stage.rename(target)
            else:
                os.link(stage, target)
                stage.unlink()
        finally:
            await afc.fclose(handle)
            stage.unlink(missing_ok=True)

    async def _purge_afc(self, afc, remote, job=None, depth=0, count=None):
        if not remote.startswith(TRASH + "/"):
            raise ValueError("Only Phosphor Trash entries can be permanently removed.")
        count = count if count is not None else [0]
        count[0] += 1
        if depth > 64 or count[0] > 20000:
            raise ValueError("This trash entry is too large to remove in one operation.")
        if job:
            job.check()
        await self._safe_afc(afc, remote)
        stat = await afc.stat(remote)
        if stat.get("st_ifmt") == "S_IFDIR":
            for name in await afc.listdir(remote):
                if name not in (".", ".."):
                    await self._purge_afc(
                        afc, virtual_path(posixpath.join(remote, name)), job, depth + 1, count
                    )
        elif stat.get("st_ifmt") != "S_IFREG":
            raise ValueError("Special files in trash cannot be removed by Phosphor.")
        await afc.rm_single(remote)

    async def _device_operation(self, action, udid, path, paths, name, localPath, job):
        device.validate_udid(udid)

        async def execute(afc):
            if action == "mkdir":
                target = virtual_path(posixpath.join(path, name))
                await self._safe_afc(afc, target, True)
                if await afc.exists(target):
                    raise ValueError("This folder already exists.")
                await afc.makedirs(target)
                return {"count": 1}
            if action == "upload":
                origin = Path(localPath)
                if not origin.is_file() or origin.is_symlink():
                    raise ValueError("Choose a regular file to upload.")
                origin = origin.resolve(strict=True)
                target = virtual_path(posixpath.join(path, filename(origin.name)))
                await self._safe_afc(afc, target, True)
                if await afc.exists(target):
                    raise ValueError("A file with this name already exists on your iPhone.")
                stage = posixpath.join(path, ".phosphor-" + uuid.uuid4().hex + ".partial")
                handle = await afc.fopen(stage, "w")
                try:
                    with origin.open("rb") as src:
                        transferred = 0
                        size = origin.stat().st_size
                        while chunk := src.read(1024 * 1024):
                            if job:
                                job.check()
                            await afc.fwrite(handle, chunk)
                            transferred += len(chunk)
                            if job:
                                job.progress(
                                    transferred / max(1, size) * 100, "Uploading " + origin.name
                                )
                except BaseException:
                    await afc.fclose(handle)
                    if await afc.exists(stage):
                        await afc.rm_single(stage)
                    raise
                await afc.fclose(handle)
                if await afc.exists(target):
                    await afc.rm_single(stage)
                    raise ValueError("A file with this name appeared on your iPhone.")
                await afc.rename(stage, target)
                return {"count": 1}
            if not paths:
                raise ValueError("Select files or folders first.")
            if action in ("restore", "purge"):
                records = self._trash_records(udid)
                for token in paths:
                    if not re.fullmatch(r"[a-f0-9]{32}", str(token)) or token not in records:
                        raise ValueError("Select an item in Phosphor Trash.")
                for token in paths:
                    if job:
                        job.check()
                    item = records[token]
                    target = virtual_path(item["target"])
                    if not target.startswith(TRASH + "/"):
                        raise ValueError("Invalid trash item.")
                    await self._safe_afc(afc, target)
                    if action == "restore":
                        original = await self._safe_afc(afc, item["original"], True)
                        if await afc.exists(original):
                            raise ValueError(
                                "The original path is occupied. Rename the existing item before restoring."
                            )
                        await afc.makedirs(posixpath.dirname(original))
                        await afc.rename(target, original)
                    else:
                        await self._purge_afc(afc, target, job)
                    del records[token]
                    self._save_trash(udid, records)
                return {"count": len(paths)}
            valid = [await self._safe_afc(afc, p, action in ("rename", "trash")) for p in paths]
            if any(p == "/" for p in valid):
                raise ValueError("Select items inside a folder.")
            if action == "rename":
                if len(valid) != 1:
                    raise ValueError("Select one item to rename.")
                target = await self._safe_afc(
                    afc, posixpath.join(posixpath.dirname(valid[0]), name), True
                )
                if await afc.exists(target):
                    raise ValueError("This name is already used.")
                await afc.rename(valid[0], target)
                return {"count": 1}
            if action == "trash":
                await self._safe_afc(afc, TRASH)
                await afc.makedirs(TRASH)
                records = self._trash_records(udid)
                for original in valid:
                    if job:
                        job.check()
                    token = uuid.uuid4().hex
                    target = TRASH + "/" + token + "-" + posixpath.basename(original)
                    records[token] = {
                        "target": target,
                        "original": original,
                        "deleted": datetime.now(timezone.utc).isoformat(),
                    }
                    self._save_trash(udid, records)
                    try:
                        await afc.rename(original, target)
                    except BaseException:
                        del records[token]
                        self._save_trash(udid, records)
                        raise
                return {"count": len(valid), "recoverable": True}
            destination = Path(localPath).resolve(strict=True)
            if not destination.is_dir():
                raise ValueError("Choose an existing destination folder.")
            for index, remote in enumerate(valid):
                if job:
                    job.check()
                target = safe_target(destination, safe_component(posixpath.basename(remote)))
                await self._download_afc(afc, remote, target, job)
                if job:
                    job.progress(
                        (index + 1) / len(valid) * 100, "Downloaded " + posixpath.basename(remote)
                    )
            return {"count": len(valid), "output": str(destination)}

        return await self._with_afc(udid, execute)
