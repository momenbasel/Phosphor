"""JSON-lines RPC on private stdio. Never opens a web server."""

import sys

if __name__ == "__main__":
    for stream in (sys.stdout, sys.stderr, sys.stdin):
        if hasattr(stream, "reconfigure"):
            stream.reconfigure(encoding="utf-8", errors="replace")
if __name__ == "__main__" and "--check-developer-support" in sys.argv:
    import json
    from device_screenshot import check_runtime

    try:
        print(json.dumps(check_runtime()), flush=True)
    except Exception as error:
        print(
            json.dumps({"status": "failed", "error": type(error).__name__ + ": " + str(error)}),
            flush=True,
        )
        sys.exit(1)
    sys.exit(0)
if "--cli" in sys.argv:
    import json

    args = json.loads(sys.stdin.readline())
    if isinstance(args, dict):
        if args.get("transport"):
            from wireless import install_cli_route

            install_cli_route(args["transport"])
        args = args["args"]
    sys.argv = ["pymobiledevice3", *args]
    if args[:2] == ["backup2", "backup"]:
        from backup_transport import install_backup_transport

        install_backup_transport()
    from pymobiledevice3.__main__ import main

    try:
        sys.exit(main())
    except Exception as error:
        # Return a compact failure; PyInstaller must not replace it with a crash.
        import device

        print(device.diagnostic(type(error).__name__ + ": " + str(error)), flush=True)
        sys.exit(1)

import asyncio
import json
import os
import platform
import re
import shutil
import tarfile
import tempfile
import threading
import time
import uuid
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from pathlib import Path

from backup import BackupStore, load_plist, safe_component, safe_target
from data import DataReader
from gallery import Gallery
from file_browser import FileBrowser
from backup_catalog import BackupCatalog
from console_store import ConsoleStore
import device
import media
import backup_management
import backup_schedule

DATA = Path(os.environ.get("PHOSPHOR_DATA", Path.home() / "AppData" / "Roaming" / "Phosphor"))
DATA.mkdir(parents=True, exist_ok=True)
DEFAULT_ROOT = (
    Path(os.environ.get("LOCALAPPDATA", Path.home() / "AppData" / "Local")) / "Phosphor" / "Backups"
)
STORE = BackupStore()
READER = DataReader(STORE)
GALLERY = Gallery(STORE, READER, DATA)
FILE_BROWSER = FileBrowser(STORE, DATA)
CATALOG = BackupCatalog(STORE, DATA)
CONSOLE = ConsoleStore(DATA)
OUTPUT_LOCK = threading.Lock()
STATE_LOCK = threading.RLock()
DEVICE_GATE = threading.RLock()
BACKUP_GATE = threading.RLock()
JOBS = {}
BUSY = set()
STOP = threading.Event()
SETTINGS_FILE = DATA / "settings.json"
try:
    SETTINGS = json.loads(SETTINGS_FILE.read_text("utf-8"))
except (OSError, ValueError):
    SETTINGS = {"backupRoot": str(DEFAULT_ROOT), "roots": [], "schedules": []}
for key, default in {
    "roots": [],
    "schedules": [],
    "backupRoot": str(DEFAULT_ROOT),
    "wifiDevices": [],
    "backupLabels": {},
}.items():
    SETTINGS.setdefault(key, default)
device.wireless.configure(SETTINGS["wifiDevices"])


def emit(message):
    with OUTPUT_LOCK:
        print(json.dumps(message, ensure_ascii=False, default=str), flush=True)


def save_settings():
    with STATE_LOCK:
        temp = SETTINGS_FILE.with_suffix(".tmp")
        temp.write_text(json.dumps(SETTINGS, indent=2), encoding="utf-8")
        os.replace(temp, SETTINGS_FILE)


def roots():
    return list(
        dict.fromkeys(
            [
                SETTINGS["backupRoot"],
                *SETTINGS["roots"],
                str(Path.home() / "Apple" / "MobileSync" / "Backup"),
                str(
                    Path(os.environ.get("APPDATA", Path.home()))
                    / "Apple Computer"
                    / "MobileSync"
                    / "Backup"
                ),
            ]
        )
    )


