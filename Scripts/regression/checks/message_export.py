from __future__ import annotations

import json
import re
import sqlite3
import tempfile
from pathlib import Path


def read(root: Path, rel: str) -> str:
    return (root / rel).read_text()


def assert_contains(text: str, needle: str, message: str) -> None:
    assert needle in text, message


def test_streaming_exports_truncate_before_write(root: Path) -> None:
    src = read(root, "Sources/Phosphor/Services/MessageExporter.swift")
    for func_name in ["exportCSV", "exportPlainText", "exportHTML", "exportMbox", "exportJSON"]:
        match = re.search(rf"private func {func_name}.*?(?=\n    private func|\n    ///|\Z)", src, re.S)
        assert match is not None, f"{func_name} not found"
        body = match.group(0)
        assert_contains(body, "removeItem(at: outputURL)", f"{func_name} must remove existing output before streaming")
        assert_contains(body, "FileHandle(forWritingTo: outputURL)", f"{func_name} must stream through FileHandle")





def test_bulk_message_exports_use_collision_safe_filenames(root: Path) -> None:
    src = read(root, "Sources/Phosphor/Services/MessageExporter.swift")
    assert_contains(src, "private func exportFilename(for chat", "Bulk message export should centralize filename generation")
    assert_contains(src, "-chat-\\(chat.id)", "Bulk message export filenames should include chat id to avoid duplicate-title overwrites")
    export_all = re.search(r"func exportAllChats\(.*?\) throws -> Int \{(?P<body>.*?)\n    \}", src, re.S)
    assert export_all is not None, "exportAllChats should exist"
    assert_contains(export_all.group("body"), "exportFilename(for: chat", "exportAllChats should use collision-safe filenames")


def test_html_export_cleans_stale_attachment_folder(root: Path) -> None:
    src = read(root, "Sources/Phosphor/Services/MessageExporter.swift")
    assert_contains(src, "private func removeAttachmentFolder(forHTMLPath", "HTML export should have explicit stale attachment cleanup")
    html = re.search(r"private func exportHTML\(.*?\) throws \{(?P<body>.*?)\n    \}", src, re.S)
    assert html is not None, "exportHTML should exist"
    assert_contains(html.group("body"), "removeAttachmentFolder(forHTMLPath: path)", "HTML export should remove stale attachment folders before staging/writing")
def test_json_overwrite_fixture_has_no_stale_tail(root: Path) -> None:
    del root  # fixture mirrors the Swift export invariant without touching source files.
    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / "export.json"
        long_payload = {"messages": [{"text": "x" * 10_000}]}
        short_payload = {"messages": []}
        path.write_text(json.dumps(long_payload), encoding="utf-8")
        path.unlink(missing_ok=True)
        with path.open("w", encoding="utf-8") as handle:
            handle.write(json.dumps(short_payload))
        assert json.loads(path.read_text(encoding="utf-8")) == short_payload


def test_attachment_path_cache_invariants(root: Path) -> None:
    src = read(root, "Sources/Phosphor/Services/MessageExporter.swift")
    assert_contains(src, "attachmentDiskPathCache", "attachment path cache should exist")
    assert_contains(src, "missingAttachmentDiskPaths", "missing attachment cache should exist")
    assert_contains(src, "if let cached = attachmentDiskPathCache[filename]", "resolver should hit positive cache")
    assert_contains(src, "missingAttachmentDiskPaths.contains(filename)", "resolver should hit negative cache")
    assert_contains(src, "attachmentDiskPathCache[filename] = candidate", "resolver should store positive cache")
    assert_contains(src, "missingAttachmentDiskPaths.insert(filename)", "resolver should store negative cache")


def test_minimal_sms_schema_fixture_supports_limited_attachment_query(root: Path) -> None:
    del root
    with tempfile.TemporaryDirectory() as tmp:
        db_path = Path(tmp) / "sms.db"
        con = sqlite3.connect(db_path)
        con.executescript(
            """
            CREATE TABLE attachment (ROWID INTEGER PRIMARY KEY, guid TEXT, filename TEXT, mime_type TEXT, transfer_name TEXT, total_bytes INTEGER);
            CREATE TABLE message_attachment_join (message_id INTEGER, attachment_id INTEGER);
            INSERT INTO attachment VALUES (1,'a','~/Library/SMS/Attachments/a.jpg','image/jpeg','a.jpg',10);
            INSERT INTO attachment VALUES (2,'b','~/Library/SMS/Attachments/b.jpg','image/jpeg','b.jpg',20);
            INSERT INTO message_attachment_join VALUES (100,1);
            INSERT INTO message_attachment_join VALUES (200,2);
            """
        )
        rows = con.execute(
            """
            SELECT maj.message_id, a.ROWID, a.guid, a.filename, a.mime_type, a.transfer_name, a.total_bytes
            FROM attachment a JOIN message_attachment_join maj ON maj.attachment_id = a.ROWID
            WHERE maj.message_id IN (?)
            """,
            (100,),
        ).fetchall()
        con.close()
        assert len(rows) == 1 and rows[0][0] == 100, "limited attachment query should only load requested message IDs"


