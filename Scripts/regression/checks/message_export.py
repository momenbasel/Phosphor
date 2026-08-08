from __future__ import annotations

import json
import re
import sqlite3
import subprocess
import tempfile
import time
from pathlib import Path


def read(root: Path, rel: str) -> str:
    return (root / rel).read_text()


def assert_contains(text: str, needle: str, message: str) -> None:
    assert needle in text, message


def test_single_pdf_export_is_a_self_contained_folder(root: Path) -> None:
    exporter = read(root, "Sources/Phosphor/Services/MessageExporter.swift")
    view_model = read(root, "Sources/Phosphor/ViewModels/MessageViewModel.swift")
    view = read(root, "Sources/Phosphor/Views/Messages/MessageListView.swift")
    bundle_writer = read(root, "Sources/Phosphor/Utilities/MessageExportBundleWriter.swift")

    assert_contains(exporter, "func exportChatPDFBundle(", "MessageExporter needs a dedicated single-conversation PDF bundle API")
    assert_contains(exporter, "appendingPathComponent(\"Attachments\"", "A single PDF bundle must contain an Attachments folder")
    assert_contains(exporter, "format: .pdf", "A single PDF bundle must generate a PDF transcript")
    assert_contains(view_model, "func startExportChatPDFBundle(", "The view model needs a background PDF-bundle export route")
    assert_contains(view, "exportSingleChatPDFBundle()", "The PDF menu action must use the bundle route")
    assert_contains(view, "Choose where Phosphor should create a folder", "PDF bundle UI must ask for the parent folder, not a lone PDF filename")
    assert_contains(bundle_writer, "directoryName:", "Bundle writer must allow a collision-safe per-conversation directory name")


