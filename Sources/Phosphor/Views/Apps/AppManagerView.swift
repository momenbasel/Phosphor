import SwiftUI

/// App management: list installed apps on device, browse app data in backups,
/// install/remove IPAs, extract app containers.
struct AppManagerView: View {

    @EnvironmentObject var deviceVM: DeviceViewModel
    @EnvironmentObject var backupVM: BackupViewModel
    @StateObject private var appVM = AppViewModel()
    @State private var activeTab: AppTab = .backup
    @State private var searchText = ""

    enum AppTab: String, CaseIterable {
        case device = "On Device"
        case backup = "In Backup"
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()

            switch activeTab {
            case .device:
                deviceAppList
            case .backup:
                backupAppList
            }
        }
        .onAppear(perform: loadApps)
        // The Apps screen stays mounted while the selected backup changes from
        // elsewhere (Backups, the Refresh Backups menu item). Without this the app
        // list goes stale and Extract Data silently does nothing.
        .onChange(of: backupVM.selectedBackup?.path) { _, _ in
            guard activeTab == .backup else { return }
            reloadBackupApps()
        }
        .onChange(of: deviceVM.selectedDevice?.id) { _, _ in
            guard activeTab == .device else { return }
            loadApps()
        }
        .alert("Apps", isPresented: $appVM.showAlert) {
            Button("OK") {}
        } message: {
            Text(appVM.alertMessage)
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 14) {
            GradientIconTile(systemName: "square.grid.2x2.fill", color: .indigo, size: 40, iconSize: 19)

            Text("Applications")
                .font(.title2.weight(.semibold))

            Spacer()

            Picker("Source", selection: $activeTab) {
                ForEach(AppTab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 240)

            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.tertiary)
                TextField("Search apps...", text: $appVM.searchQuery)
                    .textFieldStyle(.plain)
                    .frame(width: 160)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.quaternary)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            if activeTab == .backup {
                backupPicker
            }

            if activeTab == .device {
                Button {
                    installIPA()
                } label: {
                    Label("Install IPA", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .tint(.brandAccent)
                .disabled(deviceVM.selectedDevice == nil)
            }
        }
        .padding(20)
        .onChange(of: activeTab) { _, _ in loadApps() }
    }

    /// App data lives in a backup, not on the device, so the Apps screen needs its
    /// own way to pick one. Before this, the only way in was Backups -> Browse,
    /// which nothing in the UI told you about (issue #46).
    private var backupPicker: some View {
        Menu {
            ForEach(backupVM.backups) { backup in
                Button("\(backup.deviceIdentityLabel) • iOS \(backup.iosVersion) • \(backup.relativeDate)\(backup.isEncrypted ? " • Encrypted" : "")") {
                    selectBackup(backup)
                }
            }
            if !backupVM.backups.isEmpty { Divider() }
            Button("Choose Backup Folder...") { chooseBackupFolder() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "externaldrive.fill")
                    .foregroundStyle(.secondary)
                Text(backupVM.selectedBackup.map { "\($0.deviceIdentityLabel) • \($0.relativeDate)" } ?? "Choose Backup")
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
            }
            .font(.system(size: 11))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.quaternary)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Device Apps

