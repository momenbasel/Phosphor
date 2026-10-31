import hashlib
import json
import plistlib
import shutil
from datetime import datetime
from pathlib import Path

import pytest
from backup import BackupStore
from backup_catalog import BackupCatalog
from conftest import create_encrypted_fixture


class Job:
    def __init__(self, cancel_after=None):
        self.checks = 0
        self.cancel_after = cancel_after
        self.progress_events = []

    def check(self):
        self.checks += 1
        if self.cancel_after is not None and self.checks >= self.cancel_after:
            raise InterruptedError("cancelled")

    def progress(self, *args):
        self.progress_events.append(args)


def test_physical_size_is_explicit_cached_and_persisted(fixture_backup, tmp_path):
    store, backup, _ = fixture_backup
    catalog = BackupCatalog(store, tmp_path / "catalog")
    assert catalog.cached_size(backup)["status"] == "unmeasured"
    expected = sum(path.stat().st_size for path in Path(backup).rglob("*") if path.is_file())
    result = catalog.physical_size(backup)
    assert result["bytes"] == expected and result["status"] == "complete" and result["files"] > 10
    cached = catalog.physical_size(backup)
    assert cached["cached"] is True and cached["checkedAt"] == result["checkedAt"]
    assert BackupCatalog(store, tmp_path / "catalog").cached_size(backup)["bytes"] == expected
    with (Path(backup) / "Info.plist").open("ab") as out:
        out.write(b" ")
    assert catalog.cached_size(backup)["status"] == "unmeasured"


def test_cancelled_physical_scan_does_not_publish_a_partial_measurement(fixture_backup, tmp_path):
    store, backup, _ = fixture_backup
    catalog = BackupCatalog(store, tmp_path / "catalog")
    with pytest.raises(InterruptedError):
        catalog.physical_size(backup, Job(cancel_after=2))
    assert catalog.cached_size(backup)["status"] == "unmeasured"
    assert not catalog.cache_file.exists()


def test_logical_sizes_unknown_counts_and_locked_manifest_requirement(tmp_path):
    backup, _ = create_encrypted_fixture(tmp_path, "secret")
    store = BackupStore()
    store.discover([tmp_path])
    catalog = BackupCatalog(store, tmp_path / "catalog")
    physical = catalog.physical_size(str(backup))
    assert physical["bytes"] > 0
    with pytest.raises(ValueError, match="encrypted"):
        catalog.breakdown(str(backup))
    store.open(str(backup), "secret")
    assert catalog.cached_breakdown(str(backup)) is None
    result = catalog.breakdown(str(backup))
    assert result["count"] == 11 and result["bytes"] > 0 and result["unknownCount"] == 0
    assert sum(row["bytes"] for row in result["domains"]) == result["bytes"]
    assert sum(row["bytes"] for row in result["categories"]) == result["bytes"]
    assert {row["id"] for row in result["categories"]} >= {"photos", "messages", "whatsapp"}
    assert result["whatsapp"]["status"] == "database-present"
    assert catalog.breakdown(str(backup))["cached"] is True
    assert catalog.cached_breakdown(str(backup))["cached"] is True
    catalog.clear_logical(str(backup))
    store.lock(str(backup))
    assert catalog.cached_size(str(backup))["bytes"] == physical["bytes"]
    with pytest.raises(ValueError, match="encrypted"):
        catalog.breakdown(str(backup))


def test_whatsapp_inventory_is_factual_even_with_related_files_but_no_database(
    fixture_backup, tmp_path
):
    import sqlite3

    store, backup, _ = fixture_backup
    with sqlite3.connect(Path(backup) / "Manifest.db") as db:
        db.execute("DELETE FROM Files WHERE relativePath='ChatStorage.sqlite'")
        db.execute(
            "INSERT INTO Files VALUES (?,?,?,?,?)",
            (
                hashlib.sha1(b"wa").hexdigest(),
                "AppDomain-net.whatsapp.WhatsApp",
                "Library/Preferences/settings.plist",
                1,
                None,
            ),
        )
    result = BackupCatalog(store, tmp_path / "catalog").breakdown(backup)
    assert result["unknownCount"] > 0
    assert result["whatsapp"]["status"] == "files-present-no-database"
    assert "iCloud" not in result["whatsapp"]["message"]
