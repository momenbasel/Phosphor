"""Do not confuse WhatsApp auxiliary databases with missing chat content."""

import hashlib
import json
import plistlib
import sqlite3
from pathlib import Path

import conftest
from backup import BackupStore
from data import DataReader

DOMAIN = "AppDomainGroup-group.net.whatsapp.WhatsApp.shared"
CLOUD = "Library/Mobile Documents/57T9237FN3~net~whatsapp~WhatsApp/Accounts/private-account/backup/ChatStorage.sqlite.enc"


def add(backup, domain, path, data, size=None, flags=1):
    backup = Path(backup)
    fid = hashlib.sha1((domain + "-" + path).encode()).hexdigest()
    target = backup / fid[:2] / fid
    target.parent.mkdir(exist_ok=True)
    target.write_bytes(data)
    metadata = (
        plistlib.dumps(
            {"$objects": ["$null", {"Size": size}], "$top": {"root": plistlib.UID(1)}},
            fmt=plistlib.FMT_BINARY,
        )
        if size is not None
        else None
    )
    with sqlite3.connect(backup / "Manifest.db") as db:
        db.execute(
            "INSERT OR REPLACE INTO Files VALUES (?,?,?,?,?)", [fid, domain, path, flags, metadata]
        )


def remove_chat(backup):
    with sqlite3.connect(Path(backup) / "Manifest.db") as db:
        db.execute("DELETE FROM Files WHERE relativePath='ChatStorage.sqlite'")


def auxiliary():
    with sqlite3.connect(":memory:") as db:
        db.execute("CREATE TABLE ZWATIP (Z_PK INTEGER,ZLABEL TEXT)")
        return db.serialize()


def test_empty_cloud_placeholder_and_seven_auxiliary_databases(fixture_backup):
    store, backup, _ = fixture_backup
    remove_chat(backup)
    add(backup, "HomeDomain", CLOUD, b"", size=0)
    for index in range(7):
        add(backup, DOMAIN, f"auxiliary-{index}.sqlite", auxiliary())
    before = (Path(backup) / "Manifest.db").read_bytes()
    result = DataReader(store).read(backup, "whatsapp")
    assert result["available"] is False and result["rows"] == []
    assert result["availability"]["status"] == "cloud_only"
    details = result["availability"]["details"]
    assert details["emptyChatArchives"] == details["emptyCloudArchives"] == 1
    assert details["auxiliaryDatabases"] == 7 and details["unsupportedChatDatabases"] == 0
    assert "0 bytes" in result["message"] and "private-account" not in json.dumps(result)
    assert (Path(backup) / "Manifest.db").read_bytes() == before


def test_unknown_schema_in_actual_chat_database_still_reports_unsupported(fixture_backup):
    store, backup, _ = fixture_backup
    add(backup, DOMAIN, "ChatStorage.sqlite", auxiliary())
    result = DataReader(store).read(backup, "whatsapp")
    assert result["availability"]["status"] == "unsupported"
    assert result["availability"]["details"]["unsupportedChatDatabases"] == 1


def test_usable_chat_database_wins_over_empty_or_protected_cloud_artifacts(fixture_backup):
    store, backup, _ = fixture_backup
    add(backup, "HomeDomain", CLOUD, b"", size=0)
    result = DataReader(store).read(backup, "whatsapp")
    assert result["available"] and result["total"] == 1
    assert DataReader(store).read(backup, "whatsapp", chat=result["rows"][0]["id"])["total"] == 1


def test_other_apps_chatstorage_is_not_a_whatsapp_source(fixture_backup):
    store, backup, _ = fixture_backup
    remove_chat(backup)
    add(backup, "AppDomain-com.example.other", "ChatStorage.sqlite", conftest.make_whatsapp())
    result = DataReader(store).read(backup, "whatsapp")
    assert not result["available"] and result["availability"]["status"] == "missing"
