import SwiftUI

/// Browse Safari bookmarks and history from backup.
struct SafariView: View {

    @EnvironmentObject var backupVM: BackupViewModel
    @State private var activeTab: SafariTab = .history
    @State private var bookmarks: [SafariExtractor.Bookmark] = []
    @State private var history: [SafariExtractor.HistoryItem] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var searchText = ""

    enum SafariTab: String, CaseIterable {
        case history = "History"
        case bookmarks = "Bookmarks"
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()

            if isLoading {
                LoadingOverlay(message: "Loading Safari data...")
            } else if let error = errorMessage {
                EmptyStateView(icon: "safari", title: "Safari Data Unavailable", subtitle: error)
            } else {
                switch activeTab {
                case .history: historyList
                case .bookmarks: bookmarkList
                }
            }
        }
        .onAppear(perform: load)
        .onChange(of: activeTab) { _, _ in load() }
    }

    private var headerBar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Safari")
                    .font(.title2.weight(.semibold))
                Text(activeTab == .history ? "\(history.count) history items" : "\(bookmarks.count) bookmarks")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Picker("Tab", selection: $activeTab) {
                ForEach(SafariTab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 220)

            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.tertiary)
                TextField("Search...", text: $searchText)
                    .textFieldStyle(.plain)
                    .frame(width: 160)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.quaternary)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            Button("Export...") { exportData() }
                .buttonStyle(.bordered)
        }
        .padding(20)
    }

    // MARK: - History

    private var historyList: some View {
        Group {
            if history.isEmpty {
                EmptyStateView(
                    icon: "clock",
                    title: backupVM.selectedBackup == nil ? "No Backup Selected" : "No History",
                    subtitle: "Select a backup to view Safari browsing history."
                )
            } else {
                List(filteredHistory) { item in
                    HStack(spacing: 10) {
                        Image(systemName: "globe")
                            .font(.system(size: 14))
                            .foregroundStyle(.blue)
                            .frame(width: 20)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.displayTitle)
                                .font(.system(size: 13, weight: .medium))
                                .lineLimit(1)
                            Text(item.url)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                        Spacer()

                        VStack(alignment: .trailing, spacing: 2) {
                            Text(item.formattedDate)
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                            if item.visitCount > 1 {
                                Text("\(item.visitCount) visits")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
                .listStyle(.inset)
            }
        }
    }

    private var filteredHistory: [SafariExtractor.HistoryItem] {
        guard !searchText.isEmpty else { return history }
        let q = searchText.lowercased()
        return history.filter {
            $0.title.lowercased().contains(q) || $0.url.lowercased().contains(q)
        }
    }

    // MARK: - Bookmarks

    private var bookmarkList: some View {
        Group {
            if bookmarks.isEmpty {
                EmptyStateView(
                    icon: "bookmark",
                    title: backupVM.selectedBackup == nil ? "No Backup Selected" : "No Bookmarks",
                    subtitle: "Select a backup to view Safari bookmarks."
                )
            } else {
                List(filteredBookmarks) { bm in
                    HStack(spacing: 10) {
                        Image(systemName: "bookmark.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(.orange)
                            .frame(width: 20)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(bm.displayTitle)
                                .font(.system(size: 13, weight: .medium))
                                .lineLimit(1)
                            Text(bm.url)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                        Spacer()

                        Text(bm.parentTitle)
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.quaternary)
                            .clipShape(Capsule())
                    }
                    .padding(.vertical, 2)
                }
                .listStyle(.inset)
            }
        }
    }

    private var filteredBookmarks: [SafariExtractor.Bookmark] {
        guard !searchText.isEmpty else { return bookmarks }
        let q = searchText.lowercased()
        return bookmarks.filter {
            $0.title.lowercased().contains(q) || $0.url.lowercased().contains(q)
        }
    }

    // MARK: - Actions

    private func load() {
        guard let backup = backupVM.selectedBackup else { return }
        guard backup.hasManifest else {
            errorMessage = BackupInfo.incompleteBackupMessage
            isLoading = false
            return
        }
        isLoading = true
        errorMessage = nil

        let ext = SafariExtractor(backupPath: backup.path)
        do {
            switch activeTab {
            case .history: history = try ext.getHistory()
            case .bookmarks: bookmarks = try ext.getBookmarks()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func exportData() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = activeTab == .history ? "safari-history.csv" : "safari-bookmarks.html"
        guard panel.runModal() == .OK, let url = panel.url,
              let backup = backupVM.selectedBackup else { return }

        let ext = SafariExtractor(backupPath: backup.path)
        do {
            if activeTab == .history {
                try ext.exportHistory(to: url.path)
            } else {
                try ext.exportBookmarks(to: url.path)
            }
        } catch {}
    }
}