class Job:
    def __init__(self, title, keys, fn):
        self.id = uuid.uuid4().hex
        self.data = {
            "id": self.id,
            "title": title,
            "status": "running",
            "percent": 0,
            "detail": "Preparing…",
            "started": datetime.now(timezone.utc).isoformat(),
        }
        self.cancelled = threading.Event()
        self.kill = None
        self.keys = keys
        self.last_emit = 0
        self.log = None
        with STATE_LOCK:
            if any(key in BUSY for key in keys):
                raise ValueError(
                    "Another operation is using this device. Wait for it to finish or cancel it first."
                )
            BUSY.update(keys)
            JOBS[self.id] = self
        emit({"event": "job", "data": self.data.copy()})
        threading.Thread(target=self.run, args=(fn,), daemon=True).start()

    def progress(self, percent, detail):
        self.check()
        with STATE_LOCK:
            self.data.update(
                percent=(
                    self.data["percent"] if percent is None else max(0, min(99, float(percent)))
                ),
                detail=detail,
            )
        if time.monotonic() - self.last_emit > 0.3:
            self.last_emit = time.monotonic()
            emit({"event": "job", "data": self.data.copy()})

    def check(self):
        if self.cancelled.is_set() or STOP.is_set():
            raise InterruptedError(
                "Operation cancelled. Incomplete data is kept separate from completed backups."
            )

    def run(self, fn):
        try:
            result = fn(self)
            self.check()
            self.data.update(status="completed", percent=100, detail="Completed", result=result)
        except InterruptedError as e:
            self.data.update(status="cancelled", detail=str(e))
        except Exception as e:
            self.data.update(status="failed", detail=device.diagnostic(e))
        finally:
            self.data["finished"] = datetime.now(timezone.utc).isoformat()
            with STATE_LOCK:
                BUSY.difference_update(self.keys)
                changed = False
                for schedule in SETTINGS["schedules"]:
                    if schedule.get("jobId") == self.id:
                        finish_scheduled_job(schedule, self, time.time())
                        changed = True
                if changed:
                    save_settings()
            emit({"event": "job", "data": self.data.copy()})

            if (
                self.data["status"] == "completed"
                and self.data["title"] == "Create device backup"
                and isinstance(self.data.get("result"), dict)
            ):
                output = self.data["result"].get("output")
                if output:
                    try:
                        start_backup_job(
                            "Measure new backup",
                            output,
                            lambda task: measure_backup(task, output, False),
                        )
                    except Exception:
                        pass  # Optional analysis cannot invalidate a completed snapshot.

    def cancel(self):
        self.cancelled.set()
        if self.kill:
            self.kill()


def start_job(title, keys, fn):
    # Let an existing discovery/read finish before acquiring the device for a job.
    with DEVICE_GATE:
        return {"job": Job(title, keys, fn).id}


def backup_key(backup):
    return "backup:" + str(STORE.path(backup))


def start_backup_job(title, backup, fn, devices=()):
    with BACKUP_GATE:
        return start_job(title, [*devices, backup_key(backup)], fn)


def reserve_backup(job, backup):
    with BACKUP_GATE, STATE_LOCK:
        key = backup_key(backup)
        if key in job.keys:
            return
        if key in BUSY:
            raise ValueError("This backup is in use. Wait for its operation to finish.")
        BUSY.add(key)
        job.keys.append(key)


def backup_rows():
    rows = STORE.discover(roots())
    for row in rows:
        row["deviceName"] = row["name"]
        row["name"] = SETTINGS.get("backupLabels", {}).get(row["path"], row["name"])
        measured = CATALOG.cached_size(row["path"])
        row.update(size=measured["bytes"], sizeStatus=measured["status"])
    return rows


def make_backup(job, udid, full=True):
    device.validate_udid(udid)
    root = Path(SETTINGS["backupRoot"]).resolve()
    stage = root / ".inprogress" / job.id
    stage.mkdir(parents=True, exist_ok=False)
    if not full:
        with BACKUP_GATE:
            prior = next(
                (b for b in STORE.discover(roots()) if b["udid"] == udid and b["complete"]), None
            )
            if prior:
                reserve_backup(job, prior["path"])
        if prior:
            job.progress(0, "Copying previous snapshot for an independent incremental backup")
            needed = sum(p.stat().st_size for p in Path(prior["path"]).rglob("*") if p.is_file())
            if shutil.disk_usage(root).free < needed + 1024**3:
                raise ValueError(
                    "Not enough free disk space to preserve an independent incremental snapshot. Free up space or choose a different backup folder."
                )

            def copy(source, destination):
                job.check()
                if not Path(source).resolve().is_relative_to(Path(prior["path"]).resolve()):
                    raise ValueError(
                        "The previous snapshot contains a file outside its backup folder."
                    )
                return shutil.copy2(source, destination)

            def validate_links(directory, names):
                for name in names:
                    p = Path(directory) / name
                    if p.is_symlink() or (hasattr(p, "is_junction") and p.is_junction()):
                        raise ValueError("The previous snapshot contains links or junctions.")
                return []

            shutil.copytree(
                prior["path"],
                stage / udid,
                copy_function=copy,
                symlinks=False,
                ignore=validate_links,
            )
    args = ["backup2", "backup", "--udid", udid, str(stage)]
    if full:
        args.append("--full")
    device.run_cli(args, job, timeout=6 * 60 * 60)
    job.check()
    output = stage / udid
    if (
        not (output / "Manifest.db").is_file()
        or load_plist(output / "Status.plist").get("SnapshotState") != "finished"
    ):
        raise ValueError(
            "The device did not produce a complete backup. Its partial data is retained in the .inprogress folder."
        )
    final = root / "snapshots" / (datetime.now().strftime("%Y-%m-%d_%H-%M-%S") + "_" + job.id[:8])
    final.parent.mkdir(parents=True, exist_ok=True)
    os.replace(stage, final)
    STORE.discover(roots())
    return {"output": str(final / udid)}


