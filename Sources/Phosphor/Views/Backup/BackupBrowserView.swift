import SwiftUI

/// File-system-like browser for iOS backup contents. Parses Manifest.db and displays
/// domains/files in a navigable tree.
struct BackupBrowserView: View {

    @EnvironmentObject var backupVM: BackupViewModel
    @State private var searchText = ""
    @State private var selectedFiles: Set<BackupManifest.FileEntry> = []
    @State private var showExportSheet = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                if let backup = backupVM.selectedBackup {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Backup Browser")
                            .font(.title2.weight(.semibold))
                        Text("\(backup.deviceName) - \(backup.dateString)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("Backup Browser")
                        .font(.title2.weight(.semibold))
                }

                Spacer()

                // Search
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search files...", text: $searchText)
                        .textFieldStyle(.plain)
                        .frame(width: 200)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.quaternary)
                .clipShape(RoundedRectangle(cornerRadius: 8))

                if !selectedFiles.isEmpty {
                    Button {
                        showExportSheet = true
                    } label: {
                        Label("Extract (\(selectedFiles.count))", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.indigo)
                }
            }
            .padding(20)

            Divider()

            if backupVM.selectedBackup == nil {
                EmptyStateView(
                    icon: "folder",
                    title: "No Backup Selected",
                    subtitle: "Select a backup from the Backups section to browse its contents."
                )
            } else if !searchText.isEmpty {
                searchResultsView
            } else if backupVM.currentDomain != nil {
                fileListView
            } else {
                domainListView
            }
        }
        .onChange(of: searchText) { _, newValue in
            backupVM.searchBackup(newValue)
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
            let count = backupVM.extractFiles(Array(selectedFiles), to: url.path)
            if count > 0 {
                NSWorkspace.shared.open(url)
                selectedFiles.removeAll()
            }
        }
    }

    // MARK: - Domain List

    private var domainListView: some View {
        List(backupVM.browserDomains, id: \.self, selection: Binding<String?>(
            get: { backupVM.currentDomain },
            set: { if let d = $0 { backupVM.browseDomain(d) } }
        )) { domain in
            HStack {
                Image(systemName: iconForDomain(domain))
                    .font(.system(size: 16))
                    .foregroundStyle(.indigo)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 2) {
                    Text(displayName(for: domain))
                        .font(.system(size: 13, weight: .medium))
                    Text(domain)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .onTapGesture {
                backupVM.browseDomain(domain)
            }
        }
        .listStyle(.inset)
    }

    // MARK: - File List

    private var fileListView: some View {
        VStack(spacing: 0) {
            // Breadcrumb
            HStack {
                Button {
                    backupVM.currentDomain = nil
                    backupVM.browserFiles = []
                } label: {
                    Label("Domains", systemImage: "chevron.left")
                        .font(.system(size: 12))
                }
                .buttonStyle(.borderless)

                Text("/")
                    .foregroundStyle(.tertiary)

                Text(backupVM.currentDomain ?? "")
                    .font(.system(size: 12, weight: .medium))

                Spacer()

                Text("\(backupVM.browserFiles.count) items")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            .background(.quaternary.opacity(0.5))

            Divider()

            List(backupVM.browserFiles, id: \.id, selection: $selectedFiles) { file in
                fileRow(file)
            }
            .listStyle(.inset)
        }
    }

    // MARK: - Search Results

    private var searchResultsView: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(backupVM.searchResults.count) results for \"\(searchText)\"")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            .background(.quaternary.opacity(0.5))

            Divider()

            List(backupVM.searchResults, id: \.id) { file in
                fileRow(file)
            }
            .listStyle(.inset)
        }
    }

    // MARK: - File Row

    private func fileRow(_ file: BackupManifest.FileEntry) -> some View {
        HStack(spacing: 10) {
            Image(systemName: file.isDirectory ? "folder.fill" : iconForExtension(file.fileExtension))
                .font(.system(size: 14))
                .foregroundStyle(file.isDirectory ? .blue : .secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 1) {
                Text(file.fileName)
                    .font(.system(size: 13))
                    .lineLimit(1)
                Text(file.relativePath)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Spacer()

            if file.isFile && file.size > 0 {
                Text(file.size.formattedFileSize)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Helpers

    private func iconForDomain(_ domain: String) -> String {
        if domain.contains("CameraRoll") { return "photo.on.rectangle" }
        if domain.contains("AppDomain") { return "app.badge" }
        if domain.contains("HomeDomain") { return "house" }
        if domain.contains("Keychain") { return "key.fill" }
        if domain.contains("Health") { return "heart.fill" }
        if domain.contains("Wireless") { return "wifi" }
        if domain.contains("System") { return "gearshape" }
        return "folder"
    }

    private func displayName(for domain: String) -> String {
        if domain.hasPrefix("AppDomain-") {
            return domain.replacingOccurrences(of: "AppDomain-", with: "")
        }
        if domain.hasPrefix("AppDomainGroup-") {
            return domain.replacingOccurrences(of: "AppDomainGroup-", with: "") + " (Group)"
        }
        return domain
    }

    private func iconForExtension(_ ext: String) -> String {
        switch ext {
        case "jpg", "jpeg", "png", "heic", "gif", "webp": return "photo"
        case "mp4", "mov", "m4v": return "video"
        case "mp3", "m4a", "aac": return "music.note"
        case "pdf": return "doc.richtext"
        case "sqlite", "db": return "cylinder"
        case "plist": return "list.bullet.rectangle"
        case "json": return "curlybraces"
        case "xml": return "chevron.left.forwardslash.chevron.right"
        default: return "doc"
        }
    }
}
