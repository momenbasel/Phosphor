from __future__ import annotations

import json
import re
import sqlite3
import subprocess
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


def test_message_pdf_export_is_registered_and_uses_native_pdf_writer(root: Path) -> None:
    model = read(root, "Sources/Phosphor/Models/Message.swift")
    exporter = read(root, "Sources/Phosphor/Services/MessageExporter.swift")
    wa = read(root, "Sources/Phosphor/Services/WhatsAppExporter.swift")
    view = read(root, "Sources/Phosphor/Views/Messages/MessageListView.swift")
    writer = read(root, "Sources/Phosphor/Utilities/PDFTranscriptWriter.swift")
    assert_contains(model, "case pdf = \"PDF\"", "Message export formats should include PDF")
    assert_contains(model, "case .pdf: return \"pdf\"", "PDF exports should use .pdf filenames")
    assert_contains(view, "case .pdf: return .pdf", "Save panels should advertise the PDF content type")
    assert_contains(exporter, "case .pdf:", "iMessage exporter should dispatch PDF exports")
    assert_contains(exporter, "try exportPDF", "iMessage exporter should call a PDF writer")
    assert_contains(wa, "case .pdf:", "WhatsApp exporter should handle the shared PDF format")
    assert_contains(writer, "CGContext(consumer: consumer, mediaBox:", "PDF writer should render native PDF output")
    assert_contains(writer, "CTFramesetterCreateWithAttributedString", "PDF writer should measure and wrap text")
    assert_contains(writer, "CGPath(roundedRect:", "PDF writer should render rounded iMessage-style bubbles")
    assert_contains(writer, "outgoingBubbleColor", "PDF writer should distinguish outgoing blue bubbles")
    assert_contains(writer, "incomingBubbleColor", "PDF writer should distinguish incoming gray bubbles")
    assert_contains(writer, "drawReactionBadge", "PDF writer should render tapbacks/reactions as visible badges")
    assert_contains(writer, "Inline reply:", "PDF writer should preserve iMessage inline reply context")
    assert_contains(writer, "makeCard", "PDF writer should render inline replies, links, and attachments as natural in-bubble cards")
    assert_contains(writer, "drawStatus", "PDF writer should render read/service status as small bubble metadata instead of transcript rows")
    assert_contains(exporter, "reactions: reactionBadges", "PDF export should pass iMessage tapbacks into the PDF writer")
    assert_contains(exporter, "inlineReply: replyPreview(for: msg)", "PDF export should pass inline reply previews into the PDF writer")
    assert_contains(exporter, "thread_originator_guid", "Message export should read iMessage inline reply thread metadata")
    assert_contains(exporter, "reply_to_guid", "Message export should read modern inline reply target metadata")
    assert_contains(exporter, "attachments: attachmentSummaries", "PDF export should pass attachment metadata into the PDF writer")
    assert_contains(exporter, "linkURL: msg.linkURL", "PDF export should pass rich-link URLs into the PDF writer")
    assert_contains(exporter, "status: statusParts.isEmpty ? nil", "PDF export should pass service/read status into the PDF writer")
    assert_contains(writer, "entry.isFromMe ? margin + contentWidth - bubbleWidth : margin", "PDF writer should right-align outgoing bubbles and left-align incoming bubbles")