def measure_backup(job, backup, logical=True, refresh=False):
    physical = CATALOG.physical_size(backup, job, refresh)
    path = str(STORE.path(backup))
    encrypted = load_plist(Path(path) / "Manifest.plist").get("IsEncrypted", False)
    details = (
        CATALOG.breakdown(backup, job, refresh)
        if logical and (not encrypted or path in STORE.unlocked)
        else None
    )
    return {
        "backup": path,
        "physical": physical,
        "breakdown": details,
        "requiresUnlock": bool(logical and encrypted and path not in STORE.unlocked),
    }


def delete_snapshot(backup):
    path = backup_management.deletion_target(STORE, backup)
    READER.clear_cache(backup)
    GALLERY.invalidate(backup)
    FILE_BROWSER.invalidate(backup)
    CATALOG.invalidate(backup)
    STORE.lock(backup)
    backup_management.recycle(path)
    with STORE.guard:
        STORE.known.discard(str(path))
    with STATE_LOCK:
        SETTINGS.setdefault("backupLabels", {}).pop(str(path), None)
        save_settings()


def restore(job, backup, udid, password=""):
    reserve_backup(job, backup)
    path = STORE.path(backup)
    state = load_plist(path / "Status.plist")
    if state.get("SnapshotState") != "finished":
        raise ValueError("Only a completed backup can be restored.")
    if load_plist(path / "Manifest.plist").get("IsEncrypted") and not password:
        raise ValueError("This backup is encrypted. Enter its backup password before restoring.")
    device.validate_udid(udid)
    args = [
        "backup2",
        "restore",
        "--udid",
        udid,
        "--source",
        path.name,
        str(path.parent),
        "--system",
        "--settings",
        "--copy",
    ]
    if password:
        args.extend(["--password", password])
    device.run_cli(args, job, timeout=6 * 60 * 60)
    return {"device": udid}


def archive(job, backup, destination):
    path = STORE.path(backup)
    destination = Path(destination).resolve()
    if destination.is_relative_to(path):
        raise ValueError("Save the archive outside the backup directory.")
    temp = destination.with_name(destination.name + "." + job.id + ".partial")
    try:
        entries = list(path.rglob("*"))
        with tarfile.open(temp, "w:gz", compresslevel=3) as tar:
            for index, entry in enumerate(entries):
                job.check()
                if entry.is_symlink() or (hasattr(entry, "is_junction") and entry.is_junction()):
                    raise ValueError(
                        "The backup contains a link or junction; archive creation was stopped."
                    )
                tar.add(
                    entry,
                    arcname=path.name + "/" + entry.relative_to(path).as_posix(),
                    recursive=False,
                )
                job.progress(
                    index / max(1, len(entries)) * 100, "Packing a portable .phosphor archive"
                )
        # Windows rename refuses an existing destination; preserve it on collision.
        n = 1
        candidate = destination
        while candidate.exists():
            n += 1
            candidate = destination.with_name(f"{destination.stem} ({n}){destination.suffix}")
        os.rename(temp, candidate)
        return {"output": str(candidate)}
    finally:
        temp.unlink(missing_ok=True)


