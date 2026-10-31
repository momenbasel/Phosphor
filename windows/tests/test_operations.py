import importlib
import io
import json
import shutil
import tarfile
import threading
import time
from pathlib import Path
import pytest


class FakeJob:
    id = "test-operation"
    cancelled = False

    def __init__(self):
        self.keys = []

    def check(self):
        if self.cancelled:
            raise InterruptedError("cancelled")

    def progress(self, *args):
        self.check()


@pytest.fixture
def worker(tmp_path, monkeypatch, fixture_backup):
    monkeypatch.setenv("PHOSPHOR_DATA", str(tmp_path / "profile"))
    import worker

    worker = importlib.reload(worker)
    store, backup, photo = fixture_backup
    worker.STORE = store
    worker.READER = worker.DataReader(store)
    worker.GALLERY = worker.Gallery(store, worker.READER, tmp_path / "profile")
    worker.FILE_BROWSER = worker.FileBrowser(store, tmp_path / "profile")
    worker.CATALOG = worker.BackupCatalog(store, tmp_path / "profile")
    worker.CONSOLE = worker.ConsoleStore(tmp_path / "profile")
    worker.SETTINGS = {
        "backupRoot": str(tmp_path / "destination"),
        "roots": [str(Path(backup).parent)],
        "schedules": [],
    }
    worker.emit = lambda msg: None
    yield worker, backup
    worker.READER.clear_cache()
    worker.GALLERY.release()
    worker.FILE_BROWSER.invalidate()
    worker.CATALOG.clear_logical()
    for path in list(store.unlocked):
        store.lock(path)


def test_archive_roundtrip_and_preserve_collision(worker, tmp_path):
    w, backup = worker
    archive = tmp_path / "backup.phosphor"
    archive.write_bytes(b"existing export")
    result = w.archive(FakeJob(), backup, archive)
    assert archive.read_bytes() == b"existing export"
    imported = w.import_archive(FakeJob(), result["output"])
    assert list(Path(imported["output"]).glob("*/Manifest.db"))
    assert any(x["name"] == "Test iPhone" for x in w.STORE.discover(w.roots()))


@pytest.mark.parametrize("name", ["../escape", "C:/escape", "device/CON.txt", "device/test:ads"])
def test_archive_rejects_windows_unsafe_names(worker, tmp_path, name):
    w, backup = worker
    archive = tmp_path / "hostile.phosphor"
    with tarfile.open(archive, "w:gz") as tar:
        item = tarfile.TarInfo(name)
        item.size = 3
        tar.addfile(item, io.BytesIO(b"bad"))
    with pytest.raises(ValueError):
        w.import_archive(FakeJob(), archive)
    assert not list((tmp_path / "destination").glob("imports/*"))


def test_archive_rejects_links(worker, tmp_path):
    w, backup = worker
    archive = tmp_path / "link.phosphor"
    with tarfile.open(archive, "w:gz") as tar:
        item = tarfile.TarInfo("device/link")
        item.type = tarfile.SYMTYPE
        item.linkname = "../outside"
        tar.addfile(item)
    with pytest.raises(ValueError):
        w.import_archive(FakeJob(), archive)


def test_backup_snapshot_publish_and_restore_routing(worker, monkeypatch):
    w, backup = worker
    udid = Path(backup).name
    captured = []

    def device_backup(args, job, timeout):
        captured.append(args)
        if args[1] == "backup":
            stage = Path(args[4])
            shutil.copytree(backup, stage / udid, dirs_exist_ok=True)
        return ""

    monkeypatch.setattr(w.device, "run_cli", device_backup)
    result = w.make_backup(FakeJob(), udid)
    output = Path(result["output"])
    assert "snapshots" in output.parts
    assert output.joinpath("Manifest.db").is_file()
    w.restore(FakeJob(), str(output), udid, "session-secret")
    args = captured[-1]
    assert args[args.index("--source") + 1] == udid
    assert "--copy" in args
    assert Path(backup).joinpath("Manifest.db").is_file()


def test_per_device_job_lock_and_cancellation(worker):
    w, backup = worker
    gate = threading.Event()
    first = w.Job("First", ["device"], lambda j: gate.wait(5))
    with pytest.raises(ValueError, match="Another operation"):
        w.Job("Second", ["device"], lambda j: None)
    first.cancel()
    gate.set()
    for _ in range(100):
        if first.data["status"] != "running":
            break
        time.sleep(0.01)
    assert first.data["status"] == "cancelled"
    assert "device" not in w.BUSY


def test_schedule_persists_one_entry_per_device(worker):
    w, backup = worker
    udid = Path(backup).name
    w.dispatch("schedule", {"udid": udid, "frequency": "daily"})
    w.dispatch("schedule", {"udid": udid, "frequency": "weekly"})
    assert len(w.SETTINGS["schedules"]) == 1
    assert json.loads(w.SETTINGS_FILE.read_text("utf-8"))["schedules"][0]["frequency"] == "weekly"
    w.dispatch("deleteSchedule", {"id": w.SETTINGS["schedules"][0]["id"]})
    assert w.SETTINGS["schedules"] == []


@pytest.mark.parametrize(
    "method", ["deviceInfo", "files", "apps", "diagnostics", "pair", "encryption"]
)
def test_live_reads_are_blocked_during_backup(worker, method):
    w, backup = worker
    udid = Path(backup).name
    w.BUSY.add(udid)
    with pytest.raises(ValueError, match="operation is in progress"):
        w.dispatch(method, {"udid": udid})


def test_authorization_progress_preserves_percentage(worker):
    w, backup = worker
    gate = threading.Event()
    job = w.Job("Backup", ["device"], lambda j: gate.wait(2))
    job.progress(17, "Transferring")
    job.progress(None, "Waiting for authorization")
    assert job.data["percent"] == 17
    assert job.data["detail"] == "Waiting for authorization"
    gate.set()


def test_backup_waits_for_an_existing_discovery_session(worker, monkeypatch):
    w, backup = worker
    entered = threading.Event()
    release = threading.Event()
    started = threading.Event()

    def discover(protected):
        entered.set()
        release.wait(2)
        return []

    monkeypatch.setattr(w.device, "devices", discover)
    discovery = threading.Thread(target=lambda: w.dispatch("devices", {}))
    discovery.start()
    assert entered.wait(1)
    creation = threading.Thread(
        target=lambda: w.start_job("Backup", ["device"], lambda j: started.set())
    )
    creation.start()
    assert not started.wait(0.1)
    release.set()
    discovery.join(2)
    creation.join(2)
    assert started.wait(1)