def test_attributed_message_body_is_decoded_when_plain_text_is_missing(root: Path) -> None:
    exporter = read(root, "Sources/Phosphor/Services/MessageExporter.swift")
    decoder = root / "Sources/Phosphor/Utilities/MessageAttributedBodyDecoder.swift"
    typedstream_sources = sorted((root / "Sources/Phosphor/Utilities/MessageTypedStream").glob("*.swift"))
    writer = root / "Sources/Phosphor/Utilities/PDFTranscriptWriter.swift"
    notices = root / "THIRD_PARTY_NOTICES.md"
    build_script = read(root, "Scripts/build.sh")
    assert decoder.exists(), "Message exports should include an attributedBody typedstream decoder"
    assert typedstream_sources, "Message exports should include the bounded pure-Swift typedstream parser"
    assert notices.exists() and "Madrid TypedStream" in notices.read_text(), "Vendored typedstream code should retain its MIT notice"
    assert_contains(build_script, 'THIRD_PARTY_NOTICES.md', "Release bundles should include third-party license notices")
    assert_contains(exporter, '"attributedBody"', "Message queries should select attributedBody when the schema provides it")
    assert_contains(exporter, "MessageAttributedBodyDecoder.text", "Message parsing should fall back to decoded attributedBody text")
    assert "NSUnarchiver" not in decoder.read_text(), "Backup-controlled attributedBody data must not use unsafe Foundation unarchiving"

    probe = r'''
import Foundation
import PDFKit

@main
struct AttributedBodyProbe {
    static func main() throws {
        let expected = "INLINE_ATTRIBUTED_BODY_SENTINEL"
        let archived = NSArchiver.archivedData(withRootObject: NSAttributedString(string: expected))
        guard let decoded = MessageAttributedBodyDecoder.text(from: archived), decoded == expected else {
            fputs("failed to decode NSArchiver attributed string\n", stderr)
            exit(1)
        }
        guard MessageAttributedBodyDecoder.text(from: Data([0x00, 0x01, 0x02])) == nil else {
            fputs("malformed archives must fail closed\n", stderr)
            exit(2)
        }
        let truncatedTypedstream = Data([0x04, 0x0B]) + Data("streamtyped".utf8)
        guard MessageAttributedBodyDecoder.text(from: truncatedTypedstream) == nil else {
            fputs("truncated typedstreams must fail closed\n", stderr)
            exit(3)
        }
        let referenceRun = truncatedTypedstream + Data(repeating: 0xFF, count: 1_048_576)
        guard MessageAttributedBodyDecoder.text(from: referenceRun) == nil else {
            fputs("malformed reference runs must fail closed\n", stderr)
            exit(4)
        }
        var amplifiedTypes = truncatedTypedstream + Data([0x81, 0xE8, 0x03])
        amplifiedTypes.append(contentsOf: [0x84, 0x82, 0x00, 0x00, 0x01, 0x00])
        amplifiedTypes.append(Data(repeating: 0x7F, count: 65_536))
        for _ in 0..<100 {
            amplifiedTypes.append(contentsOf: [0x92, 0x86])
        }
        do {
            _ = try MessageTypedStreamDecoder.decode(amplifiedTypes)
            fputs("repeated type references must exhaust a decoded-output budget\n", stderr)
            exit(5)
        } catch MessageTypedStreamDecoderError.resourceLimit {
            // Expected: references must not amplify a small archive into an unbounded output graph.
        }
        try PDFTranscriptWriter.write(
            title: "Attributed Body Regression",
            subtitle: "",
            entries: [PDFTranscriptWriter.Entry(
                title: "Me",
                subtitle: "",
                body: decoded,
                isFromMe: true,
                inlineReply: "original message"
            )],
            to: CommandLine.arguments[1]
        )
        guard let text = PDFDocument(url: URL(fileURLWithPath: CommandLine.arguments[1]))?.string,
              text.filter({ $0.isLetter || $0.isNumber }).contains(expected.filter({ $0.isLetter || $0.isNumber })),
              text.contains("Inline reply") else {
            fputs("decoded attributedBody text was missing from PDF output\n", stderr)
            exit(6)
        }
    }
}
'''
    with tempfile.TemporaryDirectory() as temp_dir:
        temp = Path(temp_dir)
        probe_path = temp / "Probe.swift"
        probe_path.write_text(probe)
        executable = temp / "attributed-body-probe"
        compile_result = subprocess.run(
            [
                "swiftc", "-parse-as-library", *map(str, typedstream_sources), str(decoder), str(writer), str(probe_path),
                "-framework", "PDFKit", "-o", str(executable),
            ],
            capture_output=True,
            text=True,
            timeout=60,
        )
        assert compile_result.returncode == 0, compile_result.stderr
        result = subprocess.run([str(executable), str(temp / "attributed-body.pdf")], capture_output=True, text=True, timeout=10)
        assert result.returncode == 0, result.stderr


