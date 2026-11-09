import json
import shutil
import threading
import asyncio
import plistlib
import time
from datetime import datetime
from types import SimpleNamespace
from unittest.mock import AsyncMock
from pathlib import Path
import pytest
import device
from test_operations import worker
from test_operations import FakeJob
from conftest import create_encrypted_fixture


@pytest.mark.parametrize(
    "value",
    [
        [
            {
                "CFBundleIdentifier": "com.example.app",
                "CFBundleName": "Example",
                "CFBundleShortVersionString": "2.1",
            }
        ],
        {"com.example.app": {"CFBundleName": "Example", "CFBundleShortVersionString": "2.1"}},
    ],
)
def test_app_response_formats(value):
    assert device.app_rows(value) == [
        {"id": "com.example.app", "name": "Example", "version": "2.1", "detail": "com.example.app"}
    ]


def test_app_fallbacks_and_missing_battery_measurements():
    assert device.app_rows(
        [None, {"CFBundleIdentifier": "com.test", "CFBundleVersion": 12}, "com.other"]
    ) == [
        {"id": "com.other", "name": "com.other", "version": "", "detail": "com.other"},
        {"id": "com.test", "name": "com.test", "version": "12", "detail": "com.test"},
    ]
    result = device.battery_readings(
        {"CurrentCapacity": 64, "CycleCount": 1342, "IsCharging": False, "MaxCapacity": 100}
    )
    assert result["charge"] == 64 and result["cycles"] == 1342 and result["charging"] is False
    assert result["maximumCapacityPercent"] is None  # MaxCapacity is not battery health.
    assert device.battery_readings(None)["charge"] is None
    assert device.battery_readings({"CurrentCapacity": 0})["charge"] == 0


@pytest.mark.parametrize("fail", [False, True])
def test_app_browse_returns_full_inventory_and_closes_session(monkeypatch, fail):
    from pymobiledevice3.services import installation_proxy

    client = SimpleNamespace(close=AsyncMock())
    monkeypatch.setattr(device.wireless, "route", lambda udid: {"address": "10.0.0.131"})
    monkeypatch.setattr(device.wireless, "connect", AsyncMock(return_value=client))
    rows = [
        {"CFBundleIdentifier": f"com.fixture.app{i}", "CFBundleName": f"App {i}"}
        for i in range(300)
    ]
    browse = AsyncMock(return_value=rows)
    if fail:
        browse.side_effect = RuntimeError("Service closed")

    class Service:
        def __init__(self, lockdown):
            assert lockdown is client

        async def __aenter__(self):
            return self

        async def __aexit__(self, *args):
            return False

        async def browse(self, **kwargs):
            return await browse(**kwargs)

    monkeypatch.setattr(installation_proxy, "InstallationProxyService", Service)
    if fail:
        with pytest.raises(RuntimeError, match="Service closed"):
            asyncio.run(device._apps("00008030-001234567890ABCD"))
    else:
        result = asyncio.run(device._apps("00008030-001234567890ABCD"))
        assert len(result) == 300
    assert browse.call_args.kwargs["options"] == {"ApplicationType": "User"}
    assert len(browse.call_args.kwargs["attributes"]) == 5
    client.close.assert_awaited_once()


def test_json_cli_rejects_partial_document(monkeypatch):
    monkeypatch.setattr(
        device,
        "run_cli",
        lambda args: '[log] ignored\n{"apps":[{"CFBundleIdentifier":"com.test"}]}',
    )
    assert device.json_cli([])["apps"][0]["CFBundleIdentifier"] == "com.test"
    monkeypatch.setattr(
        device, "run_cli", lambda args: '"apps":[{"CFBundleIdentifier":"com.test"}]}'
    )
    with pytest.raises(ValueError, match="unreadable"):
        device.json_cli([])


def test_backup_rename_preserves_apple_files(worker):
    w, backup = worker
    before = (Path(backup) / "Info.plist").read_bytes()
    w.dispatch("renameBackup", {"backup": backup, "name": "Before the update"})
    row = next(b for b in w.dispatch("backups", {}) if b["path"] == str(Path(backup).resolve()))
    assert row["name"] == "Before the update" and row["deviceName"] == "Test iPhone"
    assert (Path(backup) / "Info.plist").read_bytes() == before
    assert list(json.loads(w.SETTINGS_FILE.read_text())["backupLabels"].values()) == [
        "Before the update"
    ]


def test_delete_requires_confirmation_and_only_targets_backup(worker, monkeypatch, tmp_path):
    w, backup = worker
    photo = w.READER.read(backup, "photos")["rows"][0]["id"]
    w.READER.thumbnail(backup, photo)
    token = w.GALLERY.preview(backup, photo)["token"]
    w.FILE_BROWSER.list(source="backup", backup=backup, path="/CameraRollDomain")
    assert (
        w.READER.indexes.cache
        and w.READER.thumbnail_cache
        and token in w.GALLERY.tokens
        and w.FILE_BROWSER.cache
    )
    with pytest.raises(ValueError, match="Confirm"):
        w.dispatch("deleteBackup", {"backup": backup})

    def recycle(target):
        assert target == Path(backup).resolve() and target.is_relative_to(tmp_path.resolve())
        shutil.rmtree(target)

    monkeypatch.setattr(w.backup_management, "recycle", recycle)
    assert w.dispatch("deleteBackup", {"backup": backup, "confirmed": True})["recycled"]
    assert Path(backup).parent.exists() and not Path(backup).exists()
    assert (
        not w.READER.indexes.cache
        and not w.READER.thumbnail_cache
        and not w.GALLERY.tokens
        and not w.FILE_BROWSER.cache
    )
    with pytest.raises(ValueError):
        w.STORE.path(backup)


