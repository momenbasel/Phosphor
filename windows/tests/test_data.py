from pathlib import Path
import csv
import io
import json
import pytest
from data import DataReader, apple_date


@pytest.mark.parametrize(
    "kind,count",
    [
        ("messages", 1),
        ("whatsapp", 1),
        ("contacts", 2),
        ("calendar", 1),
        ("notes", 1),
        ("calls", 1),
        ("safari", 1),
        ("photos", 1),
        ("music", 1),
        ("watch", 1),
        ("health", 1),
    ],
)
def test_real_sqlite_parsers(fixture_backup, kind, count):
    store, backup, photo = fixture_backup
    result = DataReader(store).read(backup, kind)
    assert result["total"] == count
    assert len(result["rows"]) == count


def test_message_dates_and_html_escaping(fixture_backup, tmp_path):
    store, backup, photo = fixture_backup
    reader = DataReader(store)
    messages = reader.read(backup, "messages", chat=1)["rows"]
    assert messages[0]["body"] == "A memory worth keeping."
    assert messages[1]["outgoing"] == 1
    assert messages[0]["date"].startswith("2026-")
    result = reader.export(backup, "messages", tmp_path / "export.html", "html", chat=1)
    html = Path(result["output"]).read_text("utf-8")
    assert "<script>" not in html
    assert "&lt;script&gt;" in html


def test_contact_export_neutralizes_formulas_and_preserves_numbers(fixture_backup, tmp_path):
    store, backup, photo = fixture_backup
    reader = DataReader(store)
    result = reader.export(backup, "contacts", tmp_path / "contacts.csv")
    rows = list(csv.DictReader(io.StringIO(Path(result["output"]).read_text("utf-8-sig"))))
    assert rows[1]["first"].startswith("'=")
    assert rows[0]["phones"] == "'+15550101"
    result = reader.export(backup, "contacts", tmp_path / "contacts.vcf", "vcf")
    assert "TEL;TYPE=CELL:+15550101" in Path(result["output"]).read_text("utf-8")


def test_calendar_ics_all_day_and_escaping(fixture_backup, tmp_path):
    store, backup, photo = fixture_backup
    result = DataReader(store).export(backup, "calendar", tmp_path / "events.ics", "ics")
    data = Path(result["output"]).read_text("utf-8")
    assert "DTSTART;VALUE=DATE:" in data
    assert "SUMMARY:Weekend\\; trip" in data
    assert "UID:" in data
    assert "Line one\\nLine two" in data


def test_paging_search_before_limit(fixture_backup):
    store, backup, photo = fixture_backup
    reader = DataReader(store)
    assert reader.read(backup, "contacts", offset=1, limit=1)["rows"][0]["first"] == "=FORMULA"
    assert reader.read(backup, "contacts", query="FORMULA", limit=1)["total"] == 1
    assert reader.read(backup, "contacts", query="%")["total"] == 0
    assert reader.read(backup, "messages", chat=1, offset=1, limit=1)["rows"][0]["outgoing"] == 1


def test_thumbnail_and_portable_json(fixture_backup, tmp_path):
    store, backup, photo = fixture_backup
    reader = DataReader(store)
    assert reader.thumbnail(backup, photo).startswith("data:image/jpeg;base64,")
    result = reader.export(backup, "whatsapp", tmp_path / "whatsapp.json", "json")
    assert (
        json.loads(Path(result["output"]).read_text("utf-8"))[0]["body"] == "Hello from the fixture"
    )
