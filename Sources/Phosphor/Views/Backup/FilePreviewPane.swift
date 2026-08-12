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
    let store: ManifestQueryStore

    @State private var readablePath: String?
    @State private var quickLookURL: URL?
    @State private var plistObject: Any?
    @State private var sqlitePreview: SQLitePreview?
    @State private var loadError: String?
    @State private var isLoading = true
    @State private var tableLoadTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(minWidth: 260, idealWidth: 320)
        .task(id: entry.id) { await loadPreview() }
        .onDisappear { tableLoadTask?.cancel() }
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
        } else if let preview = sqlitePreview {
            sqliteView(preview)
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

    struct SQLitePreview: Sendable {
        let tables: [String]
        var selectedTable: String
        var columns: [String]
        var rows: [[String]]
    }

    private func sqliteView(_ preview: SQLitePreview) -> some View {
        VStack(spacing: 0) {
            Picker("Table", selection: Binding(
                get: { preview.selectedTable },
                set: { loadTable($0) }
            )) {
                ForEach(preview.tables, id: \.self) { Text($0).tag($0) }
            }
            .padding(10)

            // Dynamic column sets are not supported by SwiftUI Table; render
            // rows as key=value cards instead.
            List(preview.rows.indices, id: \.self) { index in
                let row = preview.rows[index]
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(preview.columns.enumerated()), id: \.offset) { columnIndex, column in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(column)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                                .frame(minWidth: 90, alignment: .trailing)
                            Text(columnIndex < row.count ? row[columnIndex] : "—")
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

    // MARK: - Loading

    @MainActor
    private func loadPreview() async {
        tableLoadTask?.cancel()
        isLoading = true
        readablePath = nil
        quickLookURL = nil
        plistObject = nil
        sqlitePreview = nil
        loadError = nil

        guard entry.isFile else {
            isLoading = false
            return
        }

        do {
            let path = try await store.readablePath(for: entry)
            try Task.checkCancellation()

            switch entry.fileExtension {
            case "plist", "mobileconfig", "strings":
                let parsed = await Self.parsePlist(atPath: path)
                guard !Task.isCancelled else { return }
                readablePath = path
                if let parsed {
                    plistObject = parsed
                } else {
                    quickLookURL = URL(fileURLWithPath: path)
                }
            case "sqlite", "sqlite3", "db", "sqlitedb":
                let preview = await Self.loadSQLitePreview(path: path, table: nil)
                guard !Task.isCancelled else { return }
                readablePath = path
                sqlitePreview = preview
            default:
                guard !Task.isCancelled else { return }
                readablePath = path
                quickLookURL = URL(fileURLWithPath: path)
            }
            isLoading = false
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            loadError = error.localizedDescription
            isLoading = false
        }
    }

    private func loadTable(_ table: String) {
        guard let path = readablePath else { return }
        let entryID = entry.id
        tableLoadTask?.cancel()
        tableLoadTask = Task { @MainActor in
            let preview = await Self.loadSQLitePreview(path: path, table: table)
            guard !Task.isCancelled, entry.id == entryID else { return }
            if let preview { sqlitePreview = preview }
        }
    }

    // MARK: - Off-main parsing helpers

    private static func parsePlist(atPath path: String) async -> Any? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, format: nil)
    }

    private static func loadSQLitePreview(path: String, table: String?) async -> SQLitePreview? {
        guard let reader = try? SQLiteReader(path: path),
              let tables = try? reader.tableNames(), !tables.isEmpty else { return nil }
        guard let selected = table ?? tables.first, tables.contains(selected) else { return nil }
        let columns = ((try? reader.columns(for: selected)) ?? []).map(\.name)
        let rawRows = (try? reader.query("SELECT * FROM \"\(selected)\" LIMIT 100")) ?? []
        let rows = rawRows.map { row in
            columns.map { renderValue(row[$0] ?? nil) }
        }
        return SQLitePreview(tables: tables, selectedTable: selected, columns: columns, rows: rows)
    }

    private static func renderValue(_ value: Any?) -> String {
        switch value {
        case nil: return "—"
        case let s as String: return s
        case let n as NSNumber: return n.stringValue
        case let d as Data: return "<\(d.count) bytes>"
        default: return String(describing: value!)
        }
    }

    // MARK: - Extract

    private func extract() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = entry.fileName
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let target = entry
        Task { @MainActor in
            do {
                try await store.extractFile(target, to: url.path)
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                loadError = error.localizedDescription
            }
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
