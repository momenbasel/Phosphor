"""Exercise the shipped executable, RPC protocol, data exports, and CLI imports."""

import argparse
import json
import os
import queue
import subprocess
import sys
import tempfile
import threading
import time
import wave
from pathlib import Path

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / "tests"))
from conftest import create_fixture, create_encrypted_fixture

parser = argparse.ArgumentParser()
parser.add_argument("--frozen", action="store_true")
parser.add_argument("--engine")
parser.add_argument("--recycle", action="store_true")
args = parser.parse_args()
command = (
    [args.engine]
    if args.engine
    else (
        [str(root / "backend-dist/phosphor-engine/phosphor-engine.exe")]
        if args.frozen
        else [sys.executable, "-u", str(root / "backend/worker.py")]
    )
)
hidden = subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0
with tempfile.TemporaryDirectory(prefix="phosphor-developer-test-") as runtime_directory:
    profile = Path(runtime_directory) / "unused-profile"
    runtime = subprocess.run(
        [*command, "--check-developer-support"],
        stdin=subprocess.DEVNULL,
        text=True,
        encoding="utf-8",
        capture_output=True,
        creationflags=hidden,
        timeout=30,
        env={
            **os.environ,
            "PHOSPHOR_ISOLATED_TEST": "1",
            "PHOSPHOR_DATA": str(profile),
            "PYTHONIOENCODING": "utf-8",
        },
    )
    assert not profile.exists(), "Developer dependency check initialized a profile."
