from __future__ import annotations

from pathlib import Path


def read(root: Path, rel: str) -> str:
    return (root / rel).read_text()


def assert_contains(text: str, needle: str, message: str) -> None:
    assert needle in text, message


def test_whatsapp_exports_match_messages_export_controls(root: Path) -> None:
    exporter = read(root, "Sources/Phosphor/Services/WhatsAppExporter.swift")
    view_model_path = root / "Sources/Phosphor/ViewModels/WhatsAppViewModel.swift"
    assert view_model_path.exists(), "WhatsApp exports need an app-owned view model"
    view_model = view_model_path.read_text()
    view = read(root, "Sources/Phosphor/Views/WhatsApp/WhatsAppView.swift")
    app = read(root, "Sources/Phosphor/App/PhosphorApp.swift")
    content = read(root, "Sources/Phosphor/Views/ContentView.swift")

    for contract in [
        "func exportChatPDFBundle(",
        "func exportAllChats(",
        "func exportAllChatsAllFormats(",
        "MessageExportOptions",
        "cancellationCheck:",
        "onProgress:",
        "MessageExportTransaction.write",
        "MessageExportBundleWriter.write",
        "MessageAttachmentExporter",
    ]:
        assert_contains(exporter, contract, f"WhatsApp exporter is missing Messages parity contract: {contract}")

    assert "case .mbox:\n            try exportTXT" not in exporter, "WhatsApp MBOX must be a real MBOX export"
    assert_contains(exporter, "multipart/mixed", "WhatsApp MBOX should embed available media as MIME attachments")
    assert_contains(exporter, "base64EncodedString", "WhatsApp MBOX media should be encoded for portable import")
    assert_contains(exporter, "includeChatID", "Bulk WhatsApp filenames need collision-safe chat-ID suffixes")
    bulk_start = exporter.index("func exportAllChats(")
    bulk_end = exporter.index("func exportAllChatsAllFormats(")
    assert_contains(
        exporter[bulk_start:bulk_end],
        "MessageExportBundleWriter.write",
        "Single-format bulk WhatsApp exports must publish one complete folder atomically",
    )
    assert "|| candidate.fileName == filename" not in exporter, (
        "WhatsApp media resolution must not select the first same-named file from another message"
    )
    assert_contains(exporter, "commonPathSuffixLength", "WhatsApp media resolution should disambiguate repeated filenames by path suffix")

    for contract in [
        "startExportChatPDFBundle(",
        "startExportChat(",
        "startExportAllChats(",
        "startExportAllChatsAllFormats(",
        "cancelExport()",
        "filteredMessages(",
        "@Published var exportResult",
    ]:
        assert_contains(view_model, contract, f"WhatsApp view model is missing Messages parity contract: {contract}")

    assert_contains(
        view,
        "guard backupVM.openBackupBrowser(backup) else { return }",
        "Locked or unreadable backups must wait for successful unlock before loading WhatsApp",
    )

    for contract in [
        "exportAllMenu",
        "backupPicker",
        "exportOptionsBar",
        "Export All Conversations As...",
        "All Formats + Attachments",
        "Choose Backup Folder",
        "visibleMessages: displayedMessages",
    ]:
        assert_contains(view, contract, f"WhatsApp UI is missing Messages export control: {contract}")

    assert_contains(app, "@StateObject private var whatsAppVM", "WhatsApp export state must survive navigation")
    assert_contains(app, ".environmentObject(whatsAppVM)", "WhatsApp view model must be app-owned")
    assert_contains(content, "if whatsAppVM.isExporting", "WhatsApp progress must remain visible outside its section")
    assert_contains(content, "whatsAppVM.cancelExport()", "Root WhatsApp progress needs the same cancel action as Messages")