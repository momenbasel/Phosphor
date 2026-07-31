import SwiftUI
import AppKit
import Quartz

/// Inspector pane that previews the selected backup file without extracting it
/// to a user folder first. Preview strategy by kind:
/// - Images/PDF/video/audio/text: Quick Look (QLPreviewView) over a readable
///   (decrypted) path.
/// - .plist: parsed key/value outline.
/// - .sqlite/.db: table list + first rows of the selected table.
/// - Fallback: metadata card (domain, path, fileID, size, flags).
struct FilePreviewPane: View {

    let entry: BackupManifest.FileEntry
    let manifest: BackupManifest

    @State private var quickLookURL: URL?
    @State private var plistObject: Any?
    @State private var sqliteSummary: SQLiteSummary?
    @State private var loadError: String?
    @State private var isLoading = true

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(minWidth: 260, idealWidth: 320)
        .task(id: entry.id) { loadPreview() }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.fileName)
                    .font(.headline)
                    .lineLimit(1)
                Text(entry.relativePath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button("Extract…") { extract() }
                .disabled(!entry.isFile)
        }
        .padding(12)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if isLoading {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let loadError {
            metadataCard(errorNote: loadError)
        } else if let url = quickLookURL {
            QuickLookView(url: url)
        } else if let plistObject {
            PlistOutlineView(object: plistObject)
        } else if let summary = sqliteSummary {
            sqliteView(summary)
        } else {
            metadataCard(errorNote: nil)
        }
    }

    private func metadataCard(errorNote: String?) -> some View {
        Form {
            LabeledContent("Name", value: entry.fileName)
            LabeledContent("Path", value: entry.relativePath)
            LabeledContent("Domain", value: entry.domain)
            LabeledContent("File ID", value: entry.id)
            LabeledContent("Kind", value: entry.isDirectory ? "Folder" : entry.isFile ? "File" : "Symlink")
            if entry.size > 0 {
                LabeledContent("Size", value: entry.size.formattedFileSize)
            }
            if let errorNote {
                Text(errorNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - SQLite preview

    struct SQLiteSummary {
        let tables: [String]
        var selectedTable: String?
        var columns: [String] = []
        var rows: [[String: Any?]] = []
    }

    private func sqliteView(_ summary: SQLiteSummary) -> some View {
        VStack(spacing: 0) {
            Picker("Table", selection: Binding(
                get: { summary.selectedTable ?? summary.tables.first ?? "" },
                set: { loadTable($0) }
            )) {
                ForEach(summary.tables, id: \.self) { Text($0).tag($0) }
            }
            .padding(10)

            // Dynamic column sets are not supported by SwiftUI Table; render
            // rows as key=value cards instead.
            List(summary.rows.indices, id: \.self) { index in
                let row = summary.rows[index]
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(summary.columns, id: \.self) { column in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(column)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                                .frame(minWidth: 90, alignment: .trailing)
                            Text(stringValue(row[column] ?? nil))
                                .font(.caption)
                                .lineLimit(2)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            .listStyle(.inset)
        }
    }

    private func stringValue(_ value: Any?) -> String {
        switch value {
        case nil: return "—"
        case let s as String: return s
        case let n as NSNumber: return n.stringValue
        case let d as Data: return "<\(d.count) bytes>"
        default: return String(describing: value!)
        }
    }

    // MARK: - Loading

    private func loadPreview() {
        isLoading = true
        quickLookURL = nil
        plistObject = nil
        sqliteSummary = nil
        loadError = nil

        guard entry.isFile else {
            isLoading = false
            return
        }

        Task.detached(priority: .userInitiated) { [entry, manifest] in
            do {
                let path = try manifest.readablePath(for: entry)
                let url = URL(fileURLWithPath: path)
                let ext = entry.fileExtension

                await MainActor.run {
                    switch ext {
                    case "plist", "mobileconfig", "strings":
                        if let obj = (try? PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil))
                            ?? (try? PropertyListSerialization.propertyList(from: Data(contentsOf: url), options: [], format: nil)) {
                            plistObject = obj
                        } else {
                            quickLookURL = url // binary plist we couldn't parse: fall back to QL
                        }
                    case "sqlite", "sqlite3", "db", "sqlitedb":
                        sqliteSummary = loadSQLiteSummary(path: path)
                    default:
                        // QL handles images, PDFs, video, audio, text, office docs.
                        quickLookURL = url
                    }
                    isLoading = false
                }
            } catch {
                await MainActor.run {
                    loadError = error.localizedDescription
                    isLoading = false
                }
            }
        }
    }

    private func loadSQLiteSummary(path: String) -> SQLiteSummary? {
        guard let reader = try? SQLiteReader(path: path),
              let tables = try? reader.tableNames(), !tables.isEmpty else { return nil }
        var summary = SQLiteSummary(tables: tables, selectedTable: tables.first)
        if let first = tables.first {
            summary.columns = ((try? reader.columns(for: first)) ?? []).map(\.name)
            summary.rows = (try? reader.query("SELECT * FROM \"\(first)\" LIMIT 100")) ?? []
        }
        return summary
    }

    private func loadTable(_ table: String) {
        guard var summary = sqliteSummary,
              let path = quickLookURL?.path ?? cachedReadablePath else { return }
        guard let reader = try? SQLiteReader(path: path) else { return }
        summary.selectedTable = table
        summary.columns = ((try? reader.columns(for: table)) ?? []).map(\.name)
        summary.rows = (try? reader.query("SELECT * FROM \"\(table)\" LIMIT 100")) ?? []
        sqliteSummary = summary
    }

    /// The readable path materialized during load (sqlite previews keep the
    /// path alive for table switches).
    private var cachedReadablePath: String? {
        // QL URL doubles as the readable path for sqlite too when set; but we
        // only set quickLookURL for QL kinds, so resolve again cheaply.
        try? manifest.readablePath(for: entry)
    }

    // MARK: - Extract

    private func extract() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = entry.fileName
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try manifest.extractFile(entry, to: url.path)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            loadError = error.localizedDescription
        }
    }
}

// MARK: - Quick Look wrapper

/// NSViewRepresentable over QLPreviewView. Kept tiny: QLPreviewView resolves
/// the file's UTI itself and renders images/PDF/video/text.
struct QuickLookView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        QLPreviewView(frame: .zero, style: .normal) ?? QLPreviewView()
    }

    func updateNSView(_ nsView: QLPreviewView, context: Context) {
        nsView.previewItem = url as QLPreviewItem
    }
}

