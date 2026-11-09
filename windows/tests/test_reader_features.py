import gzip
import hashlib
import plistlib
import sqlite3
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from pathlib import Path

import pytest
import backup as backup_module
from backup import BackupStore
from conftest import create_encrypted_fixture
from data import DataReader, apple_date
from note_text import decode_note_text, MAX_NOTE_BYTES


def add_entry(backup, domain, path, data, metadata=None):
    root = Path(backup)
    fid = hashlib.sha1((domain + "-" + path).encode()).hexdigest()
    target = root / fid[:2] / fid
    target.parent.mkdir(exist_ok=True)
    target.write_bytes(data)
    blob = (
        plistlib.dumps(
            {"$objects": ["$null", metadata], "$top": {"root": plistlib.UID(1)}},
            fmt=plistlib.FMT_BINARY,
        )
        if metadata
        else None
    )
    with sqlite3.connect(root / "Manifest.db") as db:
        db.execute("INSERT OR REPLACE INTO Files VALUES (?,?,?,?,?)", (fid, domain, path, 1, blob))
    return fid


def database(script):
    db = sqlite3.connect(":memory:")
    db.executescript(script)
    data = db.serialize()
    db.close()
    return data


def varint(value):
    result = bytearray()
    while value > 127:
        result.append((value & 127) | 128)
        value >>= 7
    return bytes(result) + bytes([value])


def protobuf(field, data):
    return varint((field << 3) | 2) + varint(len(data)) + data


def note_blob(text):
    return gzip.compress(protobuf(2, protobuf(3, protobuf(2, text.encode("utf-8")))))


def test_safari_selects_schema_not_first_matching_filename(fixture_backup):
    store, backup, _ = fixture_backup
    add_entry(
        backup,
        "AppDomain-com.apple.mobilesafari",
        "History.db",
        database("CREATE TABLE unrelated (secret TEXT);"),
    )
    assert DataReader(store).read(backup, "safari")["rows"][0]["detail"] == "https://example.test"
    with sqlite3.connect(Path(backup) / "Manifest.db") as db:
        db.execute("DELETE FROM Files WHERE relativePath='Library/Safari/History.db'")
    result = DataReader(store).read(backup, "safari")
    assert result["rows"] == [] and result["availability"]["status"] == "unsupported"


def test_safari_does_not_show_other_apps_compatible_history(fixture_backup):
    store, backup, _ = fixture_backup
    with sqlite3.connect(Path(backup) / "Manifest.db") as db:
        db.execute("DELETE FROM Files WHERE relativePath='Library/Safari/History.db'")
    add_entry(
        backup,
        "AppDomain-com.example.unrelated",
        "History.db",
        database(
            "CREATE TABLE history_items(id INTEGER,url TEXT);INSERT INTO history_items VALUES(1,'https://private-other-app.test');"
        ),
    )
    result = DataReader(store).read(backup, "safari")
    assert result["rows"] == [] and result["availability"]["status"] == "missing"


def test_missing_whatsapp_is_optional_unavailable_data(fixture_backup):
    store, backup, _ = fixture_backup
    with sqlite3.connect(Path(backup) / "Manifest.db") as db:
        db.execute("DELETE FROM Files WHERE relativePath='ChatStorage.sqlite'")
    result = DataReader(store).read(backup, "whatsapp")
    assert result["available"] is False and result["total"] == 0
    assert result["availability"]["status"] == "missing"
    assert "No WhatsApp-related" in result["message"] and "iCloud" not in result["message"]
    assert "complete backup" not in result["message"]


def test_whatsapp_renamed_database_is_discovered_by_schema(fixture_backup):
    from conftest import make_whatsapp

    store, backup, _ = fixture_backup
    with sqlite3.connect(Path(backup) / "Manifest.db") as db:
        db.execute("DELETE FROM Files WHERE relativePath='ChatStorage.sqlite'")
    add_entry(
        backup,
        "AppDomainGroup-group.net.whatsapp.WhatsApp.shared",
        "Library/Persisted/conversations-v2.sqlite",
        make_whatsapp(),
    )
    add_entry(
        backup,
        "AppDomainGroup-group.net.whatsapp.WhatsApp.shared",
        "Library/Persisted/small.sqlite",
        b"not a database",
    )
    result = DataReader(store).read(backup, "whatsapp")
    assert result["available"] and result["rows"][0]["name"] == "Alex"


