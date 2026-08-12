import SwiftUI

/// Unified backup browser: backup picker on the left, domain-aware file table
/// in the middle, live preview inspector on the right. Replaces the old
/// domain-list -> flat-file-list two-step navigation.
struct BackupBrowserView: View {

    @EnvironmentObject var backupVM: BackupViewModel
    @State private var searchText = ""
    /// Selection by file ID (Table requires Set<Value.ID>).
    @State private var selectedFileIDs: Set<String> = []
    @State private var showExportSheet = false
    @State private var searchDebounceTask: Task<Void, Never>?
    @State private var sortOrder = [KeyPathComparator(\BackupManifest.FileEntry.relativePath)]
    /// Domains the user has expanded to browse; nil = show domain overview.
    @State private var showInspector = true

    var body: some View {
        NavigationSplitView {
            sidebarColumn
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 280)
        } detail: {
            detailColumn
        }
        .onChange(of: searchText) { _, newValue in
            searchDebounceTask?.cancel()
            let query = newValue
            searchDebounceTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 300_000_000)
                if Task.isCancelled { return }
                backupVM.searchBackup(query)
            }
        }
        .onChange(of: backupVM.selectedBackup?.id) { _, _ in
            selectedFileIDs.removeAll()
            searchText = ""
        }
        .onChange(of: backupVM.currentDomain) { _, _ in
            selectedFileIDs.removeAll()
        }
        .onChange(of: showExportSheet) { _, show in
            guard show else { return }
            showExportSheet = false
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = true
            panel.prompt = "Extract Here"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            let files = visibleFiles.filter { selectedFileIDs.contains($0.id) }
            let count = backupVM.extractFiles(files, to: url.path)
            if count > 0 {
                NSWorkspace.shared.open(url)
                selectedFileIDs.removeAll()
            }
        }
    }

    // MARK: - Left column: backups + domains

    private var sidebarColumn: some View {
        List(selection: Binding<String?>(
            get: { backupVM.currentDomain },
            set: { if let d = $0 { backupVM.browseDomain(d) } }
        )) {
            Section("Backups") {
                ForEach(backupVM.backups) { backup in
                    Label {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(backup.deviceIdentityLabel)
                                .font(.system(size: 12, weight: .medium))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(backup.dateString)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: backup.isEncrypted ? "lock.fill" : "externaldrive")
                            .foregroundStyle(backup.id == backupVM.selectedBackup?.id ? Color.brandAccent : .secondary)
                    }
                    .tag(Optional<String>.none) // not domain-selectable
                    .contentShape(Rectangle())
                    .onTapGesture {
                        backupVM.openBackupBrowser(backup)
                    }
                }
            }

            if backupVM.selectedBackup != nil {
                Section("Domains") {
                    ForEach(groupedDomains.keys.sorted(), id: \.self) { category in
                        DisclosureGroup(category) {
                            ForEach(groupedDomains[category] ?? [], id: \.self) { domain in
                                Label(displayName(for: domain), systemImage: iconForDomain(domain))
                                    .tag(domain)
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    /// Group domains into human categories: Apps, App Groups, System, and the
    /// pinned favorites (Camera Roll, Home, Media).
    private var groupedDomains: [String: [String]] {
        var groups: [String: [String]] = [:]
        var pinned: [String] = []
        var apps: [String] = []
        var appGroups: [String] = []
        var system: [String] = []

        for domain in backupVM.browserDomains {
            if domain.hasPrefix("AppDomainGroup-") {
                appGroups.append(domain)
            } else if domain.hasPrefix("AppDomain-") {
                apps.append(domain)
            } else if Self.pinnedDomains.contains(domain) {
                pinned.append(domain)
            } else {
                system.append(domain)
            }
        }
        if !pinned.isEmpty { groups["Favorites"] = pinned }
        if !apps.isEmpty { groups["Apps"] = apps }
        if !appGroups.isEmpty { groups["App Groups"] = appGroups }
        if !system.isEmpty { groups["System"] = system }
        return groups
    }

    private static let pinnedDomains = ["CameraRollDomain", "HomeDomain", "MediaDomain"]

    // MARK: - Detail column: breadcrumbs + table + inspector

    private var detailColumn: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showInspector.toggle()
                } label: {
                    Image(systemName: "sidebar.trailing")
                }
                .help("Toggle Preview")
            }
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Backup Browser")
                    .font(.title2.weight(.semibold))
                if let backup = backupVM.selectedBackup {
                    Text("\(backup.deviceIdentityLabel) — \(backup.dateString)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search files…", text: $searchText)
                    .textFieldStyle(.plain)
                    .frame(width: 220)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.quaternary)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            if selectedFileIDs.count > 1 {
                Button {
                    showExportSheet = true
                } label: {
                    Label("Extract (\(selectedFileIDs.count))", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.borderedProminent)
                .tint(.brandAccent)
            }
        }
        .padding(20)
    }

    @ViewBuilder
    private var content: some View {
        if backupVM.selectedBackup == nil {
            EmptyStateView(icon: "folder", title: "No Backup Selected",
                           subtitle: "Pick a backup on the left to browse its contents.")
        } else {
            HSplitView {
                tablePane
                    .frame(minWidth: 380)
                if showInspector,
                   selectedFileIDs.count == 1,
                   let selection = visibleFiles.first(where: { selectedFileIDs.contains($0.id) }),
                   let store = backupVM.queryStore {
                    FilePreviewPane(entry: selection, store: store)
                }
            }
        }
    }

    private var tablePane: some View {
        VStack(spacing: 0) {
            breadcrumbBar
            Divider()
            fileTable
        }
    }

    private var breadcrumbBar: some View {
        HStack(spacing: 4) {
            if backupVM.currentDomain != nil {
                Button {
                    backupVM.leaveDomain()
                } label: {
                    Label("Domains", systemImage: "chevron.left")
                        .font(.system(size: 12))
                }
                .buttonStyle(.borderless)
                Text("/").foregroundStyle(.tertiary)
                Text(displayName(for: backupVM.currentDomain ?? ""))
                    .font(.system(size: 12, weight: .medium))
            } else {
                Text("All Domains")
                    .font(.system(size: 12, weight: .medium))
            }
            Spacer()
            Text("\(visibleFiles.count) items")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.5))
    }

    /// Files shown in the table: search results while searching, current
    /// domain contents otherwise.
    private var visibleFiles: [BackupManifest.FileEntry] {
        searchText.isEmpty ? backupVM.browserFiles : backupVM.searchResults
    }

    private var fileTable: some View {
        Table(of: BackupManifest.FileEntry.self, selection: $selectedFileIDs, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.fileName) { file in
                HStack(spacing: 8) {
                    Image(systemName: file.isDirectory ? "folder.fill" : iconForExtension(file.fileExtension))
                        .foregroundStyle(file.isDirectory ? .blue : .secondary)
                        .frame(width: 18)
                    Text(file.fileName)
                        .lineLimit(1)
                }
            }
            .width(min: 140, ideal: 220)
            TableColumn("Size", value: \.size) { file in
                Text(file.size > 0 ? file.size.formattedFileSize : "—")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .width(70)
            TableColumn("Kind", value: \.fileExtension) { file in
                Text(file.isDirectory ? "Folder" : file.fileExtension.uppercased())
                    .foregroundStyle(.secondary)
            }
            .width(60)
            TableColumn("Path", value: \.relativePath) { file in
                Text(file.relativePath)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        } rows: {
            ForEach(visibleFiles.sorted(using: sortOrder)) { file in
                TableRow(file)
            }
        }
        .contextMenu(forSelectionType: String.self) { selection in
            if !selection.isEmpty {
                Button("Extract \(selection.count) item(s)…") {
                    selectedFileIDs = selection
                    showExportSheet = true
                }
            }
        }
    }

    // MARK: - Helpers

    private func iconForDomain(_ domain: String) -> String {
        if domain.hasPrefix("AppDomainGroup-") { return "square.grid.2x2" }
        if domain.hasPrefix("AppDomain-") { return "app" }
        switch domain {
        case "CameraRollDomain": return "photo.on.rectangle"
        case "HomeDomain": return "house"
        case "MediaDomain": return "music.note"
        case "SystemPreferencesDomain": return "gear"
        case "KeychainDomain": return "key"
        case "HealthDomain": return "heart"
        default: return "folder"
        }
    }

    private func displayName(for domain: String) -> String {
        if domain.hasPrefix("AppDomainGroup-") {
            return String(domain.dropFirst("AppDomainGroup-".count))
        }
        if domain.hasPrefix("AppDomain-") {
            return String(domain.dropFirst("AppDomain-".count))
        }
        return BackupManifest.Domain(rawValue: domain)?.displayName ?? domain
    }

    private func iconForExtension(_ ext: String) -> String {
        switch ext {
        case "jpg", "jpeg", "png", "heic", "gif", "tiff": return "photo"
        case "mov", "mp4", "m4v": return "film"
        case "mp3", "m4a", "aac", "wav": return "music.note"
        case "sqlite", "sqlite3", "db": return "cylinder"
        case "plist", "strings": return "doc.text"
        case "pdf": return "doc.richtext"
        case "zip", "gz", "tar": return "doc.zipper"
        default: return "doc"
        }
    }
}