assert runtime.returncode == 0, runtime.stdout + "\n" + runtime.stderr
support = json.loads(runtime.stdout)
assert support["status"] == "ready" and support["pyimg4Version"] == "0.8.8", support
assert support["connectsToDevice"] is False and support["changesDeviceSettings"] is False, support
assert {
    "MobileImageMounterService",
    "CryptexdService",
    "DvtProvider",
    "Screenshot",
    "CoreDeviceTunnelProxy",
    "UserspaceDialPlane",
    "RemoteServiceDiscoveryService",
    "SecureTSSRequest",
} == set(support["services"]), support
with tempfile.TemporaryDirectory(prefix="phosphor-engine-test-") as directory:
    test = Path(directory)
    backup, photo = create_fixture(test / "backups")
    encrypted, encrypted_photo = create_encrypted_fixture(test / "encrypted", "fixture password")
    original_manifest = (encrypted / "Manifest.db").read_bytes()
    proc = subprocess.Popen(
        command,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        encoding="utf-8",
        creationflags=hidden,
        env={
            **os.environ,
            "PHOSPHOR_ISOLATED_TEST": "1",
            "PHOSPHOR_DATA": str(test / "profile"),
            "PYTHONIOENCODING": "utf-8",
        },
    )
    received = queue.Queue()
    events = []

    def reader():
        for line in proc.stdout:
            try:
                received.put(json.loads(line))
            except ValueError:
                received.put({"unexpected": line})

    threading.Thread(target=reader, daemon=True).start()
    request_id = 0

    def call(method, params=None, expected_error=None):
        global request_id
        request_id += 1
        current = request_id
        proc.stdin.write(
            json.dumps({"id": current, "method": method, "params": params or {}}) + "\n"
        )
        proc.stdin.flush()
        while True:
            try:
                message = received.get(timeout=30)
            except queue.Empty:
                raise AssertionError("Engine response timeout: " + method)
            if message.get("event"):
                events.append(message)
                continue
            assert message.get("id") == current, message
            if expected_error:
                assert expected_error in message.get("error", ""), message
                return
            assert not message.get("error"), message
            return message["result"]

    def wait_job(started):
        while True:
            match = next(
                (
                    e["data"]
                    for e in reversed(events)
                    if e.get("event") == "job" and e["data"].get("id") == started["job"]
                ),
                None,
            )
            if match and match["status"] == "completed":
                return match
            if match and match["status"] in ("failed", "cancelled"):
                raise AssertionError(match)
            event = received.get(timeout=30)
            events.append(event)
            assert not event.get("error"), event

    try:
        assert call("status")["engine"]
        assert call("consoleSaved") == [] and call("logs") == []
        assert call("consoleClear") is True
        assert isinstance(call("devices"), list)
        call("addBackupRoot", {"path": str(test / "backups")})
        found = call("backups")
        assert any(b["path"] == str(backup) for b in found)
        assert call("openBackup", {"backup": str(backup)})["count"] == 11
        measured = wait_job(call("backupMeasure", {"backup": str(backup)}))["result"]
        assert measured["physical"]["bytes"] > 0 and measured["breakdown"]["count"] == 11
        assert call("backupStats", {"backup": str(backup)})["breakdown"]["cached"]
        call("renameBackup", {"backup": str(backup), "name": "Before the update"})
        assert (
            next(b for b in call("backups") if Path(b["path"]) == backup.resolve())["name"]
            == "Before the update"
        )
        schedule = call(
            "schedule",
            {"udid": backup.name, "name": "Fixture device", "frequency": "interval", "hours": 6},
        )
        assert schedule["seconds"] == 21600
        assert call("toggleSchedule", {"id": schedule["id"], "enabled": False})["enabled"] is False
        schedule = call(
            "schedule",
            {
                "udid": backup.name,
                "frequency": "weekly",
                "weekday": 0,
                "atTime": "18:30",
                "timeZone": "America/New_York",
            },
        )
        assert schedule["frequency"] == "weekly" and schedule["atTime"] == "18:30"
        call("deleteSchedule", {"id": schedule["id"]})
        assert (
            call("backupData", {"backup": str(backup), "kind": "messages", "chat": 1})["total"] == 2
        )
        assert call("thumbnail", {"backup": str(backup), "file": photo}).startswith(
            "data:image/jpeg;base64,"
        )
        assert (
            call(
                "galleryList", {"backup": str(backup), "sort": {"key": "size", "direction": "desc"}}
            )["total"]
            >= 1
        )
        call("galleryReviewSet", {"backup": str(backup), "files": [photo], "decision": "bin"})
        assert call("galleryList", {"backup": str(backup), "review": "bin"})["total"] == 1
        call("galleryReviewSet", {"backup": str(backup), "files": [photo], "decision": "reset"})
        assert call("galleryList", {"backup": str(backup), "review": "bin"})["total"] == 0
        wait_job(call("galleryScan", {"backup": str(backup), "mode": "exact", "max_items": 100}))
        assert isinstance(
            call("galleryGroups", {"backup": str(backup), "mode": "exact"})["groups"], list
        )
        assert call("fileList", {"source": "backup", "backup": str(backup), "path": "/"})["rows"]
        local = test / "local"
        local.mkdir()
        (local / "sample.txt").write_text("Preview fixture", "utf-8")
        registered = call("fileRoot", {"path": str(local)})
        assert call("fileList", {"source": "local", "root": registered["root"]})["total"] == 1
        assert (
            call(
                "filePreview",
                {"source": "local", "root": registered["root"], "path": "/sample.txt"},
            )["text"]
            == "Preview fixture"
        )
        from test_media_previews import synthetic_dng

        synthetic_dng(local / "synthetic.dng")
        original_raw = (local / "synthetic.dng").read_bytes()
        raw_preview = call(
            "filePreview", {"source": "local", "root": registered["root"], "path": "/synthetic.dng"}
        )
        assert raw_preview["kind"] == "image" and raw_preview["mime"] == "image/jpeg"
        assert call("fileMediaInfo", {"token": raw_preview["token"]})["size"] > 0
        import base64

        assert base64.b64decode(
            call("fileMediaRead", {"token": raw_preview["token"], "offset": 0, "length": 10})[
                "data"
            ]
        ).startswith(b"\xff\xd8")
        assert (local / "synthetic.dng").read_bytes() == original_raw
        import struct

        malformed_raw = bytearray(original_raw)
        struct.pack_into("<H", malformed_raw, 12, 11)
        struct.pack_into("<f", malformed_raw, 18, float("nan"))
        (local / "malformed.dng").write_bytes(malformed_raw)
        call(
            "filePreview",
            {"source": "local", "root": registered["root"], "path": "/malformed.dng"},
            expected_error="NewSubfileType",
        )
        call("fileRelease", {"token": raw_preview["token"]})
        call("fileMediaInfo", {"token": raw_preview["token"]}, expected_error="expired")
        started = call(
            "exportData",
            {
                "backup": str(backup),
                "kind": "messages",
                "format": "html",
                "destination": str(test / "messages.html"),
            },
        )
        wait_job(started)
        assert (test / "messages.html").exists()
        assert "<script>" not in (test / "messages.html").read_text("utf-8")
        wait_job(
            call(
                "convertPhotos",
                {"backup": str(backup), "ids": [photo], "destination": str(test / "jpeg")},
            )
        )
        assert (test / "jpeg/IMG_0001.jpg").is_file()
        with wave.open(str(test / "audio.wav"), "wb") as audio:
            audio.setnchannels(1)
            audio.setsampwidth(2)
            audio.setframerate(44100)
            audio.writeframes(bytes(88200))
        wait_job(
            call(
                "createRingtone",
                {"source": str(test / "audio.wav"), "destination": str(test / "tone.m4r")},
            )
        )
        assert (test / "tone.m4r").stat().st_size > 100
        call("addBackupRoot", {"path": str(test / "encrypted")})
        encrypted_path = next(
            b["path"] for b in call("backups") if Path(b["path"]) == encrypted.resolve()
        )
        call(
            "openBackup",
            {"backup": encrypted_path, "password": "wrong"},
            expected_error="Incorrect",
        )
        assert not next(b for b in call("backups") if b["path"] == encrypted_path)["unlocked"]
        assert (
            call("openBackup", {"backup": encrypted_path, "password": "fixture password"})["count"]
            == 11
        )
        assert call("backupFiles", {"backup": encrypted_path})["total"] == 11
        assert (
            call("backupData", {"backup": encrypted_path, "kind": "messages", "chat": 1})["total"]
            == 2
        )
        assert call("thumbnail", {"backup": encrypted_path, "file": encrypted_photo}).startswith(
            "data:image/jpeg;base64,"
        )
        preview = call("galleryPreview", {"backup": encrypted_path, "file": encrypted_photo})
        import base64

        chunk = call("galleryMediaRead", {"token": preview["token"], "offset": 7, "length": 83})
        plain = (backup / photo[:2] / photo).read_bytes()
        assert base64.b64decode(chunk["data"]) == plain[7:90]
        wait_job(
            call(
                "exportData",
                {
                    "backup": encrypted_path,
                    "kind": "messages",
                    "format": "html",
                    "destination": str(test / "encrypted-messages.html"),
                },
            )
        )
        assert "A memory worth keeping." in (test / "encrypted-messages.html").read_text("utf-8")
        call("lockBackup", {"backup": encrypted_path})
        call(
            "galleryMediaRead",
            {"token": preview["token"], "offset": 0, "length": 10},
            expected_error="expired",
        )
        call("backupFiles", {"backup": encrypted_path}, expected_error="encrypted")
        assert (encrypted / "Manifest.db").read_bytes() == original_manifest
        if args.recycle:
            recycle_backup, _ = create_fixture(test / "recycle")
            target = recycle_backup.resolve()
            assert target.is_relative_to(test.resolve())
            original_info = (target / "Info.plist").read_bytes()
            call("addBackupRoot", {"path": str(target.parent)})
            call("deleteBackup", {"backup": str(target)}, expected_error="Confirm")
            assert call("deleteBackup", {"backup": str(target), "confirmed": True})["recycled"]
            assert not target.exists()
            assert not any(Path(b["path"]) == target for b in call("backups"))
            import win32com.client

            shell = win32com.client.Dispatch("Shell.Application")
            matches = [
                item
                for item in shell.NameSpace(10).Items()
                if item.Name == target.name
                and Path(item.ExtendedProperty("System.Recycle.DeletedFrom")).resolve()
                == target.parent
            ]
            assert len(matches) == 1, "Synthetic backup was not found in the Recycle Bin."
            matches[0].InvokeVerb("undelete")
            for _ in range(30):
                if (target / "Info.plist").exists():
                    break
                time.sleep(0.1)
            assert (target / "Info.plist").read_bytes() == original_info
            assert any(Path(b["path"]) == target and b["complete"] for b in call("backups"))
    finally:
        proc.stdin.close()
        try:
            proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait()
        stderr = proc.stderr.read()
        assert proc.returncode == 0, stderr
    for group in [
        ["usbmux", "list"],
        ["backup2", "backup"],
        ["backup2", "restore"],
        ["backup2", "encryption"],
        ["backup2", "change-password"],
        ["lockdown", "info"],
        ["afc", "push"],
        ["apps", "install"],
        ["diagnostics", "battery", "single"],
        ["syslog", "live"],
        ["developer", "screenshot"],
        ["mounter", "list"],
    ]:
        result = subprocess.run(
            [*command, "--cli"],
            input=json.dumps([*group, "--help"]) + "\n",
            text=True,
            encoding="utf-8",
            capture_output=True,
            creationflags=hidden,
            timeout=30,
        )
        assert result.returncode == 0, (
            " ".join(group) + "\n" + result.stderr + "\n" + result.stdout[-1000:]
        )
    print(
        "PASS: real developer support imports/metadata, executable RPC, labels/schedules, encrypted WAL browsing/export/relock, gallery review/scan/range/token revocation, scoped file browsing/preview, media conversion, and 12 device CLI entry points."
    )
