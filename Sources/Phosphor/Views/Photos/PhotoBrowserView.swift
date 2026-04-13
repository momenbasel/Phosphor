import SwiftUI

/// Browse and extract photos/videos from backup Camera Roll OR directly from connected device.
struct PhotoBrowserView: View {

    @EnvironmentObject var deviceVM: DeviceViewModel
    @EnvironmentObject var backupVM: BackupViewModel
    @StateObject private var photoVM = PhotoViewModel()
    @StateObject private var liveBrowser = LiveDeviceBrowser()
    @State private var selectedItems: Set<String> = []
    @State private var filterType: MediaItem.MediaType?
    @State private var viewMode: ViewMode = .grid
    @State private var sourceMode: SourceMode = .device

    enum ViewMode { case grid, list }
    enum SourceMode: String, CaseIterable {
        case device = "From Device"
        case backup = "From Backup"
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()

            switch sourceMode {
            case .device:
                devicePhotoView
            case .backup:
                backupPhotoView
            }
        }
        .onAppear {
            // Auto-mount device if connected
            if deviceVM.selectedDevice != nil && !liveBrowser.isMounted {
                Task {
                    if let udid = deviceVM.selectedDevice?.id {
                        let ok = await liveBrowser.mount(udid: udid)
                        if ok { await liveBrowser.scanPhotos() }
                    }
                }
            }
            // Also load backup photos if available
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

                if sourceMode == .device {
                    Text("\(liveBrowser.photos.count) items on device")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    let stats = photoVM.stats
                    if stats.photos > 0 || stats.videos > 0 {
                        Text("\(stats.photos) photos, \(stats.videos) videos - \(stats.totalSize.formattedFileSize)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()

            // Source toggle
            Picker("Source", selection: $sourceMode) {
                ForEach(SourceMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 220)

            // View mode toggle
            Picker("View", selection: $viewMode) {
                Image(systemName: "square.grid.2x2").tag(ViewMode.grid)
                Image(systemName: "list.bullet").tag(ViewMode.list)
            }
            .pickerStyle(.segmented)
            .frame(width: 72)

            // Extract button
            Button {
                if sourceMode == .device {
                    extractFromDevice()
                } else {
                    extractFromBackup()
                }
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

    // MARK: - Device Photos (Live)

    private var devicePhotoView: some View {
        Group {
            if liveBrowser.isLoading {
                LoadingOverlay(message: "Scanning Camera Roll from device...")
            } else if !liveBrowser.isMounted {
                EmptyStateView(
                    icon: "photo.on.rectangle.angled",
                    title: deviceVM.selectedDevice == nil ? "No Device Connected" : "Device Not Mounted",
                    subtitle: "Connect your device via USB to browse photos directly without a backup. Requires ifuse (brew install ifuse).",
                    action: {
                        guard let udid = deviceVM.selectedDevice?.id else { return }
                        Task {
                            let ok = await liveBrowser.mount(udid: udid)
                            if ok { await liveBrowser.scanPhotos() }
                        }
                    },
                    actionLabel: deviceVM.selectedDevice != nil ? "Mount Device" : nil
                )
            } else if liveBrowser.photos.isEmpty {
                EmptyStateView(
                    icon: "photo.on.rectangle.angled",
                    title: "No Photos Found",
                    subtitle: "DCIM folder is empty or inaccessible.",
                    action: {
                        Task { await liveBrowser.scanPhotos() }
                    },
                    actionLabel: "Scan Again"
                )
            } else {
                switch viewMode {
                case .grid: liveGridView
                case .list: liveListView
                }
            }
        }
    }

    private var liveGridView: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120, maximum: 160), spacing: 8)], spacing: 8) {
                ForEach(liveBrowser.photos) { photo in
                    livePhotoCell(photo)
                }
            }
            .padding(16)
        }
    }