def test_oversized_attributed_body_is_null_before_sqlite_materialization(root: Path) -> None:
    exporter = read(root, "Sources/Phosphor/Services/MessageExporter.swift")
    decoder = root / "Sources/Phosphor/Utilities/MessageAttributedBodyDecoder.swift"
    sqlite_reader = root / "Sources/Phosphor/Utilities/SQLiteReader.swift"
    typedstream_sources = sorted((root / "Sources/Phosphor/Utilities/MessageTypedStream").glob("*.swift"))
    assert_contains(
        exporter,
        "MessageAttributedBodyDecoder.attributedBodyCandidateSQLProjection",
        "Bulk message queries should select only bounded attributedBody candidate row IDs",
    )
    assert_contains(
        exporter,
        "loadAttributedBodyText(messageId:",
        "Attributed bodies should be loaded and decoded one row at a time instead of retained across a result set",
    )
    assert_contains(
        exporter,
        "remainingAttributedBodyTextBytes",
        "Each message query should cap the aggregate recovered attributedBody text retained in memory",
    )
    select_fields = re.search(
        r"private func messageSelectFields\(\) -> String \{(?P<body>.*?)\n    \}",
        exporter,
        re.S,
    )
    assert select_fields is not None
    assert "fields.append(MessageAttributedBodyDecoder.attributedBodySQLProjection)" not in select_fields.group("body"), (
        "Bulk message SELECTs must not materialize attributedBody BLOBs"
    )

    probe = r'''
import Foundation

@main
struct OversizedAttributedBodyProbe {
    static func main() throws {
        let reader = try SQLiteReader(path: CommandLine.arguments[1])
        let candidates = try reader.query(
            "SELECT \(MessageAttributedBodyDecoder.attributedBodyCandidateSQLProjection) FROM message m ORDER BY m.ROWID"
        )
        guard candidates.count == 3,
              candidates[0]["attributed_body_rowid"] as? Int == 1,
              (candidates[1]["attributed_body_rowid"] ?? nil) == nil,
              (candidates[2]["attributed_body_rowid"] ?? nil) == nil else {
            fputs("bulk query did not reduce attributedBody values to bounded candidate row IDs\n", stderr)
            exit(1)
        }

        let smallRows = try reader.query(
            "SELECT \(MessageAttributedBodyDecoder.attributedBodySQLProjection) FROM message m WHERE m.ROWID = 1 LIMIT 1"
        )
        let oversizedRows = try reader.query(
            "SELECT \(MessageAttributedBodyDecoder.attributedBodySQLProjection) FROM message m WHERE m.ROWID = 2 LIMIT 1"
        )
        guard let small = smallRows.first?["attributedBody"] as? Data,
              small == Data([0x01, 0x02, 0x03]),
              (oversizedRows.first?["attributedBody"] ?? nil) == nil else {
            fputs("oversized attributedBody was materialized instead of projected as NULL\n", stderr)
            exit(2)
        }
    }
}
'''
    with tempfile.TemporaryDirectory() as temp_dir:
        temp = Path(temp_dir)
        database = temp / "sms.db"
        connection = sqlite3.connect(database)
        try:
            connection.execute("CREATE TABLE message (text TEXT, attributedBody BLOB)")
            connection.execute("INSERT INTO message (text, attributedBody) VALUES (NULL, ?)", (sqlite3.Binary(b"\x01\x02\x03"),))
            connection.execute(
                "INSERT INTO message (text, attributedBody) VALUES (NULL, zeroblob(?))",
                (16 * 1024 * 1024 + 1,),
            )
            connection.execute(
                "INSERT INTO message (text, attributedBody) VALUES ('plain text wins', ?)",
                (sqlite3.Binary(b"\x04\x05\x06"),),
            )
            connection.commit()
        finally:
            connection.close()

        probe_path = temp / "Probe.swift"
        probe_path.write_text(probe)
        executable = temp / "oversized-attributed-body-probe"
        compile_result = subprocess.run(
            [
                "swiftc", "-parse-as-library", *map(str, typedstream_sources), str(decoder), str(sqlite_reader),
                str(probe_path), "-lsqlite3", "-o", str(executable),
            ],
            capture_output=True,
            text=True,
            timeout=60,
        )
        assert compile_result.returncode == 0, compile_result.stderr
        result = subprocess.run([str(executable), str(database)], capture_output=True, text=True, timeout=10)
        assert result.returncode == 0, result.stderr





def test_bulk_message_exports_use_collision_safe_filenames(root: Path) -> None:
    src = read(root, "Sources/Phosphor/Services/MessageExporter.swift")
    export_all = re.search(r"func exportAllChats\(.*?\) throws -> Int \{(?P<body>.*?)\n    \}", src, re.S)
    assert export_all is not None, "exportAllChats should exist"
    assert_contains(
        export_all.group("body"),
        "chat.exportFilename(format: format, includeChatID: true)",
        "exportAllChats should preserve contact names and include collision-safe chat IDs",
    )