// MARK: - Plist outline

/// Simple recursive outline for parsed plist objects.
struct PlistOutlineView: View {
    let object: Any

    var body: some View {
        List {
            PlistNodeView(value: object, key: "Root")
        }
        .listStyle(.inset)
    }
}

/// Recursive node; a dedicated View type keeps the opaque return type from
/// self-referencing (which SwiftUI's @ViewBuilder cannot infer).
struct PlistNodeView: View {
    let value: Any
    let key: String

    var body: some View {
        if let dict = value as? [String: Any] {
            DisclosureGroup(key) {
                ForEach(dict.keys.sorted(), id: \.self) { childKey in
                    PlistNodeView(value: dict[childKey] as Any, key: childKey)
                }
            }
        } else if let array = value as? [Any] {
            DisclosureGroup("\(key) (\(array.count) items)") {
                ForEach(Array(array.enumerated()), id: \.offset) { index, element in
                    PlistNodeView(value: element, key: "[\(index)]")
                }
            }
        } else {
            LabeledContent(key, value: stringValue(value))
        }
    }

    private func stringValue(_ value: Any) -> String {
        switch value {
        case let s as String: return s
        case let n as NSNumber: return n.stringValue
        case let d as Data: return "<\(d.count) bytes>"
        case let date as Date: return date.description
        default: return String(describing: value)
        }
    }
}