def import_archive(job, source):
    root = Path(SETTINGS["backupRoot"]).resolve()
    root.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="import-", dir=root) as directory:
        staging = Path(directory)
        with tarfile.open(source, "r:gz") as tar:
            members = tar.getmembers()
            if len(members) > 2_000_000:
                raise ValueError("Archive contains too many entries.")
            total_size = 0
            seen = set()
            for member in members:
                name = member.name
                while name.startswith("./"):
                    name = name[2:]
                name = name.rstrip("/")
                target = safe_target(staging, name)
                if not (member.isfile() or member.isdir()):
                    raise ValueError(
                        "Archives containing links or special files cannot be imported."
                    )
                if any(safe_component(p) != p for p in name.split("/")):
                    raise ValueError(
                        "The archive contains a filename that Windows cannot safely store."
                    )
                normalized = str(target).casefold()
                if normalized in seen:
                    raise ValueError("Archive contains duplicate or case-colliding paths.")
                seen.add(normalized)
                total_size += member.size
            if total_size + 1024**3 > shutil.disk_usage(root).free:
                raise ValueError("There is not enough free space to import this archive.")
            for index, member in enumerate(members):
                job.check()
                name = member.name
                while name.startswith("./"):
                    name = name[2:]
                target = safe_target(staging, name.rstrip("/"))
                if member.isdir():
                    target.mkdir(parents=True, exist_ok=True)
                else:
                    target.parent.mkdir(parents=True, exist_ok=True)
                    with tar.extractfile(member) as src, target.open("xb") as dst:
                        while chunk := src.read(1024 * 1024):
                            job.check()
                            dst.write(chunk)
                job.progress(index / max(1, len(members)) * 100, "Validating and importing archive")
        found = list(staging.glob("*/Info.plist"))
        if not found or any(not (p.parent / "Manifest.db").is_file() for p in found):
            raise ValueError("This is not a valid Phosphor backup archive.")
        final = root / "imports" / job.id
        final.parent.mkdir(parents=True, exist_ok=True)
        os.rename(staging, final)
        # TemporaryDirectory cleanup tolerates its directory being moved.
    STORE.discover(roots())
    return {"output": str(final)}


LIVE_READS = {
    "screenshotCapabilities",
    "deviceInfo",
    "pair",
    "encryption",
    "deviceAction",
    "diagnostics",
    "apps",
    "files",
    "connectWifi",
}
BACKUP_READS = {
    "openBackup",
    "lockBackup",
    "backupFiles",
    "backupData",
    "thumbnail",
    "renameBackup",
    "deleteBackup",
    "galleryList",
    "galleryReviewState",
    "galleryReviewSet",
    "galleryPreview",
    "galleryMediaInfo",
    "galleryMediaRead",
    "galleryGroups",
    "galleryRelease",
    "backupStats",
}


def dispatch(method, p):
    if method in ("fileMediaInfo", "fileMediaRead", "fileRelease"):
        with BACKUP_GATE:
            udid = FILE_BROWSER.token_udid(p["token"]) if method != "fileRelease" else ""
            if udid:
                with DEVICE_GATE:
                    with STATE_LOCK:
                        if udid in BUSY:
                            raise ValueError(
                                "A device operation is running. Wait for it to finish before streaming live files."
                            )
                    return dispatch_unlocked(method, p)
            return dispatch_unlocked(method, p)
    if method in ("fileList", "filePreview"):
        if p.get("source", "device") == "device":
            with DEVICE_GATE:
                if p.get("udid") in BUSY:
                    raise ValueError(
                        "A device operation is running. Wait for it to finish before browsing live files."
                    )
                return dispatch_unlocked(method, p)
        if p.get("source") == "backup":
            with BACKUP_GATE:
                return dispatch_unlocked(method, p)
    if method in BACKUP_READS:
        with BACKUP_GATE:
            if method in ("lockBackup", "deleteBackup") and backup_key(p["backup"]) in BUSY:
                raise ValueError(
                    "This backup is in use. Wait for its operation to finish before locking or deleting it."
                )
            return dispatch_unlocked(method, p)
    if method == "devices" or method in LIVE_READS:
        with DEVICE_GATE:
            with STATE_LOCK:
                if method in LIVE_READS and (
                    (p.get("udid") in BUSY) or (method == "connectWifi" and BUSY)
                ):
                    raise ValueError(
                        "A device operation is in progress. Wait for it to finish before opening another live device connection."
                    )
            return dispatch_unlocked(method, p)
    return dispatch_unlocked(method, p)