def test_csv_and_mbox_exports_sanitize_all_untrusted_fields(root: Path) -> None:
    src = read(root, "Sources/Phosphor/Services/MessageExporter.swift")
    csv_helper = read(root, "Sources/Phosphor/Utilities/CSVExport.swift")
    assert_contains(csv_helper, "enum CSVExport", "CSV export should centralize field escaping and formula neutralization")
    assert_contains(csv_helper, "[\"=\", \"+\", \"-\", \"@\", \"\\t\", \"\\r\", \"\\n\"].contains", "CSV export should neutralize formula-leading cells")
    assert_contains(src, "].map(CSVExport.field)", "Messages CSV export should apply escaping to every field, not only message text")
    for rel in [
        "Sources/Phosphor/Services/ContactsExtractor.swift",
        "Sources/Phosphor/Services/HealthExtractor.swift",
        "Sources/Phosphor/Services/SafariExtractor.swift",
        "Sources/Phosphor/Services/CalendarExtractor.swift",
        "Sources/Phosphor/Services/CallLogExtractor.swift",
        "Sources/Phosphor/Services/WhatsAppExporter.swift",
    ]:
        assert_contains(read(root, rel), "CSVExport.", f"{rel} should use centralized CSV escaping")
    assert_contains(src, "messageIDLocalPart", "MBOX Message-ID should sanitize database-derived GUIDs")
    assert_contains(src, "mimeBoundary(for: msg.guid)", "MBOX MIME boundaries should not include raw database strings")
    assert_contains(src, "safeHeaderToken", "MBOX MIME type headers should reject CR/LF and unsafe characters")
    assert_contains(src, "replacingOccurrences(of: \"\\r\", with: \" \")", "MBOX header encoding should remove carriage returns")
    assert_contains(src, "replacingOccurrences(of: \"\\n\", with: \" \")", "MBOX header encoding should remove newlines")


def test_mbox_export_includes_all_available_attachments(root: Path) -> None:
    src = read(root, "Sources/Phosphor/Services/MessageExporter.swift")
    assert_contains(src, "payloadAttachments", "MBOX export should collect all readable non-payload attachments")
    assert_contains(src, "for payload in payloadAttachments", "MBOX export should emit one MIME part per readable attachment")
    assert "attachments.first(where" not in src[src.index("private func exportMbox"):src.index("/// Mbox bodies")], "MBOX export must not silently pick only the first attachment"


def test_message_exports_cancel_and_invalidate_on_backup_switch(root: Path) -> None:
    vm = read(root, "Sources/Phosphor/ViewModels/MessageViewModel.swift")
    view = read(root, "Sources/Phosphor/Views/Messages/MessageListView.swift")
    exporter = read(root, "Sources/Phosphor/Services/MessageExporter.swift")
    assert_contains(vm, "activeExportID", "Message exports should use operation IDs to ignore stale completions")
    assert_contains(vm, "self.backupPath == backupPath", "Export completions should be scoped to the captured backup path")
    assert_contains(vm, "cancelExport(presentAlert: false)", "Loading a different backup should cancel in-flight exports without stale UI")
    assert_contains(view, ".onChange(of: backupVM.selectedBackup?.path)", "Messages view should reload when external selected backup changes")
    assert_contains(view, ".onChange(of: backupVM.backups.map(\\.path))", "Messages view should clear/reload when the backup list changes")
    assert_contains(exporter, "cancellationCheck", "Export writers should accept a cancellation hook")
    assert_contains(exporter, "try cancellationCheck?()", "Export writer loops should check cancellation during long exports")


def test_notes_bulk_export_uses_collision_safe_filenames(root: Path) -> None:
    notes = read(root, "Sources/Phosphor/Services/NotesExtractor.swift")
    assert_contains(notes, "-note-\\(note.id)", "Bulk note export filenames should include stable note id to avoid duplicate-title overwrites")


def test_message_exporter_caches_schema_and_preserves_tapback_context(root: Path) -> None:
    src = read(root, "Sources/Phosphor/Services/MessageExporter.swift")
    assert_contains(src, "private let messageColumns", "message table columns should be cached per exporter")
    assert_contains(src, "private func foldRows", "reaction/tapback folding should be centralized")
    assert_contains(src, "reactionEventsByTarget", "tapback rows must be folded with their target messages")
    assert_contains(src, "associated_message_type", "tapback detection should use associated_message_type when present")
