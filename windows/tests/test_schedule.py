from datetime import datetime
from types import SimpleNamespace
import json
import threading
import time
from zoneinfo import ZoneInfo
import pytest
import backup_schedule
from test_operations import worker


@pytest.mark.parametrize("hours", [0, 721, True, 2.5, "6"])
def test_interval_validation(hours):
    with pytest.raises(ValueError):
        backup_schedule.configure({"frequency": "interval", "hours": hours}, 1000)


def test_calendar_times_and_dst():
    zone = ZoneInfo("America/New_York")
    now = datetime(2026, 10, 31, 10, 0, tzinfo=zone).timestamp()
    daily = backup_schedule.configure(
        {"frequency": "daily", "atTime": "10:00", "timeZone": str(zone)}, now
    )
    assert daily["next"] - now == 25 * 3600
    weekly = backup_schedule.configure(
        {"frequency": "weekly", "atTime": "18:30", "weekday": 0, "timeZone": str(zone)}, now
    )
    due = datetime.fromtimestamp(weekly["next"], zone)
    assert due.weekday() == 0 and (due.hour, due.minute) == (18, 30)
    interval = backup_schedule.configure({"frequency": "interval", "hours": 6}, now)
    assert interval["next"] - now == 6 * 3600


def test_first_run_date_time_and_completion_cadence():
    now = datetime(2026, 10, 7, 12, 0, tzinfo=ZoneInfo("America/New_York")).timestamp()
    first = "2026-10-08T09:15:00-04:00"
    schedule = backup_schedule.configure(
        {"frequency": "interval", "hours": 6, "firstAt": first}, now
    )
    assert schedule["next"] == datetime.fromisoformat(first).timestamp()
    assert (
        backup_schedule.next_due(schedule, schedule["next"] + 100) == schedule["next"] + 100 + 21600
    )
    for invalid in ["2026-10-08T09:15:00", "not a date", "2026-10-01T09:15:00-04:00"]:
        with pytest.raises(ValueError):
            backup_schedule.configure({"frequency": "monthly", "firstAt": invalid}, now)


def fake_scheduled_job(w, monkeypatch):
    original = w.dispatch
    created = []
    job = SimpleNamespace(data={"status": "running", "detail": "Waiting for authorization"})

    def dispatch(method, params):
        if method == "createBackup":
            created.append(params)
            w.JOBS["scheduled-test"] = job
            return {"job": "scheduled-test"}
        return original(method, params)

    monkeypatch.setattr(w, "dispatch", dispatch)
    return job, created


def test_offline_catchup_and_next_run_after_completion(worker, monkeypatch):
    w, backup = worker
    udid = w.STORE.path(backup).name
    s = w.dispatch("schedule", {"udid": udid, "frequency": "interval", "hours": 6})
    due = s["next"]
    connected = []
    monkeypatch.setattr(w.device, "devices", lambda protected: connected)
    job, created = fake_scheduled_job(w, monkeypatch)
    w.scheduler_tick(due + 100)
    assert not created and s["next"] == due
    connected.append({"id": udid, "paired": True})
    w.scheduler_tick(due + 101)
    assert len(created) == 1 and not created[0]["full"]
    w.scheduler_tick(due + 200)
    assert len(created) == 1 and s["next"] == due
    job.data["status"] = "completed"
    w.scheduler_tick(due + 300)
    assert s["next"] == due + 300 + 6 * 3600 and s["lastCompleted"] == due + 300
    assert "jobId" not in s


def test_failure_is_visible_and_retry_is_bounded(worker, monkeypatch):
    w, backup = worker
    udid = w.STORE.path(backup).name
    s = w.dispatch("schedule", {"udid": udid, "frequency": "daily"})
    monkeypatch.setattr(w.device, "devices", lambda protected: [{"id": udid, "paired": True}])
    job, created = fake_scheduled_job(w, monkeypatch)
    w.scheduler_tick(s["next"])
    job.data.update(status="failed", detail="Device unavailable")
    now = s["next"] + 100
    w.scheduler_tick(now)
    assert s["lastError"] == "Device unavailable" and s["retryAt"] == now + 300
    w.scheduler_tick(now + 1)
    assert len(created) == 1
    w.scheduler_tick(now + 300)
    assert len(created) == 2


def test_pause_during_discovery_prevents_backup(worker, monkeypatch):
    w, backup = worker
    udid = w.STORE.path(backup).name
    s = w.dispatch("schedule", {"udid": udid, "frequency": "weekly"})

    def devices(protected):
        w.dispatch("toggleSchedule", {"id": s["id"], "enabled": False})
        return [{"id": udid, "paired": True}]

    monkeypatch.setattr(w.device, "devices", devices)
    job, created = fake_scheduled_job(w, monkeypatch)
    w.scheduler_tick(s["next"])
    assert not created


def test_completion_immediately_persists_next_run(worker):
    w, backup = worker
    udid = w.STORE.path(backup).name
    s = w.dispatch("schedule", {"udid": udid, "frequency": "interval", "hours": 6})
    gate = threading.Event()
    job = w.Job("Scheduled fixture", [udid], lambda j: gate.wait(2))
    s["jobId"] = job.id
    gate.set()
    # The job thread clears jobId, records completion, and saves under STATE_LOCK;
    # read the persisted file only after that whole update has been written.
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        with w.STATE_LOCK:
            saved = json.loads(w.SETTINGS_FILE.read_text())["schedules"][0]
        if "lastCompleted" in saved:
            break
        time.sleep(0.01)
    assert "jobId" not in saved and saved["lastCompleted"] > 0
    assert saved["next"] - saved["lastCompleted"] == 6 * 3600