def test_pdf_export_filenames_preserve_resolved_contact_name(root: Path) -> None:
    model = root / "Sources/Phosphor/Models/Message.swift"
    exporter = read(root, "Sources/Phosphor/Services/MessageExporter.swift")
    view = read(root, "Sources/Phosphor/Views/Messages/MessageListView.swift")
    assert_contains(
        model.read_text(),
        "func exportFilename(format: MessageExportFormat, includeChatID: Bool)",
        "MessageChat should own contact-preserving export filename generation",
    )
    assert_contains(
        exporter,
        "chat.exportFilename(format: format, includeChatID: true)",
        "Bulk exports should preserve the resolved contact name while retaining collision-safe chat IDs",
    )
    assert_contains(
        view,
        "chat.exportFilename(format: format, includeChatID: false)",
        "Single-chat save panels should default PDF files to the resolved contact name",
    )

    probe = r'''
import Foundation

extension Date {
    var shortString: String { "" }
}

@main
struct ContactFilenameProbe {
    static func main() {
        let chat = MessageChat(
            id: 42,
            chatIdentifier: "+15551234567",
            displayName: "",
            participants: ["+15551234567"],
            resolvedTitle: "Jane Doe",
            lastMessageDate: nil,
            messageCount: 1,
            isGroupChat: false
        )
        guard chat.exportFilename(format: .pdf, includeChatID: false) == "Jane Doe.pdf",
              chat.exportFilename(format: .pdf, includeChatID: true) == "Jane Doe-chat-42.pdf" else {
            fputs("PDF export filename did not preserve the resolved contact name\n", stderr)
            exit(1)
        }
    }
}
'''
    with tempfile.TemporaryDirectory() as temp_dir:
        temp = Path(temp_dir)
        probe_path = temp / "Probe.swift"
        probe_path.write_text(probe)
        executable = temp / "contact-filename-probe"
        result = subprocess.run(
            ["swiftc", "-parse-as-library", str(model), str(probe_path), "-o", str(executable)],
            capture_output=True,
            text=True,
            timeout=60,
        )
        assert result.returncode == 0, result.stderr
        run = subprocess.run([str(executable)], capture_output=True, text=True, timeout=10)
        assert run.returncode == 0, run.stderr


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


def test_message_view_clears_stale_loaded_backup_and_preserves_readiness(root: Path) -> None:
    view_model = read(root, "Sources/Phosphor/ViewModels/MessageViewModel.swift")
    assert_contains(view_model, "func clear()", "MessageViewModel should expose a clear path for stale backup state")
    assert_contains(view_model, "var loadedBackupPath", "MessageViewModel should expose the loaded backup path for UI reconciliation")
    assert_contains(view_model, "exportOperationID", "Message exports should ignore stale detached task completions after clearing/switching backups")
    assert_contains(view_model, "invalidateExportForBackupSwitch", "Switching backups should cancel and clear active export state")
    assert_contains(view_model, "exportTask?.cancel()", "Switching/clearing backups should cancel active detached export work")
    assert_contains(view_model, "self.exportOperationID == exportID", "Detached export completions should only update current export state")
    assert_contains(view_model, "self.backupPath == backupPath", "Detached export completions should not update UI after the loaded backup changes")

    view = read(root, "Sources/Phosphor/Views/Messages/MessageListView.swift")
    assert_contains(view, ".onChange(of: backupVM.selectedBackup?.id)", "Messages should react when BackupViewModel clears or changes the selected backup")
    assert_contains(view, ".onChange(of: backupVM.backups.map(\\.path))", "Messages should react when the backup folder/list changes")
    assert_contains(view, "reconcileLoadedBackupWithAvailableBackups", "Messages should clear old chats when their backup path disappears")
    assert_contains(view, "messageVM.clear()", "Messages should clear stale conversations/export state")
    assert_contains(view, "messageVM.loadedBackupPath != nil && loadedBackupIsCurrent && messageVM.chats.isEmpty", "Messages readiness should render even when BackupViewModel selectedBackup is nil after manifest-open failure")
    assert_contains(view, "guard loadedBackupIsCurrent", "Export actions should be gated to the currently loaded backup")


def test_stale_export_completion_model_requires_current_operation_and_backup(root: Path) -> None:
    del root
    state = {
        "exportOperationID": "export-1",
        "backupPath": "/backups/A",
        "isExporting": True,
        "exportResult": None,
    }

    def complete(export_id: str, backup_path: str, result: str) -> None:
        if state["exportOperationID"] != export_id or state["backupPath"] != backup_path:
            return
        state["isExporting"] = False
        state["exportOperationID"] = None
        state["exportResult"] = result

    def fail_or_cancel(export_id: str, backup_path: str, message: str) -> None:
        if state["exportOperationID"] != export_id or state["backupPath"] != backup_path:
            return
        state["isExporting"] = False
        state["exportOperationID"] = None
        state["alertMessage"] = message

    def switch_backup(path: str) -> None:
        if state["backupPath"] != path:
            state["exportOperationID"] = None
            state["isExporting"] = False
        state["backupPath"] = path

    state["exportOperationID"] = None  # MessageViewModel.clear()
    complete("export-1", "/backups/A", "stale clear completion")
    fail_or_cancel("export-1", "/backups/A", "stale clear failure")
    assert state["exportResult"] is None, "cleared exports must ignore stale completions"
    assert "alertMessage" not in state, "cleared exports must ignore stale failure/cancel alerts"

    state.update(exportOperationID="export-2", backupPath="/backups/A", isExporting=True)
    switch_backup("/backups/B")
    complete("export-2", "/backups/A", "stale backup completion")
    fail_or_cancel("export-2", "/backups/A", "stale backup failure")
    assert state["exportResult"] is None, "backup switches must ignore completions from the old backup"
    assert "alertMessage" not in state, "backup switches must ignore failure/cancel alerts from the old backup"
    assert state["isExporting"] is False, "backup switches should not leave the export overlay stuck"

    state.update(exportOperationID="export-3", backupPath="/backups/B", isExporting=True)
    complete("export-3", "/backups/B", "current completion")
    assert state["exportResult"] == "current completion"
    assert state["isExporting"] is False


