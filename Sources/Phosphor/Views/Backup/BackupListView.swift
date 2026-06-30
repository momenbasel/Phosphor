import SwiftUI

/// Lists all discovered iOS backups with metadata. Allows creating new backups and managing existing ones.
struct BackupListView: View {

    @EnvironmentObject var deviceVM: DeviceViewModel
    @EnvironmentObject var backupVM: BackupViewModel
    @State private var showDeleteConfirm = false
    @State private var backupToDelete: BackupInfo?
    @State private var backupPassword = ""
    @State private var showImportArchive = false
    @State private var archiveProgress: String?
    @State private var isArchiving = false
    @State private var showScheduleSheet = false
    @State private var showFullWiFiBackupConfirm = false
    @State private var pendingFullWiFiBackupUDID: String?
    @State private var pendingFullWiFiBackupPrefersNetwork = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Backups")
                        .font(.title2.weight(.semibold))
                    Text("\(backupVM.backups.count) backups - \(backupVM.totalSize) total")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                newBackupMenu
                .buttonStyle(.borderedProminent)
                .tint(.indigo)
                .disabled(backupVM.isCreating)

                Button {
                    backupVM.loadBackups()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .padding(20)

            Divider()

            if backupVM.isCreating {
                backupProgressView
            }

            if let err = backupVM.loadError, backupVM.backups.isEmpty {
                backupLoadErrorBanner(err)
            }

            if backupVM.backups.isEmpty {
                EmptyStateView(
                    icon: "externaldrive",
                    title: "No Backups Found",
                    subtitle: "Back up your device, or pick an existing backup folder via New Backup -> Open Existing Backup Folder.",
                    action: {
                        guard let device = deviceVM.selectedDevice else { return }
                        startBackup(for: device, incremental: device.connectionType == .wifi)
                    },
                    actionLabel: deviceVM.selectedDevice?.connectionType == .wifi ? "Create Incremental Wi-Fi Backup" : (deviceVM.selectedDevice != nil ? "Create Backup" : nil)
                )
            } else {
                List {
                    ForEach(backupVM.backups) { backup in
                        BackupRow(backup: backup) {
                            backupVM.openBackupBrowser(backup)
                        } onDelete: {
                            backupToDelete = backup
                            showDeleteConfirm = true
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .alert("Delete Backup?", isPresented: $showDeleteConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                if let backup = backupToDelete {
                    backupVM.deleteBackup(backup)
                }
            }
        } message: {
            if let backup = backupToDelete {
                Text("This will permanently delete the backup of \(backup.deviceName) (\(backup.sizeResolved ? backup.sizeString : "size calculating")). This cannot be undone.")
            }
        }
        .alert("Backup", isPresented: $backupVM.showAlert) {
            Button("OK") {}
        } message: {
            Text(backupVM.alertMessage)
        }
        .alert("Full Wi-Fi Backup?", isPresented: $showFullWiFiBackupConfirm) {
            Button("Run Full Wi-Fi Backup") {
                if let udid = pendingFullWiFiBackupUDID {
                    let preferNetwork = pendingFullWiFiBackupPrefersNetwork
                    Task { await backupVM.createBackup(udid: udid, incremental: false, preferNetwork: preferNetwork) }
                }
                pendingFullWiFiBackupUDID = nil
                pendingFullWiFiBackupPrefersNetwork = false
            }
            Button("Cancel", role: .cancel) {
                pendingFullWiFiBackupUDID = nil
                pendingFullWiFiBackupPrefersNetwork = false
            }
        } message: {
            Text("This device is connected over Wi-Fi. Full backups can be much slower and more sensitive to sleep/lock/network interruptions. Incremental Wi-Fi Backup is recommended unless you specifically need a full backup.")
        }
        .sheet(isPresented: $showScheduleSheet) {
            BackupScheduleSheet()
                .frame(width: 440, height: 400)
        }
        .sheet(isPresented: $backupVM.showPasswordPrompt) {
            EncryptedBackupUnlockSheet(password: $backupPassword) {
                let pwd = backupPassword
                backupPassword = ""
                Task { await backupVM.unlockBackup(password: pwd) }
            } onCancel: {
                backupPassword = ""
                backupVM.showPasswordPrompt = false
            }
        }
        .onAppear { backupVM.loadBackups() }
    }

    private var newBackupMenu: some View {
        Menu {
            backupCreationButtons

            Divider()

            Button {
                importPhosphorArchive()
            } label: {
                Label("Import .phosphor Archive", systemImage: "square.and.arrow.down")
            }

            Button {
                backupVM.openExistingBackupFolder()
            } label: {
                Label("Open Existing Backup Folder...", systemImage: "folder")
            }

            Divider()

            Button {
                showScheduleSheet = true
            } label: {
                Label("Schedule Backups...", systemImage: "clock")
            }
        } label: {
            Label("New Backup", systemImage: "plus")
        }
    }

    @ViewBuilder
    private var backupCreationButtons: some View {
        if deviceVM.selectedDevice?.connectionType == .wifi {
            Button {
                guard let device = deviceVM.selectedDevice else { return }
                startBackup(for: device, incremental: true)
            } label: {
                Label("Incremental Wi-Fi Backup (Recommended)", systemImage: "wifi")
            }
            .disabled(deviceVM.selectedDevice == nil)

            Button {
                guard let device = deviceVM.selectedDevice else { return }
                startBackup(for: device, incremental: false)
            } label: {
                Label("Full Wi-Fi Backup (Slower)", systemImage: "externaldrive.badge.plus")
            }
            .disabled(deviceVM.selectedDevice == nil)
        } else {
            Button {
                guard let device = deviceVM.selectedDevice else { return }
                startBackup(for: device, incremental: false)
            } label: {
                Label("Full USB Backup (Fastest)", systemImage: "externaldrive.badge.plus")
            }
            .disabled(deviceVM.selectedDevice == nil)

            Button {
                guard let device = deviceVM.selectedDevice else { return }
                startBackup(for: device, incremental: true)
            } label: {
                Label("Incremental Backup", systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(deviceVM.selectedDevice == nil)
        }
    }

    private func startBackup(for device: DeviceInfo, incremental: Bool) {
        if device.connectionType == .wifi && !incremental {
            pendingFullWiFiBackupUDID = device.id
            pendingFullWiFiBackupPrefersNetwork = true
            showFullWiFiBackupConfirm = true
            return
        }
        Task { await backupVM.createBackup(udid: device.id, incremental: incremental, preferNetwork: device.connectionType == .wifi) }
    }

    private func importPhosphorArchive() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.init(filenameExtension: BackupArchiver.fileExtension)].compactMap { $0 }
        panel.message = "Select a .phosphor backup archive to import"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        isArchiving = true
        archiveProgress = "Importing archive..."

        Task {
            let result = await BackupArchiver.importArchive(from: url.path) { progress in
                archiveProgress = progress
            }
            isArchiving = false
            archiveProgress = nil
            if result != nil {
                backupVM.loadBackups()
                backupVM.alertMessage = "Archive imported"
                backupVM.showAlert = true
            } else {
                backupVM.alertMessage = "Failed to import archive"
                backupVM.showAlert = true
            }
        }
    }

    private var backupProgressView: some View {
        HStack(spacing: 12) {
            ProgressView()
                .scaleEffect(0.8)
            Text(backupVM.progressText)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Color.indigo.opacity(0.06))
    }

    @ViewBuilder
    private func backupLoadErrorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.system(size: 16))
            VStack(alignment: .leading, spacing: 4) {
                Text("Cannot read backup directory")
                    .font(.system(size: 13, weight: .semibold))
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer()
            Button("Pick Folder...") {
                backupVM.openExistingBackupFolder()
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Color.orange.opacity(0.08))
    }
}

struct EncryptedBackupUnlockSheet: View {
    @Binding var password: String
    let onUnlock: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "lock.fill")
                .font(.system(size: 36))
                .foregroundStyle(.orange)

            VStack(spacing: 6) {
                Text("Encrypted Backup")
                    .font(.headline)
                Text("Enter the password you set when enabling backup encryption.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            SecureField("Backup password", text: $password)
                .textFieldStyle(.roundedBorder)
                .onSubmit(onUnlock)

            HStack(spacing: 12) {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Unlock") { onUnlock() }
                    .buttonStyle(.borderedProminent)
                    .disabled(password.isEmpty)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(width: 340)
    }
}

struct BackupRow: View {
    let backup: BackupInfo
    let onBrowse: () -> Void
    let onDelete: () -> Void
    @State private var isExporting = false

    var body: some View {
        HStack(spacing: 14) {
            // Device icon
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.indigo.opacity(0.1))
                    .frame(width: 44, height: 44)
                Image(systemName: backup.productType.hasPrefix("iPad") ? "ipad" : "iphone")
                    .font(.system(size: 20))
                    .foregroundStyle(.indigo)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(backup.deviceName)
                        .font(.system(size: 14, weight: .medium))

                    if backup.isEncrypted {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.orange)
                            .help("Encrypted backup")
                    }

                    if backup.isFullBackup {
                        Text("Full")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.indigo)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.indigo.opacity(0.1))
                            .clipShape(Capsule())
                    }
                }