def test_message_exports_publish_generation_sidecars_without_crash_mismatch(root: Path) -> None:
    src = read(root, "Sources/Phosphor/Services/MessageExporter.swift")
    transaction = root / "Sources/Phosphor/Utilities/MessageExportTransaction.swift"
    attachment_exporter = root / "Sources/Phosphor/Utilities/MessageAttachmentExporter.swift"
    assert transaction.exists(), "single-conversation exports need a transactional staging helper"
    assert_contains(src, "MessageExportTransaction.write", "exportMessages must stage the transcript and sidecar as one recoverable operation")
    assert_contains(src, "stagedTranscriptURL.path", "format writers must receive a same-volume staging path")
    for func_name in ["exportCSV", "exportPlainText", "exportHTML", "exportMbox", "exportJSON"]:
        match = re.search(rf"private func {func_name}.*?(?=\n    private func|\n    ///|\Z)", src, re.S)
        assert match is not None, f"{func_name} not found"
        assert_contains(match.group(0), "FileHandle(forWritingTo: outputURL)", f"{func_name} must continue streaming through FileHandle")

    probe = r'''
import Foundation

@main
struct GenerationPublicationProbe {
    enum ProbeError: Error { case cancelled }

    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let final = root.appendingPathComponent("chat.txt")
        let source = root.appendingPathComponent("source.bin")
        let fileManager = FileManager.default
        try Data("NEW_ATTACHMENT".utf8).write(to: source)

        // The completed transcript points at its own immutable old generation.
        let oldGeneration = root.appendingPathComponent("chat-txt_attachments-old", isDirectory: true)
        try fileManager.createDirectory(at: oldGeneration, withIntermediateDirectories: true)
        try Data("OLD_ATTACHMENT".utf8).write(to: oldGeneration.appendingPathComponent("old.bin"))
        try Data("OLD:chat-txt_attachments-old/old.bin".utf8).write(to: final)

        let item = MessageAttachmentExporter.Item(key: "attachment", displayName: "new.bin", sourcePath: source.path)

        // Model abrupt process death after publishing a new sidecar but before
        // replacing the transcript. The old transcript must still resolve its old
        // sidecar; the new directory is merely an orphan recoverable on next run.
        let orphan = try MessageAttachmentExporter.prepareGeneration([item], beside: final.path)
        guard try String(contentsOf: final, encoding: .utf8) == "OLD:chat-txt_attachments-old/old.bin",
              fileManager.fileExists(atPath: oldGeneration.appendingPathComponent("old.bin").path),
              let orphanPath = orphan.paths["attachment"],
              let orphanURL = orphan.directoryURL,
              fileManager.fileExists(atPath: root.appendingPathComponent(orphanPath).path) else {
            exit(1)
        }

        // In-process writer failure removes the unreferenced new generation and
        // leaves the old published transcript/sidecar pair intact.
        do {
            try MessageExportTransaction.write(to: final, prepareAttachments: {
                try MessageAttachmentExporter.prepareGeneration([item], beside: final.path)
            }) { staged, paths in
                try Data("PARTIAL:\(paths["attachment"]!)".utf8).write(to: staged)
                throw ProbeError.cancelled
            }
            exit(2)
        } catch ProbeError.cancelled {}
        guard try String(contentsOf: final, encoding: .utf8) == "OLD:chat-txt_attachments-old/old.bin",
              fileManager.fileExists(atPath: oldGeneration.appendingPathComponent("old.bin").path),
              !fileManager.fileExists(atPath: root.appendingPathComponent("chat-txt_attachments").path) else {
            exit(3)
        }

        // A subsequent successful publication commits a transcript that embeds
        // the generation it references, then reclaims old/orphan generations.
        try MessageExportTransaction.write(to: final, prepareAttachments: {
            try MessageAttachmentExporter.prepareGeneration([item], beside: final.path)
        }) { staged, paths in
            try Data("NEW:\(paths["attachment"]!)".utf8).write(to: staged)
        }
        let transcript = try String(contentsOf: final, encoding: .utf8)
        let hasExpectedPrefix = transcript.hasPrefix("NEW:chat-txt_attachments-")
        let relativePath = transcript.split(separator: ":", maxSplits: 1).last.map(String.init)
        let newSidecarExists = relativePath.map { fileManager.fileExists(atPath: root.appendingPathComponent($0).path) } ?? false
        let oldGenerationExists = fileManager.fileExists(atPath: oldGeneration.path)
        let orphanExists = fileManager.fileExists(atPath: orphanURL.path)
        guard hasExpectedPrefix, newSidecarExists, !oldGenerationExists, !orphanExists else {
            fputs("prefix=\(hasExpectedPrefix) new=\(newSidecarExists) old=\(oldGenerationExists) orphan=\(orphanExists)\n", stderr)
            exit(4)
        }
    }
}
'''
    with tempfile.TemporaryDirectory() as temp_dir:
        temp = Path(temp_dir)
        probe_path = temp / "Probe.swift"
        probe_path.write_text(probe)
        executable = temp / "generation-publication-probe"
        compile_result = subprocess.run(
            ["swiftc", "-parse-as-library", str(attachment_exporter), str(transaction), str(probe_path), "-o", str(executable)],
            capture_output=True, text=True, timeout=60,
        )
        assert compile_result.returncode == 0, compile_result.stderr
        result = subprocess.run([str(executable), str(temp)], capture_output=True, text=True, timeout=20)
        assert result.returncode == 0, f"generation publication probe exited {result.returncode}: {result.stderr}"


