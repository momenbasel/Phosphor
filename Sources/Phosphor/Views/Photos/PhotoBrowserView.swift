import SwiftUI

/// Browse and extract photos/videos from backup Camera Roll.
struct PhotoBrowserView: View {

    @EnvironmentObject var backupVM: BackupViewModel
    @StateObject private var photoVM = PhotoViewModel()
    @State private var selectedItems: Set<String> = []
    @State private var filterType: MediaItem.MediaType?
    @State private var viewMode: ViewMode = .grid

    enum ViewMode {
        case grid, list
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()

            if photoVM.isLoading {
                LoadingOverlay(message: "Scanning Camera Roll...")
            } else if backupVM.selectedBackup == nil && backupVM.backups.isEmpty {
                EmptyStateView(
                    icon: "photo.on.rectangle.angled",
                    title: "No Backup Available",
                    subtitle: "Create a backup first from the Backups section. Photos are extracted from local device backups.",
                    action: nil,
                    actionLabel: nil
                )
            } else if backupVM.selectedBackup == nil {
                EmptyStateView(
                    icon: "photo.on.rectangle.angled",
                    title: "No Backup Selected",
                    subtitle: "Go to Backups, select a backup, then return here to browse photos.",
                    action: {
                        // Auto-select first backup
                        if let first = backupVM.backups.first {
                            backupVM.openBackupBrowser(first)
                            Task { await photoVM.loadPhotos(from: first.path) }
                        }
                    },
                    actionLabel: backupVM.backups.isEmpty ? nil : "Use Latest Backup"
                )
            } else if photoVM.items.isEmpty {
                EmptyStateView(
                    icon: "photo.on.rectangle.angled",
                    title: "No Photos Found",
                    subtitle: "This backup doesn't contain Camera Roll photos, or it may be encrypted."
                )
            } else {
                switch viewMode {
                case .grid:
                    gridView
                case .list:
                    listView
                }
            }
        }
        .onAppear {
            if let backup = backupVM.selectedBackup {
                Task { await photoVM.loadPhotos(from: backup.path) }
            }
        }
        .alert("Photos", isPresented: $photoVM.showAlert) {
            Button("OK") {}
        } message: {
            Text(photoVM.alertMessage)
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Photos & Videos")
                    .font(.title2.weight(.semibold))

                let stats = photoVM.stats
                if stats.photos > 0 || stats.videos > 0 {
                    Text("\(stats.photos) photos, \(stats.videos) videos - \(stats.totalSize.formattedFileSize)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            // Filter
            Picker("Filter", selection: $filterType) {
                Text("All").tag(nil as MediaItem.MediaType?)
                Text("Photos").tag(MediaItem.MediaType.photo as MediaItem.MediaType?)
                Text("Videos").tag(MediaItem.MediaType.video as MediaItem.MediaType?)
                Text("Screenshots").tag(MediaItem.MediaType.screenshot as MediaItem.MediaType?)
            }
            .pickerStyle(.segmented)
            .frame(width: 320)

            // View mode toggle
            Picker("View", selection: $viewMode) {
                Image(systemName: "square.grid.2x2").tag(ViewMode.grid)
                Image(systemName: "list.bullet").tag(ViewMode.list)
            }
            .pickerStyle(.segmented)
            .frame(width: 72)

            // Extract button
            Button {
                extractSelected()
            } label: {
                Label(
                    selectedItems.isEmpty ? "Extract All" : "Extract (\(selectedItems.count))",
                    systemImage: "square.and.arrow.down"
                )
            }
            .buttonStyle(.borderedProminent)
            .tint(.indigo)
        }
        .padding(20)
    }

    // MARK: - Grid

    private var gridView: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120, maximum: 160), spacing: 8)], spacing: 8) {
                ForEach(displayedItems) { item in
                    photoGridCell(item)
                }
            }
            .padding(16)
        }
    }

    private func photoGridCell(_ item: MediaItem) -> some View {
        VStack(spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(.controlBackgroundColor))
                    .frame(height: 100)

                Image(systemName: item.mediaType.sfSymbol)
                    .font(.system(size: 28))
                    .foregroundStyle(.tertiary)

                // Selection indicator
                if selectedItems.contains(item.id) {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.indigo, lineWidth: 3)
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.indigo)
                        .background(Circle().fill(.white).padding(2))
                        .position(x: 20, y: 20)
                }

                // Video duration badge
                if item.mediaType == .video {
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            Image(systemName: "play.fill")
                                .font(.system(size: 8))
                            Text(item.sizeString)
                                .font(.system(size: 9, weight: .medium))
                        }
                        .foregroundStyle(.white)
                        .padding(4)
                        .background(.black.opacity(0.6))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .padding(4)
                    }
                }
            }
            .frame(height: 100)
            .onTapGesture {
                toggleSelection(item.id)
            }

            Text(item.filename)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    // MARK: - List

    private var listView: some View {
        List(displayedItems, selection: $selectedItems) { item in
            HStack(spacing: 10) {
                Image(systemName: item.mediaType.sfSymbol)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 1) {
                    Text(item.filename)
                        .font(.system(size: 13))
                        .lineLimit(1)
                    Text(item.relativePath)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }

                Spacer()

                Text(item.sizeString)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
        }
        .listStyle(.inset)
    }

    // MARK: - Helpers

    private var displayedItems: [MediaItem] {
        let vm = photoVM
        guard let filter = filterType else { return vm.items }
        return vm.items.filter { $0.mediaType == filter }
    }

    private func toggleSelection(_ id: String) {
        if selectedItems.contains(id) {
            selectedItems.remove(id)
        } else {
            selectedItems.insert(id)
        }
    }

    private func extractSelected() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Extract Here"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        let itemsToExtract: [MediaItem]
        if selectedItems.isEmpty {
            itemsToExtract = displayedItems
        } else {
            itemsToExtract = displayedItems.filter { selectedItems.contains($0.id) }
        }

        guard backupVM.selectedBackup != nil else { return }

        Task {
            let count = await photoVM.extractSelected(itemsToExtract, to: url.path)
            if count > 0 {
                NSWorkspace.shared.open(url)
            }
        }
    }
}