    private var deviceAppList: some View {
        Group {
            if appVM.isLoading {
                LoadingOverlay(message: "Loading installed apps...")
            } else if appVM.installedApps.isEmpty {
                EmptyStateView(
                    icon: "square.grid.2x2",
                    title: "No Apps Found",
                    subtitle: "Connect a device and ensure ideviceinstaller is installed to browse apps.",
                    action: {
                        if let udid = deviceVM.selectedDevice?.id {
                            Task { await appVM.loadInstalledApps(udid: udid) }
                        }
                    },
                    actionLabel: "Retry"
                )
            } else {
                VStack(spacing: 0) {
                    // The device list cannot extract anything - app containers only
                    // exist in a backup. Say so here instead of leaving people
                    // hunting for a button that is on the other tab (issue #46).
                    HStack(spacing: 8) {
                        Image(systemName: "info.circle")
                            .foregroundStyle(.secondary)
                        Text("To extract an app's data, switch to In Backup. Extraction reads from a local backup, not from the device.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Go to In Backup") { activeTab = .backup }
                            .buttonStyle(.link)
                            .font(.system(size: 11))
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                    .background(.quaternary.opacity(0.4))

                    List(appVM.filteredInstalled) { app in
                        installedAppRow(app)
                    }
                    .listStyle(.inset)
                    .searchable(text: $appVM.searchQuery, prompt: "Filter apps")
                }
            }
        }
    }

    private func installedAppRow(_ app: InstalledApp) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(app.appType == .system ? Color.gray.opacity(0.1) : Color.brandAccent.opacity(0.1))
                    .frame(width: 36, height: 36)
                Image(systemName: app.appType == .system ? "gearshape.fill" : "app.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(app.appType == .system ? .gray : Color.brandAccent)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(app.displayName)
                    .font(.system(size: 13, weight: .medium))
                HStack(spacing: 6) {
                    Text(app.id)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    if !app.version.isEmpty {
                        Text("v\(app.version)")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            Spacer()

            if app.appType == .user {
                Menu {
                    Button("Uninstall", role: .destructive) {
                        guard let udid = deviceVM.selectedDevice?.id else { return }
                        Task { await appVM.uninstall(bundleId: app.id, udid: udid) }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .frame(width: 24)
            }
        }
        .padding(.vertical, 3)
    }

    // MARK: - Backup Apps

    private var backupAppList: some View {
        Group {
            if appVM.isLoading {
                LoadingOverlay(message: "Reading apps from backup...")
            } else if backupVM.backups.isEmpty {
                EmptyStateView(
                    icon: "archivebox",
                    title: "No Backups Found",
                    subtitle: "App data is extracted from a local backup. Create one in the Backups section, or point Phosphor at an existing backup folder.",
                    action: { chooseBackupFolder() },
                    actionLabel: "Choose Backup Folder..."
                )
            } else if backupVM.selectedBackup == nil {
                EmptyStateView(
                    icon: "archivebox",
                    title: "Choose a Backup",
                    subtitle: "Pick a backup to list the apps inside it. Each app row then gets an Extract Data button for its container.",
                    action: { if let latest = backupVM.backups.first { selectBackup(latest) } },
                    actionLabel: "Use Latest Backup"
                )
            } else if appVM.backupApps.isEmpty {
                EmptyStateView(
                    icon: "archivebox",
                    title: "No Apps in Backup",
                    subtitle: "This backup has no app containers in it. A backup taken with 'Encrypt local backup' off omits some app data.",
                    action: { reloadBackupApps() },
                    actionLabel: "Reload"
                )
            } else {
                List(appVM.filteredBackup) { app in
                    backupAppRow(app)
                }
                .listStyle(.inset)
                .searchable(text: $appVM.searchQuery, prompt: "Filter apps")
            }
        }
    }

    private func backupAppRow(_ app: AppBundle) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.purple.opacity(0.1))
                    .frame(width: 36, height: 36)
                Image(systemName: "app.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.purple)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(app.displayName)
                    .font(.system(size: 13, weight: .medium))
                Text(app.id)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if app.dataSize > 0 {
                Text(app.sizeString)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Button("Extract Data") {
                extractAppData(app)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.vertical, 3)
    }

    // MARK: - Actions

    private func loadApps() {
        switch activeTab {
        case .device:
            if let udid = deviceVM.selectedDevice?.id {
                Task { await appVM.loadInstalledApps(udid: udid) }
            }
        case .backup:
            if backupVM.backups.isEmpty { backupVM.loadBackups() }
            if backupVM.selectedBackup != nil {
                reloadBackupApps()
            } else if let latest = backupVM.backups.first {
                // Land on something usable instead of an empty screen that tells
                // the user to go somewhere else.
                selectBackup(latest)
            }
        }
    }

    private func selectBackup(_ backup: BackupInfo) {
        // openBackupBrowser returns false for a locked encrypted backup, having
        // raised the password sheet. The onChange on selectedBackup picks the app
        // list back up once the unlock succeeds.
        guard backupVM.openBackupBrowser(backup) else { return }
        reloadBackupApps()
    }

    private func reloadBackupApps() {
        guard let backup = backupVM.selectedBackup else {
            appVM.backupApps = []
            return
        }
        Task { await appVM.loadBackupApps(backupPath: backup.path) }
    }

    private func chooseBackupFolder() {
        let previous = backupVM.backups.map(\.path)
        backupVM.openExistingBackupFolder()
        guard backupVM.backups.map(\.path) != previous,
              let latest = backupVM.backups.first else { return }
        selectBackup(latest)
    }

    private func installIPA() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.init(filenameExtension: "ipa")!]
        panel.prompt = "Install"

        guard panel.runModal() == .OK,
              let url = panel.url,
              let udid = deviceVM.selectedDevice?.id else { return }

        Task { await appVM.installIPA(path: url.path, udid: udid) }
    }

    private func extractAppData(_ app: AppBundle) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Extract Here"

        guard panel.runModal() == .OK,
              let url = panel.url,
              let backup = backupVM.selectedBackup else { return }

        Task { await appVM.extractAppData(bundleId: app.id, backupPath: backup.path, to: url.path) }
    }
}