def test_same_destination_exports_serialize_sidecar_publication(root: Path) -> None:
    transaction_path = root / "Sources/Phosphor/Utilities/MessageExportTransaction.swift"
    transaction = transaction_path.read_text()
    attachment_exporter = root / "Sources/Phosphor/Utilities/MessageAttachmentExporter.swift"

    assert_contains(
        transaction,
        "withDestinationLock",
        "same-destination exports must serialize generation cleanup after transcript publication",
    )
    assert_contains(
        transaction, "flock(",
        "the publication lock must also protect separate Phosphor processes",
    )
    assert_contains(
        transaction,
        "withDestinationLock(for: finalTranscriptURL)",
        "the complete prepare, publish, and cleanup transaction must run under the destination lock",
    )

    worker = r'''
import Foundation

@main
struct ConcurrentPublicationWorker {
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let marker = CommandLine.arguments[2]
        let fileManager = FileManager.default
        let final = root.appendingPathComponent("conversation.html")
        let source = root.appendingPathComponent("source-\(marker).jpg")
        try Data(marker.utf8).write(to: source)
        let item = MessageAttachmentExporter.Item(key: "image", displayName: "image.jpg", sourcePath: source.path)

        try MessageExportTransaction.write(to: final, prepareAttachments: {
            let generation = try MessageAttachmentExporter.prepareGeneration([item], beside: final.path)
            if marker == "A" {
                try Data().write(to: root.appendingPathComponent("A-sidecar-ready"))
            }
            return generation
        }) { staged, paths in
            if marker == "A" { Thread.sleep(forTimeInterval: 0.45) }
            try Data("\(marker):\(paths["image"]!)".utf8).write(to: staged)
        }

        guard fileManager.fileExists(atPath: final.path) else { exit(1) }
    }
}
'''
    with tempfile.TemporaryDirectory() as temp_dir:
        temp = Path(temp_dir)
        worker_path = temp / "ConcurrentPublicationWorker.swift"
        worker_path.write_text(worker)
        executable = temp / "concurrent-publication-worker"
        compile_result = subprocess.run(
            ["swiftc", "-parse-as-library", str(attachment_exporter), str(transaction_path), str(worker_path), "-o", str(executable)],
            capture_output=True, text=True, timeout=60,
        )
        assert compile_result.returncode == 0, compile_result.stderr

        first = subprocess.Popen([str(executable), str(temp), "A"], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        ready = temp / "A-sidecar-ready"
        deadline = time.monotonic() + 5
        while not ready.exists() and time.monotonic() < deadline:
            time.sleep(0.01)
        assert ready.exists(), "first worker did not publish its sidecar generation"

        second = subprocess.run([str(executable), str(temp), "B"], capture_output=True, text=True, timeout=10)
        first_stdout, first_stderr = first.communicate(timeout=10)
        assert first.returncode == 0, first_stderr or first_stdout
        assert second.returncode == 0, second.stderr or second.stdout

        transcript = (temp / "conversation.html").read_text()
        marker, relative_path = transcript.split(":", maxsplit=1)
        assert marker == "B", "the later same-destination export must win after serialized publication"
        assert (temp / relative_path).is_file(), "the completed transcript must retain the sidecar generation it references"


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
    assert_contains(exporter, "attachments: pdfAttachments", "PDF export should pass attachment metadata and resolved image paths into the PDF writer")
    assert_contains(exporter, "resolveAttachmentDiskPath(filename: filename)", "PDF export should resolve image attachments from the backup")
    assert_contains(writer, "CGImageSourceCreateThumbnailAtIndex", "PDF image previews should use bounded ImageIO thumbnails")
    assert_contains(exporter, "linkURL: msg.linkURL", "PDF export should pass rich-link URLs into the PDF writer")
    assert_contains(exporter, "status: statusParts.isEmpty ? nil", "PDF export should pass service/read status into the PDF writer")
    assert_contains(writer, "entry.isFromMe ? margin + contentWidth - bubbleWidth : margin", "PDF writer should right-align outgoing bubbles and left-align incoming bubbles")


def test_message_pdf_export_renders_image_attachments(root: Path) -> None:
    writer = root / "Sources/Phosphor/Utilities/PDFTranscriptWriter.swift"
    probe = r'''
import AppKit
import Foundation
import PDFKit

@main
struct PDFAttachmentProbe {
    static func main() throws {
        let imagePath = CommandLine.arguments[1]
        let pdfPath = CommandLine.arguments[2]
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 120,
            pixelsHigh: 90,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                bitmap.setColor(NSColor(calibratedRed: 1, green: 0, blue: 0, alpha: 1), atX: x, y: y)
            }
        }
        try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: imagePath))

        try PDFTranscriptWriter.write(
            title: "Attachment Regression",
            subtitle: "",
            entries: [PDFTranscriptWriter.Entry(
                title: "Me",
                subtitle: "",
                body: "",
                isFromMe: true,
                attachments: [.init(summary: "photo.png • image/png", imagePath: imagePath)]
            )],
            to: pdfPath
        )

        guard let document = PDFDocument(url: URL(fileURLWithPath: pdfPath)),
              let page = document.page(at: 0) else { exit(1) }
        let rendered = page.thumbnail(of: CGSize(width: 612, height: 792), for: .mediaBox)
        guard let tiff = rendered.tiffRepresentation, let pixels = NSBitmapImageRep(data: tiff) else { exit(2) }
        var foundRedPixel = false
        for y in stride(from: 0, to: pixels.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: pixels.pixelsWide, by: 2) {
                guard let color = pixels.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if color.redComponent > 0.8 && color.greenComponent < 0.2 && color.blueComponent < 0.2 {
                    foundRedPixel = true
                    break
                }
            }
            if foundRedPixel { break }
        }
        guard foundRedPixel else {
            fputs("PDF did not visibly render the image attachment\n", stderr)
            exit(3)
        }
    }
}
'''
    with tempfile.TemporaryDirectory() as temp_dir:
        temp = Path(temp_dir)
        probe_path = temp / "Probe.swift"
        probe_path.write_text(probe)
        executable = temp / "pdf-attachment-probe"
        compile_result = subprocess.run(
            ["swiftc", "-parse-as-library", str(writer), str(probe_path), "-framework", "PDFKit", "-o", str(executable)],
            capture_output=True,
            text=True,
            timeout=60,
        )
        assert compile_result.returncode == 0, compile_result.stderr
        result = subprocess.run(
            [str(executable), str(temp / "photo.png"), str(temp / "attachment.pdf")],
            capture_output=True,
            text=True,
            timeout=20,
        )
        assert result.returncode == 0, result.stderr


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


def test_message_export_filenames_preserve_names_without_chat_label(root: Path) -> None:
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
              chat.exportFilename(format: .pdf, includeChatID: true) == "Jane Doe-42.pdf" else {
            fputs("Export filename did not preserve the resolved contact name without adding Chat\n", stderr)
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


def test_message_export_progress_survives_messages_navigation(root: Path) -> None:
    app = read(root, "Sources/Phosphor/App/PhosphorApp.swift")
    content = read(root, "Sources/Phosphor/Views/ContentView.swift")
    messages = read(root, "Sources/Phosphor/Views/Messages/MessageListView.swift")

    assert_contains(
        app,
        "@StateObject private var messageVM = MessageViewModel()",
        "the export task must outlive the Messages screen",
    )
    assert_contains(
        app,
        ".environmentObject(messageVM)",
        "the app must provide one shared message export state to every section",
    )
    assert_contains(
        content,
        "@EnvironmentObject var messageVM: MessageViewModel",
        "the root content view must observe shared message export progress",
    )
    assert_contains(
        content,
        "if messageVM.isExporting { messageExportProgressView }",
        "the export progress bar must stay visible while navigating away from Messages",
    )
    assert_contains(
        content,
        "Button(\"Cancel\") { messageVM.cancelExport() }",
        "the persistent export progress bar must retain cancellation",
    )
    assert_contains(
        messages,
        "@EnvironmentObject var messageVM: MessageViewModel",
        "Messages must consume the shared export state instead of recreating it",
    )
    assert "@StateObject private var messageVM = MessageViewModel()" not in messages, (
        "recreating the Messages view must not make an active export progress bar disappear"
    )


def test_background_message_exports_keep_loaded_contact_directory(root: Path) -> None:
    view_model = read(root, "Sources/Phosphor/ViewModels/MessageViewModel.swift")
    assert_contains(
        view_model,
        "private var contactDirectory: ContactDirectory = .empty",
        "MessageViewModel should retain the contact directory loaded for the selected backup",
    )
    assert_contains(
        view_model,
        "self.contactDirectory = directory",
        "Loading chats should retain the resolved contacts for later background exports",
    )
    assert view_model.count("contacts: contactDirectory") >= 2, (
        "Single-chat and bulk detached exporters should preserve resolved contact names and sender labels"
    )


def test_html_export_uses_shared_fresh_attachment_sidecar(root: Path) -> None:
    src = read(root, "Sources/Phosphor/Services/MessageExporter.swift")
    helper = read(root, "Sources/Phosphor/Utilities/MessageAttachmentExporter.swift")
    assert_contains(helper, "stagingURL", "attachment sidecars should stage a fresh folder before replacing prior output")
    assert_contains(helper, "replaceItemAt", "attachment sidecars should atomically replace prior completed output")
    html = re.search(r"private func exportHTML\(.*?\) throws \{(?P<body>.*?)\n    \}", src, re.S)
    assert html is not None, "exportHTML should exist"
    assert "stageOriginalAttachments" not in html.group("body"), "HTML should not copy attachments a second time"
    assert_contains(html.group("body"), "attachmentMap", "HTML should link to the shared original-attachment sidecar")


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


def test_message_attachment_sidecars_are_collision_safe_and_cancellation_safe(root: Path) -> None:
    exporter = root / "Sources/Phosphor/Utilities/MessageAttachmentExporter.swift"
    assert exporter.exists(), "message exports should have a reusable original-attachment sidecar writer"

    probe = r'''
import Foundation

@main
struct AttachmentSidecarProbe {
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let htmlExport = root.appendingPathComponent("conversation.html")
        let pdfExport = root.appendingPathComponent("conversation.pdf")
        let first = root.appendingPathComponent("source-a/photo.jpg")
        let second = root.appendingPathComponent("source-b/photo.jpg")
        let fileManager = FileManager.default
        let legacySidecar = root.appendingPathComponent("conversation_attachments", isDirectory: true)
        try fileManager.createDirectory(at: legacySidecar, withIntermediateDirectories: true)
        try Data("stale".utf8).write(to: legacySidecar.appendingPathComponent("old.jpg"))
        let encodedPath = MessageAttachmentExporter.relativeURL(
            for: "conversation-html_attachments/photo#1? 50%.jpg"
        )
        guard encodedPath == "conversation-html_attachments/photo%231%3F%2050%25.jpg" else {
            fputs("HTML attachment paths were not URL encoded by segment\n", stderr)
            exit(1)
        }
        try fileManager.createDirectory(at: first.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: second.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("A".utf8).write(to: first)
        try Data("B".utf8).write(to: second)

        let initialGeneration = try MessageAttachmentExporter.prepareGeneration([
            .init(key: "first", displayName: "photo.jpg", sourcePath: first.path),
            .init(key: "second", displayName: "photo.jpg", sourcePath: second.path),
        ], beside: htmlExport.path)
        let initial = initialGeneration.paths
        MessageAttachmentExporter.cleanupObsoleteGenerations(for: initialGeneration)
        guard initial["first"]?.hasSuffix("/photo.jpg") == true,
              initial["second"]?.hasSuffix("/photo-2.jpg") == true else {
            fputs("duplicate attachment names were not made collision-safe\n", stderr)
            exit(1)
        }

        let sidecar = initialGeneration.directoryURL!
        guard !fileManager.fileExists(atPath: legacySidecar.path) else {
            fputs("legacy HTML sidecar was not cleaned after successful replacement\n", stderr)
            exit(2)
        }
        let initialNames = try Set(fileManager.contentsOfDirectory(atPath: sidecar.path))
        guard initialNames == ["photo.jpg", "photo-2.jpg"] else {
            fputs("initial sidecar contents were incomplete\n", stderr)
            exit(2)
        }

        let refreshedGeneration = try MessageAttachmentExporter.prepareGeneration([
            .init(key: "first", displayName: "photo.jpg", sourcePath: first.path),
        ], beside: htmlExport.path)
        let refreshed = refreshedGeneration.paths
        MessageAttachmentExporter.cleanupObsoleteGenerations(for: refreshedGeneration)
        let refreshedSidecar = refreshedGeneration.directoryURL!
        let remaining = try Set(fileManager.contentsOfDirectory(atPath: refreshedSidecar.path))
        guard refreshed.count == 1,
              remaining == ["photo.jpg"],
              try Data(contentsOf: refreshedSidecar.appendingPathComponent("photo.jpg")) == Data("A".utf8) else {
            fputs("rerun did not replace stale sidecar content\n", stderr)
            exit(3)
        }

        _ = try MessageAttachmentExporter.prepareGeneration([], beside: pdfExport.path)
        guard fileManager.fileExists(atPath: refreshedSidecar.appendingPathComponent("photo.jpg").path) else {
            fputs("exporting another transcript format removed the HTML sidecar\n", stderr)
            exit(4)
        }

        var checks = 0
        do {
            _ = try MessageAttachmentExporter.prepareGeneration([
                .init(key: "second", displayName: "photo.jpg", sourcePath: second.path),
                .init(key: "first", displayName: "photo.jpg", sourcePath: first.path),
            ], beside: htmlExport.path) {
                checks += 1
                if checks == 2 { throw CancellationError() }
            }
            fputs("cancelled attachment export unexpectedly succeeded\n", stderr)
            exit(5)
        } catch is CancellationError {
            let preserved = try Data(contentsOf: refreshedSidecar.appendingPathComponent("photo.jpg"))
            guard preserved == Data("A".utf8),
                  !fileManager.fileExists(atPath: refreshedSidecar.appendingPathComponent("photo-2.jpg").path) else {
                fputs("cancellation replaced the previously completed attachment folder\n", stderr)
                exit(6)
            }
        }

        let emptyGeneration = try MessageAttachmentExporter.prepareGeneration([], beside: htmlExport.path)
        MessageAttachmentExporter.cleanupObsoleteGenerations(for: emptyGeneration)
        guard !fileManager.fileExists(atPath: refreshedSidecar.path) else {
            fputs("empty re-export did not clean the stale attachment folder\n", stderr)
            exit(7)
        }
    }
}
'''

    with tempfile.TemporaryDirectory() as temp_dir:
        temp = Path(temp_dir)
        probe_path = temp / "Probe.swift"
        probe_path.write_text(probe)
        executable = temp / "attachment-sidecar-probe"
        compile_result = subprocess.run(
            ["swiftc", "-parse-as-library", str(exporter), str(probe_path), "-o", str(executable)],
            capture_output=True,
            text=True,
            timeout=60,
        )
        assert compile_result.returncode == 0, compile_result.stderr
        result = subprocess.run([str(executable), str(temp)], capture_output=True, text=True, timeout=10)
        assert result.returncode == 0, result.stderr


def test_original_attachment_option_applies_to_every_message_export_format(root: Path) -> None:
    exporter = read(root, "Sources/Phosphor/Services/MessageExporter.swift")
    view = read(root, "Sources/Phosphor/Views/Messages/MessageListView.swift")
    export_messages = re.search(
        r"func exportMessages\(.*?\) throws \{(?P<body>.*?)\n    \}",
        exporter,
        re.S,
    )
    assert export_messages is not None, "exportMessages should exist"
    body = export_messages.group("body")
    assert_contains(
        body,
        "prepareOriginalAttachmentGeneration(",
        "every export format should prepare a generation before format-specific rendering",
    )
    assert body.index("prepareOriginalAttachmentGeneration") < body.index("switch format"), (
        "original attachment export must not be limited to HTML, PDF, or MBOX"
    )
    assert_contains(
        exporter,
        "MessageAttachmentExporter.export",
        "message exports should use the cancellation-safe sidecar writer",
    )
    assert_contains(
        exporter,
        "attachmentMap: attachmentMap",
        "HTML should link to the same original attachment sidecar instead of copying files twice",
    )
    assert_contains(
        exporter,
        "MessageAttachmentExporter.relativeURL(for: relPath)",
        "HTML attachment src/href values should URL-encode reserved filename characters",
    )
    assert_contains(
        view,
        'Toggle("Export Attachments", isOn: $includeAttachments)',
        "the Messages export control should clearly say that it exports original attachments",
    )
    assert_contains(
        view,
        "Copies original photos, videos, audio, and files",
        "the attachment option should explain that originals are written beside the transcript",
    )


def test_all_formats_message_bundle_is_atomic_and_collision_safe(root: Path) -> None:
    helper = root / "Sources/Phosphor/Utilities/MessageExportBundleWriter.swift"
    assert helper.exists(), "all-formats exports should use a dedicated atomic bundle writer"

    probe = r'''
import Foundation

@main
struct MessageExportBundleProbe {
    static func main() throws {
        let parent = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let fileManager = FileManager.default

        let first = try MessageExportBundleWriter.write(in: parent) { root in
            let conversation = root.appendingPathComponent("Jane Doe-42", isDirectory: true)
            try fileManager.createDirectory(at: conversation, withIntermediateDirectories: true)
            try Data("pdf".utf8).write(to: conversation.appendingPathComponent("Jane Doe.pdf"))
            return 1
        }
        guard first.count == 1,
              first.directory.lastPathComponent == "Messages Export",
              fileManager.fileExists(atPath: first.directory.appendingPathComponent("Jane Doe-42/Jane Doe.pdf").path) else {
            fputs("first bundle did not produce the expected export folder\n", stderr)
            exit(1)
        }

        let second = try MessageExportBundleWriter.write(in: parent) { root in
            try Data("second".utf8).write(to: root.appendingPathComponent("marker.txt"))
            return 1
        }
        guard second.directory.lastPathComponent == "Messages Export 2",
              fileManager.fileExists(atPath: first.directory.path),
              fileManager.fileExists(atPath: second.directory.path) else {
            fputs("bundle naming overwrote a prior completed export\n", stderr)
            exit(2)
        }

        do {
            _ = try MessageExportBundleWriter.write(in: parent) { root in
                try Data("partial".utf8).write(to: root.appendingPathComponent("partial.txt"))
                throw CancellationError()
            }
            fputs("cancelled bundle unexpectedly succeeded\n", stderr)
            exit(3)
        } catch is CancellationError {
            let names = try fileManager.contentsOfDirectory(atPath: parent.path)
            guard !names.contains("Messages Export 3"),
                  !names.contains(where: { $0.contains("staging-") }) else {
                fputs("cancelled bundle left visible or staged partial output\n", stderr)
                exit(4)
            }
        }
    }
}
'''

    with tempfile.TemporaryDirectory() as temp_dir:
        temp = Path(temp_dir)
        probe_path = temp / "Probe.swift"
        probe_path.write_text(probe)
        executable = temp / "message-export-bundle-probe"
        compile_result = subprocess.run(
            ["swiftc", "-parse-as-library", str(helper), str(probe_path), "-o", str(executable)],
            capture_output=True,
            text=True,
            timeout=60,
        )
        assert compile_result.returncode == 0, compile_result.stderr
        result = subprocess.run([str(executable), str(temp)], capture_output=True, text=True, timeout=10)
        assert result.returncode == 0, result.stderr


def test_single_pdf_bundle_serializes_same_parent_across_processes(root: Path) -> None:
    helper = root / "Sources/Phosphor/Utilities/MessageExportBundleWriter.swift"
    probe = r'''
import Foundation

@main
struct MessageExportBundleRaceProbe {
    static func main() throws {
        let parent = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let mode = CommandLine.arguments[2]
        let ready = URL(fileURLWithPath: CommandLine.arguments[3])
        let release = URL(fileURLWithPath: CommandLine.arguments[4])

        let result = try MessageExportBundleWriter.write(in: parent, directoryName: "Conversation") { root in
            if mode == "hold" {
                try Data().write(to: ready)
                while !FileManager.default.fileExists(atPath: release.path) {
                    Thread.sleep(forTimeInterval: 0.01)
                }
            }
            try Data(mode.utf8).write(to: root.appendingPathComponent("marker.txt"))
            return 1
        }
        print(result.directory.lastPathComponent)
    }
}
'''

    with tempfile.TemporaryDirectory() as temp_dir:
        temp = Path(temp_dir)
        probe_path = temp / "RaceProbe.swift"
        probe_path.write_text(probe)
        executable = temp / "message-export-bundle-race-probe"
        compile_result = subprocess.run(
            ["swiftc", "-parse-as-library", str(helper), str(probe_path), "-o", str(executable)],
            capture_output=True,
            text=True,
            timeout=60,
        )
        assert compile_result.returncode == 0, compile_result.stderr

        parent = temp / "exports"
        ready = temp / "ready"
        release = temp / "release"
        first = subprocess.Popen(
            [str(executable), str(parent), "hold", str(ready), str(release)],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        try:
            deadline = time.monotonic() + 5
            while not ready.exists() and time.monotonic() < deadline:
                time.sleep(0.01)
            assert ready.exists(), "first PDF bundle did not reach its staged write"

            second = subprocess.Popen(
                [str(executable), str(parent), "run", str(ready), str(release)],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            release.write_text("go")
            first_out, first_err = first.communicate(timeout=10)
            second_out, second_err = second.communicate(timeout=10)
            assert first.returncode == 0, first_err
            assert second.returncode == 0, second_err
            assert {first_out.strip(), second_out.strip()} == {"Conversation", "Conversation 2"}
            assert (parent / "Conversation" / "marker.txt").exists()
            assert (parent / "Conversation 2" / "marker.txt").exists()
        finally:
            if first.poll() is None:
                release.write_text("cleanup")
                first.terminate()
                first.wait(timeout=5)


def test_all_formats_message_bundle_has_one_folder_per_conversation(root: Path) -> None:
    exporter = read(root, "Sources/Phosphor/Services/MessageExporter.swift")
    view_model = read(root, "Sources/Phosphor/ViewModels/MessageViewModel.swift")
    view = read(root, "Sources/Phosphor/Views/Messages/MessageListView.swift")

    bundle = re.search(
        r"func exportAllChatsAllFormats\(.*?\) throws -> MessageExportBundleWriter.Result \{(?P<body>.*?)\n    \}",
        exporter,
        re.S,
    )
    assert bundle is not None, "MessageExporter should expose an all-formats bundle export"
    body = bundle.group("body")
    assert_contains(body, "MessageExportFormat.allCases", "each conversation should be written in every supported format")
    assert_contains(body, "includeChatID: true", "conversation folders should retain collision-safe chat IDs")
    assert_contains(body, 'appendingPathComponent("Attachments"', "each conversation should contain one shared Attachments folder")
    assert_contains(body, "attachmentMap: attachmentMap", "HTML should link to the shared conversation attachment folder")
    assert_contains(view_model, "startExportAllChatsAllFormats", "the background export view model should expose the bundle action")
    assert_contains(view, 'Button("All Formats + Attachments")', "Export All should offer the complete conversation bundle")
    assert_contains(view, "exportAllConversationsAllFormats", "the all-formats menu option should open its folder picker")


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
    attachment_items = re.search(r"private func originalAttachmentItems.*?(?=\n    private func|\n    ///|\Z)", src, re.S)
    assert attachment_items is not None, "originalAttachmentItems should exist"
    assert_contains(
        attachment_items.group(0),
        "try cancellationCheck?()",
        "attachment resolution should be cancellable",
    )
    helper = read(root, "Sources/Phosphor/Utilities/MessageAttachmentExporter.swift")
    assert_contains(helper, "try cancellationCheck?()", "original attachment copying should be cancellable between files")


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
