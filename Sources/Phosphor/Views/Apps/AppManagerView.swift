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
        .alert("Apps", isPresented: $appVM.showAlert) {
            Button("OK") {}
        } message: {
            Text(appVM.alertMessage)
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack {
            Text("Applications")
                .font(.title2.weight(.semibold))

            Spacer()

            Picker("Source", selection: $activeTab) {
                ForEach(AppTab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 240)

            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.tertiary)
                TextField("Search apps...", text: $searchText)
                    .textFieldStyle(.plain)
                    .frame(width: 160)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.quaternary)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            if activeTab == .device {
                Button {
                    installIPA()
                } label: {
                    Label("Install IPA", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .tint(.indigo)
                .disabled(deviceVM.selectedDevice == nil)
            }
        }
        .padding(20)
        .onChange(of: activeTab) { _, _ in loadApps() }
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
                List(appVM.filteredInstalled) { app in
                    installedAppRow(app)
                }
                .listStyle(.inset)
                .searchable(text: $appVM.searchQuery, prompt: "Filter apps")
            }
        }
    }

    private func installedAppRow(_ app: InstalledApp) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(app.appType == .system ? Color.gray.opacity(0.1) : Color.indigo.opacity(0.1))
                    .frame(width: 36, height: 36)
                Image(systemName: app.appType == .system ? "gearshape.fill" : "app.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(app.appType == .system ? .gray : .indigo)
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
            if appVM.backupApps.isEmpty {
                EmptyStateView(
                    icon: "archivebox",
                    title: "No Apps in Backup",
                    subtitle: "Select a backup from the Backups section to browse its installed applications."
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
            if let backup = backupVM.selectedBackup {
                appVM.loadBackupApps(backupPath: backup.path)
            }
        }
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

        let dest = (url.path as NSString).appendingPathComponent(app.id)
        Task { await appVM.extractAppData(bundleId: app.id, backupPath: backup.path, to: dest) }
    }
}