                HStack(spacing: 8) {
                    Text(backup.modelName)
                    Text("-")
                    Text("iOS \(backup.iosVersion)")
                }
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    Text(backup.dateString)
                    Text("(\(backup.relativeDate))")
                    Text("-")
                    if backup.sizeResolved {
                        Text(backup.sizeString)
                    } else {
                        Label("Calculating...", systemImage: "clock")
                    }
                    if backup.appCount > 0 {
                        Text("-")
                        Text("\(backup.appCount) apps")
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            }

            Spacer()

            HStack(spacing: 8) {
                Button("Browse") { onBrowse() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                Menu {
                    Button("Browse Contents") { onBrowse() }

                    Divider()

                    Button {
                        exportAsArchive()
                    } label: {
                        Label("Export as .phosphor Archive", systemImage: "archivebox")
                    }

                    Divider()

                    Button("Show in Finder") {
                        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: backup.path)
                    }

                    Divider()

                    Button("Delete Backup", role: .destructive) { onDelete() }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .frame(width: 24)
            }
        }
        .padding(.vertical, 6)
        .overlay {
            if isExporting {
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.7)
                    Text("Exporting archive...").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.regularMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private func exportAsArchive() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Export Here"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        isExporting = true
        Task {
            let path = await BackupArchiver.createArchive(from: backup, to: url.path) { _ in }
            isExporting = false
            if let path {
                NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: url.path)
            }
        }
    }
}