    private func livePhotoCell(_ photo: LiveDeviceBrowser.LivePhoto) -> some View {
        VStack(spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(.controlBackgroundColor))
                    .frame(height: 100)

                // Try to load actual thumbnail
                if let nsImage = NSImage(contentsOfFile: photo.path) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(height: 100)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    Image(systemName: photo.sfSymbol)
                        .font(.system(size: 28))
                        .foregroundStyle(.tertiary)
                }

                if selectedItems.contains(photo.id) {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.indigo, lineWidth: 3)
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.indigo)
                        .background(Circle().fill(.white).padding(2))
                        .position(x: 20, y: 20)
                }

                if photo.isVideo {
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            Image(systemName: "play.fill")
                                .font(.system(size: 8))
                            Text(photo.sizeString)
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
            .onTapGesture { toggleSelection(photo.id) }

            Text(photo.name)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var liveListView: some View {
        List(liveBrowser.photos) { photo in
            HStack(spacing: 10) {
                // Thumbnail
                if let nsImage = NSImage(contentsOfFile: photo.path) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 40, height: 40)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                } else {
                    Image(systemName: photo.sfSymbol)
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .frame(width: 40, height: 40)
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(photo.name)
                        .font(.system(size: 13))
                        .lineLimit(1)
                    if let date = photo.modified {
                        Text(date.shortString)
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                }

                Spacer()

                Text(photo.sizeString)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
        }
        .listStyle(.inset)
    }

    // MARK: - Backup Photos

    private var backupPhotoView: some View {
        Group {
            if photoVM.isLoading {
                LoadingOverlay(message: "Scanning Camera Roll from backup...")
            } else if backupVM.selectedBackup == nil && backupVM.backups.isEmpty {
                EmptyStateView(
                    icon: "photo.on.rectangle.angled",
                    title: "No Backup Available",
                    subtitle: "Create a backup first, or switch to 'From Device' to browse photos directly.",
                    action: nil, actionLabel: nil
                )
            } else if backupVM.selectedBackup == nil {
                EmptyStateView(
                    icon: "photo.on.rectangle.angled",
                    title: "No Backup Selected",
                    subtitle: "Go to Backups, select a backup, then return here.",
                    action: {
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
                    title: "No Photos in Backup",
                    subtitle: "This backup doesn't contain Camera Roll photos, or it may be encrypted."
                )
            } else {
                switch viewMode {
                case .grid: backupGridView
                case .list: backupListView
                }
            }
        }
    }

    private var backupGridView: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120, maximum: 160), spacing: 8)], spacing: 8) {
                ForEach(displayedItems) { item in
                    backupGridCell(item)
                }
            }
            .padding(16)
        }
    }

    private func backupGridCell(_ item: MediaItem) -> some View {
        VStack(spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(.controlBackgroundColor))
                    .frame(height: 100)
                Image(systemName: item.mediaType.sfSymbol)
                    .font(.system(size: 28))
                    .foregroundStyle(.tertiary)
                if selectedItems.contains(item.id) {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.indigo, lineWidth: 3)
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.indigo)
                        .background(Circle().fill(.white).padding(2))
                        .position(x: 20, y: 20)
                }
            }
            .frame(height: 100)
            .onTapGesture { toggleSelection(item.id) }

            Text(item.filename)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var backupListView: some View {
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
        guard let filter = filterType else { return photoVM.items }
        return photoVM.items.filter { $0.mediaType == filter }
    }

    private func toggleSelection(_ id: String) {
        if selectedItems.contains(id) {
            selectedItems.remove(id)
        } else {
            selectedItems.insert(id)
        }
    }

    private func extractFromDevice() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Extract Here"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let photosToExtract: [LiveDeviceBrowser.LivePhoto]
        if selectedItems.isEmpty {
            photosToExtract = liveBrowser.photos
        } else {
            photosToExtract = liveBrowser.photos.filter { selectedItems.contains($0.id) }
        }

        let count = liveBrowser.exportPhotos(photosToExtract, to: url.path)
        if count > 0 { NSWorkspace.shared.open(url) }
    }

    private func extractFromBackup() {
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
            if count > 0 { NSWorkspace.shared.open(url) }
        }
    }
}
