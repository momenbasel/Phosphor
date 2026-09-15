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


def test_whatsapp_personal_and_business_sources_are_deterministic_and_selectable(root: Path) -> None:
    manifest = read(root, "Sources/Phosphor/Utilities/BackupManifest.swift")
    exporter = read(root, "Sources/Phosphor/Services/WhatsAppExporter.swift")
    view_model = read(root, "Sources/Phosphor/ViewModels/WhatsAppViewModel.swift")
    view = read(root, "Sources/Phosphor/Views/WhatsApp/WhatsAppView.swift")

    assert_contains(manifest, "enum WhatsAppSource", "Backup discovery needs explicit Personal and Business WhatsApp sources")
    assert_contains(manifest, "func whatsAppDatabases()", "Backup discovery must return every supported WhatsApp database")
    assert_contains(manifest, "ORDER BY", "WhatsApp source discovery must have a deterministic order")
    assert_contains(manifest, "net.whatsapp.WhatsAppSMB", "WhatsApp Business must be discovered explicitly")
    assert_contains(manifest, "relativePath = 'ChatStorage.sqlite'", "Root database name must match exactly")
    assert_contains(manifest, "relativePath LIKE '%/ChatStorage.sqlite'", "Nested database basename must match exactly")
    assert "relativePath LIKE '%ChatStorage.sqlite'" not in manifest, (
        "database discovery must reject decoy names such as OldChatStorage.sqlite"
    )
    assert "domain LIKE '%whatsapp%'" not in manifest, "Discovery must not select an arbitrary ChatStorage.sqlite by broad domain match"

    assert_contains(exporter, "source: BackupManifest.WhatsAppSource", "WhatsApp exporter must open the requested source")
    assert_contains(exporter, "private let source", "Media resolution must retain the selected WhatsApp source")
    assert_contains(exporter, "selectedSource.domains.contains($0.domain)", "Attachments must never cross Personal and Business domains")
    assert "manifest.search(\"ChatStorage.sqlite\")" not in exporter, "Fallback search must not select an unrelated ChatStorage.sqlite"

    assert_contains(view_model, "@Published private(set) var availableSources", "The view model must publish every discovered WhatsApp source")
    assert_contains(view_model, "@Published private(set) var selectedSource", "The view model must retain the selected WhatsApp source")
    assert_contains(view_model, "func selectSource", "Switching a source must reload chats from that source")
    assert_contains(view_model, "sourceChanged", "Changing WhatsApp source must cancel and invalidate any export from the previous source")
    assert_contains(view_model, "WhatsAppExporter(backupPath: backupPath, source: source)", "Browse and export must bind to the selected source")

    assert_contains(view, "whatsAppVM.availableSources.count > 1", "UI source selection should only appear when both sources exist")
    assert_contains(view, "Picker(\"WhatsApp\", selection:", "UI needs an explicit WhatsApp source picker")
    assert_contains(view, "source.displayName", "UI must label Personal and Business sources explicitly")
    assert_contains(view, ".onChange(of: whatsAppVM.selectedSource)", "Switching accounts must clear stale search filters")