def dispatch_unlocked(method, p):
    if method == "status":
        return {
            "platform": platform.platform(),
            "engine": True,
            "driver": device.driver_ready(),
            "backupRoot": SETTINGS["backupRoot"],
            "roots": roots(),
            "wifiDevices": SETTINGS.get("wifiDevices", []),
            "schedules": SETTINGS["schedules"],
            "jobs": [j.data.copy() for j in list(JOBS.values())[-100:]],
        }
    if method == "devices":
        if os.environ.get("PHOSPHOR_ISOLATED_TEST") == "1":
            return []
        with STATE_LOCK:
            protected = {k for k in BUSY if re.fullmatch(r"[A-Fa-f0-9-]{12,80}", k)}
        return device.devices(protected)
    if method == "connectWifi":
        row = asyncio.run(asyncio.wait_for(device.wireless.attach(p["address"]), 45))
        with STATE_LOCK:
            SETTINGS["wifiDevices"] = [
                r for r in SETTINGS.get("wifiDevices", []) if r["id"] != row["id"]
            ] + [row]
            save_settings()
        return row
    if method == "forgetWifi":
        with STATE_LOCK:
            if p["udid"] in BUSY:
                raise ValueError("Wait for this device’s current operation to finish.")
            SETTINGS["wifiDevices"] = [
                r for r in SETTINGS.get("wifiDevices", []) if r["id"] != p["udid"]
            ]
            device.wireless.configure(SETTINGS["wifiDevices"])
            save_settings()
        return True
    if method == "backups":
        return backup_rows()
    if method == "renameBackup":
        path = str(STORE.path(p["backup"]))
        name = backup_management.label(p["name"])
        with STATE_LOCK:
            SETTINGS.setdefault("backupLabels", {})[path] = name
            save_settings()
        return {"name": name}
    if method == "deleteBackup":
        if not p.get("confirmed"):
            raise ValueError("Confirm backup deletion first.")
        delete_snapshot(p["backup"])
        return {"deleted": True, "recycled": True}
    if method == "backupStats":
        return {
            "physical": CATALOG.cached_size(p["backup"]),
            "breakdown": CATALOG.cached_breakdown(p["backup"]),
        }
    if method == "backupMeasure":
        return start_backup_job(
            "Analyze backup storage",
            p["backup"],
            lambda j: measure_backup(
                j, p["backup"], p.get("logical", True), p.get("refresh", False)
            ),
        )
    if method in ("setBackupRoot", "addBackupRoot"):
        path = Path(p["path"]).resolve()
        if method == "setBackupRoot":
            path.mkdir(parents=True, exist_ok=True)
            SETTINGS["backupRoot"] = str(path)
        elif str(path) not in SETTINGS["roots"]:
            SETTINGS["roots"].append(str(path))
        save_settings()
        return STORE.discover(roots())
    if method == "openBackup":
        before = set(STORE.unlocked)
        path = str(STORE.path(p["backup"]))
        if (
            path not in before
            and len(before) >= 2
            and any(backup_key(value) in BUSY for value in before)
        ):
            raise ValueError(
                "Finish the active backup operation before unlocking another encrypted snapshot."
            )
        result = STORE.open(p["backup"], p.get("password"))
        for evicted in before - set(STORE.unlocked):
            READER.clear_cache(evicted)
            GALLERY.invalidate(evicted)
            FILE_BROWSER.invalidate(evicted)
            CATALOG.clear_logical(evicted)
        return result
    if method == "lockBackup":
        READER.clear_cache(p["backup"])
        GALLERY.invalidate(p["backup"])
        FILE_BROWSER.invalidate(p["backup"])
        CATALOG.clear_logical(p["backup"])
        STORE.lock(p["backup"])
        return True
    if method == "galleryList":
        return GALLERY.list(**p)
    if method == "galleryReviewState":
        return GALLERY.review_state(**p)
    if method == "galleryReviewSet":
        return GALLERY.review_set(**p)
    if method == "galleryPreview":
        return GALLERY.preview(**p)
    if method == "galleryMediaInfo":
        return GALLERY.preview_info(**p)
    if method == "galleryMediaRead":
        return GALLERY.preview_chunk(**p)
    if method == "galleryRelease":
        return GALLERY.release(**p)
    if method == "galleryGroups":
        return GALLERY.groups(**p)
    if method == "galleryScan":
        return start_backup_job(
            "Find " + ("similar photos" if p.get("mode") == "similar" else "duplicate media"),
            p["backup"],
            lambda j: GALLERY.scan_duplicates(job=j, **p),
        )
    if method == "fileSources":
        return FILE_BROWSER.sources()
    if method == "fileRoot":
        return FILE_BROWSER.register_local(**p)
    if method == "fileList":
        return FILE_BROWSER.list(**p)
    if method == "filePreview":
        return FILE_BROWSER.preview(**p)
    if method == "fileMediaInfo":
        return FILE_BROWSER.preview_info(**p)
    if method == "fileMediaRead":
        return FILE_BROWSER.preview_chunk(**p)
    if method == "fileRelease":
        return FILE_BROWSER.release(**p)
    if method == "screenshotCapabilities":
        return device.screenshot_capabilities(device.validate_udid(p["udid"]))
    if method == "fileOperation":
        title = {
            "rename": "Rename file",
            "mkdir": "Create folder",
            "upload": "Upload file",
            "download": "Download files",
            "trash": "Move files to trash",
            "restore": "Restore files from trash",
            "purge": "Delete trash permanently",
        }.get(p.get("action"), "File operation")
        if p.get("source") == "backup":
            return start_backup_job(
                title, p["backup"], lambda j: FILE_BROWSER.operation(job=j, **p)
            )
        keys = (
            [device.validate_udid(p["udid"])]
            if p.get("source", "device") == "device"
            else ["files:" + str(p.get("root", ""))]
        )
        return start_job(title, keys, lambda j: FILE_BROWSER.operation(job=j, **p))
    if method == "backupFiles":
        return STORE.files(**p)
    if method == "backupData":
        return READER.read(**p)
    if method == "thumbnail":
        return GALLERY.thumbnail(**p)
    if method == "convertPhotos":
        return start_backup_job(
            "Convert photos to JPEG",
            p["backup"],
            lambda j: media.convert_photos(STORE, p["backup"], p["ids"], p["destination"], j),
        )
    if method == "createRingtone":
        return start_job(
            "Create ringtone", [], lambda j: media.create_ringtone(p["source"], p["destination"], j)
        )
    if method == "extractFiles":
        return start_backup_job(
            "Extract backup files", p["backup"], lambda j: STORE.extract(**p, job=j)
        )
    if method == "exportData":
        return start_backup_job(
            "Export " + p["kind"], p["backup"], lambda j: READER.export(**p, job=j)
        )
    if method == "archive":
        return start_backup_job(
            "Export backup archive",
            p["backup"],
            lambda j: archive(j, p["backup"], p["destination"]),
        )
    if method == "importArchive":
        return start_job(
            "Import backup archive", ["import"], lambda j: import_archive(j, p["path"])
        )
    if method == "createBackup":
        udid = device.validate_udid(p["udid"])
        return start_job(
            "Create device backup", [udid], lambda j: make_backup(j, udid, p.get("full", True))
        )
    if method == "restoreBackup":
        if not p.get("confirmed"):
            raise ValueError("Confirm the restore before continuing.")
        udid = device.validate_udid(p["udid"])
        return start_backup_job(
            "Restore device backup",
            p["backup"],
            lambda j: restore(j, p["backup"], udid, p.get("password", "")),
            devices=[udid],
        )
    if method == "clone":
        source = device.validate_udid(p["source"])
        target = device.validate_udid(p["target"])
        if source == target:
            raise ValueError("Choose two different devices.")
        if not p.get("confirmed"):
            raise ValueError("Confirm the destination device before cloning.")

        def clone(job):
            result = make_backup(job, source)
            job.progress(0, "Source backup saved. Restoring destination device")
            restore(job, result["output"], target, p.get("password", ""))
            return result

        return start_job("Clone device", [source, target], clone)
    if method == "deviceInfo":
        return device.json_cli(["lockdown", "info", "--udid", device.validate_udid(p["udid"])])
    if method == "pair":
        return device.run_cli(["lockdown", "pair", "--udid", device.validate_udid(p["udid"])])
    if method == "encryption":
        udid = device.validate_udid(p["udid"])
        state = device.run_cli(["backup2", "encryption", "--udid", udid]).strip()
        if state not in ("on", "off"):
            raise ValueError("The device backup encryption setting could not be read.")
        if not p.get("mode"):
            return {"encrypted": state == "on"}
        mode = p["mode"]
        if mode not in ("on", "off", "change"):
            raise ValueError("Unsupported encryption operation.")
        if not p.get("password"):
            raise ValueError("A backup password is required.")
        if mode == "change":
            if state != "on":
                raise ValueError("Enable backup encryption before changing its password.")
            if not p.get("newPassword"):
                raise ValueError("Enter the new backup password.")
            command = [
                "backup2",
                "change-password",
                "--udid",
                udid,
                p["password"],
                p["newPassword"],
            ]
        else:
            if (mode == "on") == (state == "on"):
                raise ValueError("Backup encryption is already " + mode + ".")
            command = ["backup2", "encryption", "--udid", udid, mode, p["password"]]

        def update_encryption(job):
            with tempfile.TemporaryDirectory(prefix="encryption-", dir=DATA) as folder:
                return device.run_cli(
                    [*command, "--backup-directory", folder],
                    job,
                    120,
                    secrets=[p["password"], p.get("newPassword", "")],
                )

        return start_job("Update backup encryption", [udid], update_encryption)
    if method == "deviceAction":
        if p["action"] not in ("restart", "shutdown", "sleep"):
            raise ValueError("Unsupported device action.")
        return device.run_cli(
            ["diagnostics", p["action"], "--udid", device.validate_udid(p["udid"])]
        )
    if method == "diagnostics":
        udid = device.validate_udid(p["udid"])
        result = {}
        try:
            result["battery"] = device.battery_readings(
                device.json_cli(["diagnostics", "battery", "single", "--udid", udid])
            )
        except Exception as e:
            result["battery"] = {"error": str(e)}
        try:
            result["storage"] = device.storage_info(udid)
        except Exception as e:
            result["storage"] = {"error": str(e)}
        return result
    if method == "apps":
        return device.apps(p["udid"])
    if method in ("installApp", "removeApp"):
        udid = device.validate_udid(p["udid"])
        if method == "removeApp" and not p.get("confirmed"):
            raise ValueError("Confirm app removal first.")
        args = [
            "apps",
            "install" if method == "installApp" else "uninstall",
            "--udid",
            udid,
            p["path"] if method == "installApp" else p["bundle"],
        ]
        return start_job(
            "Install app" if method == "installApp" else "Remove app",
            [udid],
            lambda j: device.run_cli(args, j, 1800),
        )
    if method == "files":
        return device.files(p["udid"], p.get("remote", "/"))
    if method in ("pushFile", "pullFile", "deleteFile"):
        udid = device.validate_udid(p["udid"])
        remote = p["remote"]
        if not remote.startswith("/") or remote == "/" or ".." in remote.split("/"):
            raise ValueError("Choose a file inside the device Media folder.")
        if method in ("pushFile", "deleteFile"):
            device.validate_media_write(remote)
        if method == "deleteFile" and not p.get("confirmed"):
            raise ValueError("Confirm deletion first.")
        if method == "pushFile":
            parent = remote.rsplit("/", 1)[0] or "/"
            if any(r["path"] == remote for r in device.files(udid, parent)["rows"]):
                raise ValueError(
                    "A file with this name already exists on the device. Rename the local file before uploading."
                )
            args = ["afc", "push", "--udid", udid, p["path"], remote]
        elif method == "pullFile":
            if Path(p["path"]).exists():
                raise ValueError(
                    "Choose a new file path; an existing export will not be overwritten."
                )
            args = ["afc", "pull", "--udid", udid, remote, p["path"]]
        else:
            args = ["afc", "rm", "--udid", udid, remote]
        return start_job(
            {
                "pushFile": "Upload file",
                "pullFile": "Download file",
                "deleteFile": "Delete device file",
            }[method],
            [udid],
            lambda j: (
                {"output": p.get("path")} if device.run_cli(args, j, 3600) is not None else {}
            ),
        )
    if method == "prepareScreenshot":
        udid = device.validate_udid(p["udid"])
        return start_job(
            "Prepare screenshots", [udid], lambda j: device.screenshot_prepare(udid, j)
        )
    if method == "screenshot":
        udid = device.validate_udid(p["udid"])
        path = p["path"]
        if Path(path).exists():
            raise ValueError("Choose a new screenshot filename.")
        return start_job(
            "Capture screenshot", [udid], lambda j: device.capture_screenshot(udid, path, j)
        )
    if method == "jobs":
        return [j.data.copy() for j in list(JOBS.values())[-100:]]
    if method == "cancelJob":
        if p["id"] in JOBS:
            JOBS[p["id"]].cancel()
        return True
    if method == "schedule":
        udid = device.validate_udid(p["udid"])
        configuration = backup_schedule.configure(p, time.time())
        with STATE_LOCK:
            existing = next((s for s in SETTINGS["schedules"] if s["udid"] == udid), None)
            if (
                existing
                and existing.get("jobId")
                and JOBS.get(existing["jobId"])
                and JOBS[existing["jobId"]].data["status"] == "running"
            ):
                raise ValueError(
                    "Wait for this scheduled backup to finish before editing its schedule."
                )
            s = {
                "id": existing["id"] if existing else uuid.uuid4().hex,
                "udid": udid,
                "name": p.get("name", "iOS device"),
                "enabled": bool(p.get("enabled", True)),
                **configuration,
            }
            SETTINGS["schedules"] = [s if x["udid"] == udid else x for x in SETTINGS["schedules"]]
            if not existing:
                SETTINGS["schedules"].append(s)
            save_settings()
        return s
    if method == "toggleSchedule":
        with STATE_LOCK:
            s = next((s for s in SETTINGS["schedules"] if s["id"] == p["id"]), None)
            if not s:
                raise ValueError("This schedule no longer exists.")
            s["enabled"] = bool(p["enabled"])
            save_settings()
        return s
    if method == "deleteSchedule":
        with STATE_LOCK:
            SETTINGS["schedules"] = [s for s in SETTINGS["schedules"] if s["id"] != p["id"]]
            save_settings()
        return True
    if method == "logs":
        return CONSOLE.read(p.get("limit", 2000))
    if method == "consoleClear":
        return CONSOLE.clear()
    if method == "consoleSave":
        return CONSOLE.save(p.get("path"))
    if method == "consoleSaved":
        return CONSOLE.list()
    if method == "consoleOpen":
        return CONSOLE.open(p["id"])
    if method == "startLogs":
        udid = device.validate_udid(p["udid"])

        def stream(job):
            def log(line):
                CONSOLE.append(line)
                emit({"event": "log", "data": line})

            job.log = log
            return device.run_cli(["syslog", "live", "--udid", udid], job, 24 * 60 * 60)

        return start_job("Device console", [udid], stream)
    if method == "stopLogs":
        for j in JOBS.values():
            if j.data["title"] == "Device console" and j.data["status"] == "running":
                j.cancel()
        return True
    raise ValueError("Unknown operation.")