def test_message_exports_escape_csv_and_mbox_headers(root: Path) -> None:
    src = read(root, "Sources/Phosphor/Services/MessageExporter.swift")
    helper = read(root, "Sources/Phosphor/Utilities/CSVExport.swift")
    assert_contains(helper, "enum CSVExport", "CSV export escaping should be centralized for all CSV surfaces")
    assert_contains(helper, "static func field", "CSV helper should expose field escaping")
    assert_contains(helper, "drop(while:", "CSV helper should detect formula payloads after leading whitespace")
    assert_contains(helper, '["=", "+", "-", "@"].contains', "CSV helper should neutralize spreadsheet formula-leading cells")
    assert_contains(src, "fields.map(CSVExport.field)", "Message CSV export should escape every field, not only message text")
    assert_contains(src, "private func mboxToken", "MBOX export should sanitize Message-ID/boundary tokens")
    assert_contains(src, "private func headerToken", "MBOX export should sanitize MIME header tokens")
    assert_contains(src, ".replacingOccurrences(of: \"\\n\", with: \" \")", "MBOX header encoding should strip raw newlines")
    assert_contains(src, "embeddedAttachments", "MBOX export should collect every embeddable attachment")
    assert_contains(src, "for embedded in embeddedAttachments", "MBOX export should emit all non-payload attachments, not just the first")


def test_csv_exports_share_formula_safe_helper(root: Path) -> None:
    helper = read(root, "Sources/Phosphor/Utilities/CSVExport.swift")
    assert_contains(helper, "static func row", "CSV helper should centralize whole-row creation")
    for rel in [
        "Sources/Phosphor/Services/CalendarExtractor.swift",
        "Sources/Phosphor/Services/CallLogExtractor.swift",
        "Sources/Phosphor/Services/ContactsExtractor.swift",
        "Sources/Phosphor/Services/HealthExtractor.swift",
        "Sources/Phosphor/Services/SafariExtractor.swift",
        "Sources/Phosphor/Services/WhatsAppExporter.swift",
    ]:
        src = read(root, rel)
        assert_contains(src, "CSVExport.row", f"{rel} should use the shared CSV escaping/formula-neutralization helper")


def test_message_export_writers_check_cancellation_inside_long_loops(root: Path) -> None:
    src = read(root, "Sources/Phosphor/Services/MessageExporter.swift")
    assert_contains(src, "cancellationCheck: (() throws -> Void)?", "Message exports should accept a cancellation checkpoint")
    for func_name in ["exportCSV", "exportPlainText", "exportHTML", "exportMbox", "exportJSON"]:
        match = re.search(rf"private func {func_name}.*?(?=\n    private func|\n    ///|\Z)", src, re.S)
        assert match is not None, f"{func_name} not found"
        assert_contains(match.group(0), "try cancellationCheck?()", f"{func_name} should stop promptly during large single-chat exports")
    stage = re.search(r"private func stageAttachments.*?(?=\n    private func|\n    ///|\Z)", src, re.S)
    assert stage is not None, "stageAttachments should exist"
    assert_contains(stage.group(0), "try cancellationCheck?()", "HTML attachment staging should be cancellable")


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


def test_message_exporter_caches_schema_and_preserves_tapback_context(root: Path) -> None:
    src = read(root, "Sources/Phosphor/Services/MessageExporter.swift")
    assert_contains(src, "private let messageColumns", "message table columns should be cached per exporter")
    assert_contains(src, "private func foldRows", "reaction/tapback folding should be centralized")
    assert_contains(src, "reactionEventsByTarget", "tapback rows must be folded with their target messages")
    assert_contains(src, "associated_message_type", "tapback detection should use associated_message_type when present")
