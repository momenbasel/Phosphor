import SwiftUI
import WebKit

/// Browse and export Apple Notes from backup NoteStore.sqlite.
struct NotesView: View {

    @EnvironmentObject var backupVM: BackupViewModel
    @State private var folders: [NotesExtractor.NoteFolder] = []
    @State private var notes: [NotesExtractor.Note] = []
    @State private var selectedNote: NotesExtractor.Note?
    @State private var selectedFolder: NotesExtractor.NoteFolder?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var searchText = ""

    var body: some View {
        HSplitView {
            noteListPane
                .frame(minWidth: 260, idealWidth: 300, maxWidth: 400)
            noteDetailPane
        }
        .onAppear(perform: load)
    }

    // MARK: - Note List

    private var noteListPane: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Notes")
                    .font(.headline)
                Spacer()
                if !notes.isEmpty {
                    Text("\(notes.count) notes")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            // Folder filter
            if !folders.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        folderChip(nil, label: "All")
                        ForEach(folders) { folder in
                            folderChip(folder, label: folder.displayName)
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .padding(.bottom, 8)
            }

            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.tertiary)
                TextField("Search notes...", text: $searchText)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.quaternary)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 16)
            .padding(.bottom, 8)

            Divider()

            if isLoading {
                LoadingOverlay(message: "Loading notes...")
            } else if let error = errorMessage {
                EmptyStateView(icon: "note.text", title: "Notes Unavailable", subtitle: error)
            } else if notes.isEmpty {
                EmptyStateView(
                    icon: "note.text",
                    title: backupVM.selectedBackup == nil ? "No Backup Selected" : "No Notes Found",
                    subtitle: "Select a backup to browse Apple Notes."
                )
            } else {
                List(filteredNotes, selection: $selectedNote) { note in
                    noteRow(note).tag(note)
                }
                .listStyle(.inset)
            }
        }
    }

    private func folderChip(_ folder: NotesExtractor.NoteFolder?, label: String) -> some View {
        let isSelected = (folder == nil && selectedFolder == nil) || (folder?.id == selectedFolder?.id)
        return Button {
            selectedFolder = folder
            filterByFolder()
        } label: {
            Text(label)
                .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(isSelected ? Color.indigo.opacity(0.2) : Color(.controlBackgroundColor))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var filteredNotes: [NotesExtractor.Note] {
        var result = notes
        if !searchText.isEmpty {
            let q = searchText.lowercased()
            result = result.filter {
                $0.title.lowercased().contains(q) || $0.snippet.lowercased().contains(q)
            }
        }
        return result
    }

    private func noteRow(_ note: NotesExtractor.Note) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                if note.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                }
                Text(note.displayTitle)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                if note.isLocked {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            Text(note.snippet)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(2)
            HStack {
                Text(note.folderName)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Spacer()
                Text(note.formattedModifiedDate)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Detail

    private var noteDetailPane: some View {
        VStack(spacing: 0) {
            if let note = selectedNote {
                HStack {
                    Text(note.displayTitle)
                        .font(.headline)
                    Spacer()
                    Button("Export...") { exportNote(note) }
                        .buttonStyle(.bordered)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                Divider()

                if let html = note.htmlBody {
                    NoteHTMLView(html: html)
                } else {
                    ScrollView {
                        Text(note.snippet)
                            .font(.system(size: 14))
                            .padding(16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            } else {
                EmptyStateView(
                    icon: "doc.text",
                    title: "Select a Note",
                    subtitle: "Choose a note from the list to view its contents."
                )
            }
        }
    }

    // MARK: - Actions

    private func load() {
        guard let backup = backupVM.selectedBackup else { return }
        isLoading = true
        errorMessage = nil
        do {
            let ext = try NotesExtractor(backupPath: backup.path)
            folders = try ext.getFolders()
            notes = try ext.getNotes()
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func filterByFolder() {
        guard let backup = backupVM.selectedBackup else { return }
        do {
            let ext = try NotesExtractor(backupPath: backup.path)
            notes = try ext.getNotes(folderId: selectedFolder?.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func exportNote(_ note: NotesExtractor.Note) {
        let panel = NSSavePanel()
        let ext = note.htmlBody != nil ? "html" : "txt"
        panel.nameFieldStringValue = "\(note.displayTitle).\(ext)"
        guard panel.runModal() == .OK, let url = panel.url,
              let backup = backupVM.selectedBackup else { return }
        do {
            let extractor = try NotesExtractor(backupPath: backup.path)
            try extractor.exportNote(note, to: url.path)
        } catch {}
    }
}

/// WKWebView wrapper for rendering note HTML content.
struct NoteHTMLView: NSViewRepresentable {
    let html: String

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.preferences.isElementFullscreenEnabled = false
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let styledHTML = """
        <html><head><style>
        body { font-family: -apple-system, system-ui; font-size: 14px; padding: 16px;
               color: #f5f5f7; background: transparent; line-height: 1.6; }
        a { color: #5856D6; }
        @media (prefers-color-scheme: light) { body { color: #1d1d1f; } }
        </style></head><body>\(html)</body></html>
        """
        webView.loadHTMLString(styledHTML, baseURL: nil)
    }
}