/// Sheet for configuring scheduled backups.
struct BackupScheduleSheet: View {

    @StateObject private var scheduler = BackupScheduler()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Scheduled Backups")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.bordered)
            }
            .padding()
            Divider()

            Form {
                Section("Schedule") {
                    Toggle("Enable automatic backups", isOn: $scheduler.schedule.enabled)

                    if scheduler.schedule.enabled {
                        Picker("Frequency", selection: $scheduler.schedule.frequency) {
                            ForEach(BackupScheduler.Frequency.allCases, id: \.self) { freq in
                                Text(freq.rawValue).tag(freq)
                            }
                        }

                        HStack {
                            Text("Preferred time")
                            Spacer()
                            Picker("Hour", selection: $scheduler.schedule.preferredHour) {
                                ForEach(0..<24, id: \.self) { h in
                                    Text(String(format: "%02d:00", h)).tag(h)
                                }
                            }
                            .frame(width: 100)
                        }

                        Toggle("Wi-Fi only (skip if USB not available)", isOn: $scheduler.schedule.wifiOnly)
                        Toggle("Incremental only (faster)", isOn: $scheduler.schedule.incrementalOnly)
                    }
                }

                if scheduler.schedule.enabled {
                    Section("Status") {
                        if let lastRun = scheduler.schedule.lastRunDate {
                            HStack {
                                Text("Last backup")
                                Spacer()
                                Text(lastRun.shortString)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if let nextRun = scheduler.schedule.nextRunDate {
                            HStack {
                                Text("Next backup")
                                Spacer()
                                Text(nextRun.shortString)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if let result = scheduler.schedule.lastResult {
                            HStack {
                                Text("Last result")
                                Spacer()
                                Text(result)
                                    .foregroundStyle(result == "Completed" ? .green : .orange)
                            }
                        }

                        Button("Run Now") {
                            Task { await scheduler.runNow() }
                        }
                        .disabled(scheduler.isRunningScheduledBackup)
                    }

                    if !scheduler.recentLogs.isEmpty {
                        Section("Recent Log") {
                            ForEach(scheduler.recentLogs.prefix(5)) { log in
                                HStack(spacing: 6) {
                                    Image(systemName: log.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                                        .font(.system(size: 10))
                                        .foregroundStyle(log.success ? .green : .red)
                                    Text(log.message)
                                        .font(.system(size: 11))
                                        .lineLimit(1)
                                    Spacer()
                                    Text(log.date.shortString)
                                        .font(.system(size: 10))
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
        }
        .onChange(of: scheduler.schedule.enabled) { _, enabled in
            if enabled {
                scheduler.updateNextRunDate()
                scheduler.startMonitoring()
            } else {
                scheduler.stopMonitoring()
            }
        }
    }
}