def test_safari_without_optional_visit_table_still_reads_urls(fixture_backup):
    store, backup, _ = fixture_backup
    add_entry(
        backup,
        "HomeDomain",
        "Library/Safari/History.db",
        database(
            "CREATE TABLE history_items (id INTEGER,url TEXT);INSERT INTO history_items VALUES(1,'https://example.test/new');"
        ),
    )
    result = DataReader(store).read(backup, "safari")
    assert result["available"] and result["rows"][0]["name"] == "https://example.test/new"
    assert result["rows"][0]["date"] == ""


def test_notes_decode_full_text_keep_snippet_and_do_not_decode_locked(fixture_backup):
    store, backup, _ = fixture_backup
    data = database(
        """CREATE TABLE ZICCLOUDSYNCINGOBJECT (Z_PK INTEGER,ZTITLE1 TEXT,ZSNIPPET TEXT,ZMODIFICATIONDATE1 REAL,ZISPASSWORDPROTECTED INTEGER);
        INSERT INTO ZICCLOUDSYNCINGOBJECT VALUES(1,'Readable','Short snippet',800000000,0),(2,'Locked','Hidden snippet',800000001,1),(3,'Unknown','Safe snippet',800000002,0);
        CREATE TABLE ZICNOTEDATA (ZNOTE INTEGER,ZDATA BLOB);"""
    )
    fid = add_entry(backup, "HomeDomain", "Library/Notes/NoteStore.sqlite", data)
    path = Path(backup) / fid[:2] / fid
    with sqlite3.connect(path) as db:
        db.executemany(
            "INSERT INTO ZICNOTEDATA VALUES (?,?)",
            [
                (1, note_blob("Full text\nSecond line 🦊")),
                (2, note_blob("Must never be decoded")),
                (3, b"not protobuf"),
            ],
        )
    rows = {r["id"]: r for r in DataReader(store).read(backup, "notes")["rows"]}
    assert rows[1]["body"] == "Full text\nSecond line 🦊" and rows[1]["bodyStatus"] == "full"
    assert rows[2]["body"] == "" and rows[2]["bodyStatus"] == "locked"
    assert rows[3]["body"] == "Safe snippet" and rows[3]["bodyStatus"] == "snippet"


def test_note_parser_does_not_guess_arbitrary_utf8_or_inflate_unbounded_data():
    assert decode_note_text(note_blob("Exact supported field")) == "Exact supported field"
    assert decode_note_text(b"some printable unrelated text") is None
    assert decode_note_text(gzip.compress(b"x" * (MAX_NOTE_BYTES + 1))) is None
    assert decode_note_text(b"\x12\x7fshort") is None


def test_call_date_duration_filters_precede_paging(fixture_backup):
    store, backup, _ = fixture_backup
    add_entry(
        backup,
        "HomeDomain",
        "Library/CallHistoryDB/CallHistory.storedata",
        database(
            """CREATE TABLE ZCALLRECORD (Z_PK INTEGER,ZADDRESS TEXT,ZDATE REAL,ZDURATION REAL,ZCALLTYPE INTEGER);
        INSERT INTO ZCALLRECORD VALUES(1,'Short',800000000,5,1),(2,'Long',800000001,120,1),(3,'Later',800100000,240,1);"""
        ),
    )
    day = apple_date(800000000)[:10]
    result = DataReader(store).read(
        backup,
        "calls",
        dateFrom=day,
        dateTo=day,
        minDuration=60,
        maxDuration=180,
        limit=1,
        sort="duration",
        order="desc",
    )
    assert result["total"] == 1 and result["rows"][0]["name"] == "Long"
    assert DataReader(store).read(backup, "calls", query="Long", minDuration=200)["total"] == 0


def test_calendar_includes_event_spanning_month_boundary(fixture_backup):
    store, backup, _ = fixture_backup
    unix = datetime(2026, 10, 1, tzinfo=timezone.utc).timestamp()
    apple = unix - 978307200
    add_entry(
        backup,
        "HomeDomain",
        "Library/Calendar/Calendar.sqlitedb",
        database(
            f"""CREATE TABLE CalendarItem(summary TEXT,start_date REAL,end_date REAL,all_day INTEGER,description TEXT,location TEXT);
        INSERT INTO CalendarItem VALUES('Spanning',{apple-3600},{apple+3600},0,'Across midnight','Studio'),('Older',{apple-90000},{apple-80000},0,'','');"""
        ),
    )
    result = DataReader(store).read(backup, "calendar", dateFrom="2026-10-01", dateTo="2026-10-31")
    assert result["total"] == 1 and result["rows"][0]["name"] == "Spanning"
    assert (
        result["rows"][0]["location"] == "Studio"
        and result["rows"][0]["start"] == result["rows"][0]["date"]
    )