def test_lock_clears_cached_metadata_thumbnails_preview_keys_and_directories(worker):
    w, backup = worker
    photo = w.READER.read(backup, "photos")["rows"][0]["id"]
    w.READER.thumbnail(backup, photo)
    token = w.GALLERY.preview(backup, photo)["token"]
    w.FILE_BROWSER.list(source="backup", backup=backup, path="/CameraRollDomain")
    assert w.dispatch("lockBackup", {"backup": backup})
    assert not w.READER.indexes.cache and not w.READER.thumbnail_cache and not w.FILE_BROWSER.cache
    with pytest.raises(ValueError, match="expired"):
        w.GALLERY.preview_info(token)


def test_active_backup_cannot_be_deleted_or_locked(worker):
    w, backup = worker
    gate = threading.Event()
    result = w.start_backup_job("Fixture export", backup, lambda j: gate.wait(2))
    try:
        for method in ("deleteBackup", "lockBackup"):
            with pytest.raises(ValueError, match="in use"):
                w.dispatch(method, {"backup": backup, "confirmed": True})
    finally:
        gate.set()


def test_backup_stats_are_cached_and_locked_backups_report_physical_size(
    worker, monkeypatch, tmp_path
):
    w, backup = worker

    def no_scan(*args, **kwargs):
        raise AssertionError("Status must not initiate a heavy measurement")

    monkeypatch.setattr(w.CATALOG, "physical_size", no_scan)
    monkeypatch.setattr(w.CATALOG, "breakdown", no_scan)
    initial = w.dispatch("backupStats", {"backup": backup})
    assert initial["physical"]["bytes"] is None and initial["breakdown"] is None
    encrypted, _ = create_encrypted_fixture(tmp_path / "encrypted", "secret")
    w.STORE.discover([encrypted.parent])
    locked = w.dispatch("backupStats", {"backup": str(encrypted)})
    assert locked["physical"]["bytes"] is None and locked["breakdown"] is None
    with pytest.raises(ValueError, match="Unlock"):
        with w.STORE.connection(str(encrypted)):
            pass


def test_measure_and_lock_preserve_physical_cache_clear_logical_data(worker, tmp_path):
    w, backup = worker
    measured = w.measure_backup(FakeJob(), backup)
    assert measured["physical"]["bytes"] > 0 and measured["breakdown"]["count"] > 0
    stats = w.dispatch("backupStats", {"backup": backup})
    assert (
        stats["physical"]["bytes"] == measured["physical"]["bytes"] and stats["breakdown"]["cached"]
    )
    w.dispatch("lockBackup", {"backup": backup})
    after = w.dispatch("backupStats", {"backup": backup})
    assert after["physical"]["bytes"] == stats["physical"]["bytes"] and after["breakdown"] is None
    encrypted, _ = create_encrypted_fixture(tmp_path / "encrypted", "secret")
    w.STORE.discover([encrypted.parent])
    locked = w.measure_backup(FakeJob(), str(encrypted))
    assert (
        locked["physical"]["bytes"] > 0 and locked["requiresUnlock"] and locked["breakdown"] is None
    )


def test_completed_backup_updates_schedule_before_optional_analysis_failure(worker, monkeypatch):
    w, backup = worker
    udid = Path(backup).name
    schedule = w.dispatch("schedule", {"udid": udid, "frequency": "interval", "hours": 6})
    gate = threading.Event()
    analyzed = threading.Event()

    def analysis(job, path, logical=True, refresh=False):
        analyzed.set()
        raise ValueError("Analysis fixture failed after a completed snapshot")

    monkeypatch.setattr(w, "measure_backup", analysis)
    job = w.Job("Create device backup", [udid], lambda task: gate.wait(2) and {"output": backup})
    schedule["jobId"] = job.id
    gate.set()
    assert analyzed.wait(2)
    assert job.data["status"] == "completed" and job.data["result"]["output"] == backup
    assert "jobId" not in schedule and schedule["next"] - schedule["lastCompleted"] == 6 * 3600
    deadline = time.monotonic() + 2
    while (
        not any(
            item.data["title"] == "Measure new backup" and item.data["status"] == "failed"
            for item in w.JOBS.values()
        )
        and time.monotonic() < deadline
    ):
        time.sleep(0.01)
    assert any(
        item.data["title"] == "Measure new backup" and item.data["status"] == "failed"
        for item in w.JOBS.values()
    )
    assert schedule.get("lastError") is None and job.data["status"] == "completed"