def finish_scheduled_job(schedule, job, now):
    schedule.pop("jobId", None)
    if job and job.data["status"] == "completed":
        completed = (
            datetime.fromisoformat(job.data["finished"]).timestamp()
            if job.data.get("finished")
            else now
        )
        schedule["lastCompleted"] = completed
        schedule["next"] = backup_schedule.next_due(schedule, completed)
        schedule.pop("lastError", None)
        schedule.pop("retryAt", None)
    else:
        schedule["lastError"] = (
            job.data["detail"] if job else "Phosphor closed before the scheduled backup finished."
        )
        schedule["retryAt"] = now + 300


def scheduler_tick(now=None):
    now = time.time() if now is None else now
    for s in list(SETTINGS["schedules"]):
        if s.get("jobId"):
            job = JOBS.get(s["jobId"])
            if job and job.data["status"] == "running":
                continue
            with STATE_LOCK:
                finish_scheduled_job(s, job, now)
                save_settings()
        if (
            not s.get("enabled")
            or s["next"] > now
            or s.get("retryAt", 0) > now
            or s["udid"] in BUSY
        ):
            continue
        try:
            if not any(d["id"] == s["udid"] and d["paired"] for d in dispatch("devices", {})):
                continue
            with DEVICE_GATE, STATE_LOCK:
                if (
                    not s.get("enabled")
                    or not any(current is s for current in SETTINGS["schedules"])
                    or s["udid"] in BUSY
                ):
                    continue
                started = dispatch("createBackup", {"udid": s["udid"], "full": False})
                s["jobId"] = started["job"]
                s["lastStarted"] = now
                s.pop("lastError", None)
                save_settings()
        except Exception as e:
            with STATE_LOCK:
                s["lastError"] = str(e)
                s["retryAt"] = now + 300
                save_settings()


def scheduler():
    while not STOP.wait(30):
        scheduler_tick()


def handle(request):
    try:
        result = dispatch(request["method"], request.get("params", {}))
        emit({"id": request["id"], "result": result})
    except Exception as e:
        emit({"id": request.get("id"), "error": device.diagnostic(e)})


if __name__ == "__main__":
    # NumPy's Windows native import can stall in an RPC thread while the main
    # thread blocks reading stdin. Warm RAW dependencies before either starts.
    media.initialize_raw_decoder()
    if "--no-scheduler" not in sys.argv:
        threading.Thread(target=scheduler, daemon=True).start()
    pool = ThreadPoolExecutor(max_workers=4)
    try:
        for line in sys.stdin:
            try:
                request = json.loads(line)
            except ValueError:
                continue
            pool.submit(handle, request)
    finally:
        STOP.set()
        for job in list(JOBS.values()):
            job.cancel()
        pool.shutdown(wait=False, cancel_futures=True)