def test_calendar_floating_days_and_local_instants_have_separate_boundaries(
    fixture_backup, tmp_path
):
    store, backup, _ = fixture_backup

    def apple(value):
        return datetime.fromisoformat(value).timestamp() - 978307200

    rows = [
        (
            "October all-day",
            apple("2026-10-01T00:00:00+00:00"),
            apple("2026-10-02T00:00:00+00:00"),
            1,
        ),
        (
            "November all-day",
            apple("2026-11-01T00:00:00+00:00"),
            apple("2026-11-02T00:00:00+00:00"),
            1,
        ),
        (
            "September exclusive end",
            apple("2026-09-30T00:00:00+00:00"),
            apple("2026-10-01T00:00:00+00:00"),
            1,
        ),
        (
            "Late October timed",
            apple("2026-11-01T03:00:00+00:00"),
            apple("2026-11-01T03:30:00+00:00"),
            0,
        ),
        (
            "Late September timed",
            apple("2026-10-01T03:00:00+00:00"),
            apple("2026-10-01T03:30:00+00:00"),
            0,
        ),
        ("October missing end", apple("2026-10-01T00:00:00+00:00"), None, 1),
    ]
    db = sqlite3.connect(":memory:")
    db.execute(
        "CREATE TABLE CalendarItem(summary TEXT,start_date REAL,end_date REAL,all_day INTEGER)"
    )
    db.executemany("INSERT INTO CalendarItem VALUES (?,?,?,?)", rows)
    add_entry(backup, "HomeDomain", "Library/Calendar/Calendar.sqlitedb", db.serialize())
    db.close()
    reader = DataReader(store)
    options = {
        "dateFrom": "2026-10-01T00:00:00-04:00",
        "dateTo": "2026-11-01T00:00:00-04:00",
        "filters": {"dayFrom": "2026-10-01", "dayTo": "2026-11-01"},
    }
    result = reader.read(backup, "calendar", **options)
    assert {r["name"] for r in result["rows"]} == {
        "October all-day",
        "Late October timed",
        "October missing end",
    }
    exported = reader.export(backup, "calendar", tmp_path / "october.ics", "ics", **options)
    text = Path(exported["output"]).read_text("utf-8")
    assert "SUMMARY:November" not in text and "SUMMARY:Late October timed" in text
    missing_end = next(
        event for event in text.split("BEGIN:VEVENT") if "SUMMARY:October missing end" in event
    )
    assert (
        "DTSTART;VALUE=DATE:20261001" in missing_end and "DTEND;VALUE=DATE:20261002" in missing_end
    )


def test_media_metadata_sort_range_selection_and_reused_index(fixture_backup):
    store, backup, photo = fixture_backup
    unix = datetime(2026, 10, 1, tzinfo=timezone.utc).timestamp()
    second = add_entry(
        backup,
        "CameraRollDomain",
        "Media/DCIM/100APPLE/IMG_0002.MOV",
        b"v" * 300,
        {"Size": 280, "Birth": unix},
    )
    third = add_entry(
        backup,
        "CameraRollDomain",
        "Media/DCIM/100APPLE/IMG_0003.JPG",
        b"p" * 200,
        {"Size": 180, "Birth": unix + 86400},
    )
    reader = DataReader(store)
    result = reader.read(backup, "photos", sort="size", order="desc", limit=2)
    assert [r["id"] for r in result["rows"]] == [second, third]
    assert result["rows"][0]["size"] == 280 and result["rows"][0]["dateSource"] == "fileCreated"
    result = reader.read(backup, "photos", dateFrom="2026-10-02", dateTo="2026-10-02")
    assert result["total"] == 1 and result["rows"][0]["id"] == third
    assert reader.read(backup, "photos", filters={"ids": []})["total"] == 0
    assert (
        reader.read(backup, "photos", filters={"excludeIds": [photo, third]})["rows"][0]["id"]
        == second
    )
    assert reader.indexes.builds == 1


def test_media_capture_date_supersedes_file_timestamp(fixture_backup):
    store, backup, photo = fixture_backup
    add_entry(
        backup,
        "CameraRollDomain",
        "Media/PhotoData/Photos.sqlite",
        database(
            """CREATE TABLE ZASSET (ZFILENAME TEXT,ZDIRECTORY TEXT,ZDATECREATED REAL,ZWIDTH INTEGER,ZHEIGHT INTEGER);
        INSERT INTO ZASSET VALUES('IMG_0001.PNG','DCIM/100APPLE',800000000,50,50);"""
        ),
    )
    row = DataReader(store).read(backup, "photos")["rows"][0]
    assert row["id"] == photo and row["date"] == apple_date(800000000)
    assert row["dateSource"] == "capture" and row["width"] == 50
