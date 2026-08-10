import AppKit
import SwiftUI

/// Lists all discovered iOS backups with metadata. Allows creating new backups and managing existing ones.
struct BackupListView: View {

    @EnvironmentObject var deviceVM: DeviceViewModel
    @EnvironmentObject var backupVM: BackupViewModel
    var onBrowseBackup: () -> Void = {}
    @State private var showDeleteConfirm = false
    @State private var backupToDelete: BackupInfo?
    @State private var showImportArchive = false
    @State private var archiveProgress: String?
    @State private var isArchiving = false
    @State private var showScheduleSheet = false
    @State private var showFullWiFiBackupConfirm = false
    @State private var pendingFullWiFiBackupUDID: String?
    @State private var pendingFullWiFiBackupPrefersNetwork = false
    @State private var showIncompleteBackupTrashConfirm = false
    @State private var pendingIncompleteBackupIssue: BackupManager.BackupFailure?

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 14) {
                GradientIconTile(systemName: "externaldrive.fill", color: .blue, size: 40, iconSize: 19)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Backups")
                        .font(.title2.weight(.semibold))
                    Text(backupSummary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                newBackupMenu
                .buttonStyle(.borderedProminent)
                .tint(.brandAccent)

                Button {
                    backupVM.loadBackups()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .padding(20)

            Divider()

            backupStateNotice

            if !activeBackupActivities.isEmpty {
                backupActivityList
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
                        startBackup(for: device, incremental: shouldOfferIncremental(for: device))
                    },
                    actionLabel: emptyStateBackupActionLabel
                )
            } else {
                List {
                    ForEach(backupVM.backups) { backup in
                        BackupRow(backup: backup) {
                            if backupVM.openBackupBrowser(backup) {
                                onBrowseBackup()
                            }
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
                Text("This will permanently delete \(backup.deviceIdentityLabel) (\(backup.sizeResolved ? backup.sizeString : "size calculating")). This cannot be undone.")
            }
        }
        .alert("Backup", isPresented: $backupVM.showAlert) {
            Button("OK") {}
        } message: {
            Text(backupVM.alertMessage)
        }
        .sheet(item: $backupVM.backupIssue) { issue in
            BackupIssueSheet(
                issue: issue,
                primaryActionTitle: backupIssueActionTitle(for: issue),
                primaryAction: { handleBackupIssueAction(issue) },
                dismiss: { backupVM.backupIssue = nil }
            )
        }
        .alert("Move Incomplete Backup to Trash?", isPresented: $showIncompleteBackupTrashConfirm) {
            Button("Move to Trash & Run Full Backup", role: .destructive) {
                if let issue = pendingIncompleteBackupIssue {
                    Task { await backupVM.deleteIncompleteBackupAndRunFull(for: issue) }
                }
                pendingIncompleteBackupIssue = nil
            }
            Button("Cancel", role: .cancel) {
                pendingIncompleteBackupIssue = nil
            }
        } message: {
            Text(incompleteBackupTrashConfirmationMessage)
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
            Text(fullWiFiBackupConfirmationMessage)
        }
        .sheet(isPresented: $showScheduleSheet) {
            BackupScheduleSheet()
                .frame(width: 480, height: 500)
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

    private var activeBackupActivities: [BackupViewModel.BackupActivity] {
        backupVM.backupActivities.values
            .filter(\.isActive)
            .sorted { lhs, rhs in
                switch (lhs.state, rhs.state) {
                case (.running, .queued): true
                case (.queued, .running): false
                default: lhs.udid < rhs.udid
                }
            }
    }

    private var backedUpDeviceCount: Int {
        Set(backupVM.backups.map { backup in
            backup.udid.isEmpty ? "backup:\(backup.id)" : "device:\(backup.udid)"
        }).count
    }

    private var backupSummary: String {
        let backupWord = backupVM.backups.count == 1 ? "backup" : "backups"
        let deviceWord = backedUpDeviceCount == 1 ? "device" : "devices"
        return "\(backupVM.backups.count) \(backupWord) across \(backedUpDeviceCount) \(deviceWord) - \(backupVM.totalSize) total"
    }

    private var selectedDeviceBackupIsActive: Bool {
        deviceVM.selectedDevice.map { backupVM.isBackupActive(for: $0.id) } == true
    }


    @ViewBuilder
    private var backupStateNotice: some View {
        if let device = deviceVM.selectedDevice {
            let state = backupState(for: device)
            BackupStateNotice(title: state.title, detail: state.detail, icon: state.icon, tint: state.tint)
                .padding(.horizontal, 20)
                .padding(.top, 12)
        }
    }

    private func backupState(for device: DeviceInfo) -> (title: String, detail: String, icon: String, tint: Color) {
        let hasCompleteBackup = shouldOfferIncremental(for: device)
        if device.connectionType == .wifi {
            if hasCompleteBackup {
                return (
                    "Wi-Fi backup ready",
                    "Incremental Wi-Fi backups are available. Keep the device unlocked and on the same network while the backup runs.",
                    "wifi",
                    .blue
                )
            }
            return (
                "First backup must be full",
                "USB is recommended for the first backup. Wi-Fi is supported, but it is slower and more sensitive to sleep, lock, and network interruptions.",
                "externaldrive.badge.plus",
                .orange
            )
        }

        return (
            hasCompleteBackup ? "USB backup ready" : "USB recommended for first backup",
            hasCompleteBackup ? "USB is the fastest and most reliable way to refresh this backup." : "Create a full USB backup first. After that, incremental backups can update only changed files.",
            "cable.connector",
            .green
        )
    }

    @ViewBuilder
    private var backupCreationButtons: some View {
        if deviceVM.selectedDevice?.connectionType == .wifi {
            if let device = deviceVM.selectedDevice, shouldOfferIncremental(for: device) {
                Button {
                    startBackup(for: device, incremental: true)
                } label: {
                    Label("Incremental Wi-Fi Backup (Recommended)", systemImage: "wifi")
                }
                .disabled(deviceVM.selectedDevice == nil)
            } else {
                Button {
                    guard let device = deviceVM.selectedDevice else { return }
                    startBackup(for: device, incremental: false)
                } label: {
                    Label("First Wi-Fi Backup (Full)", systemImage: "externaldrive.badge.plus")
                }
                .disabled(deviceVM.selectedDevice == nil)
            }

            if let device = deviceVM.selectedDevice, shouldOfferIncremental(for: device) {
                Button {
                    startBackup(for: device, incremental: false)
                } label: {
                    Label("Full Wi-Fi Backup (Slower)", systemImage: "externaldrive.badge.plus")
                }
                .disabled(deviceVM.selectedDevice == nil)
            }
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

    private var emptyStateBackupActionLabel: String? {
        guard let device = deviceVM.selectedDevice else { return nil }
        if device.connectionType == .wifi {
            return shouldOfferIncremental(for: device) ? "Create Incremental Wi-Fi Backup" : "Create Full Wi-Fi Backup"
        }
        return "Create Backup"
    }

    private var fullWiFiBackupConfirmationMessage: String {
        guard let device = deviceVM.selectedDevice else {
            return "This device is connected over Wi-Fi. Full backups can be slower and more sensitive to interruptions."
        }
        if shouldOfferIncremental(for: device) {
            return "This device is connected over Wi-Fi. Full backups can be much slower and more sensitive to sleep, lock, and network interruptions. Incremental Wi-Fi Backup is recommended unless you specifically need a full backup."
        }
        return "This is the first backup for this device, so it must be a full backup. USB is recommended for the first backup; Wi-Fi is supported but slower and more sensitive to sleep, lock, and network interruptions."
    }

    private var incompleteBackupTrashConfirmationMessage: String {
        guard let issue = pendingIncompleteBackupIssue else { return "This will move the incomplete backup folder to Trash." }
        let path = issue.recoveryPath ?? issue.technicalDetails ?? "Unknown path"
        let device = issue.udid.map { " for device \($0)" } ?? ""
        return "This will move this incomplete backup folder\(device) to Trash, then run a full backup:\n\n\(path)\n\nPhosphor will not permanently delete the folder. You can restore it from Trash if needed."
    }

    private func shouldOfferIncremental(for device: DeviceInfo) -> Bool {
        BackupManager.hasExistingBackup(for: device.id) && backupVM.backups.contains { backup in
            backup.udid == device.id || backup.id == device.id
        }
    }


    private func backupIssueActionTitle(for issue: BackupManager.BackupFailure) -> String? {
        switch issue.recoveryAction {
        case .runFullBackup:
            return "Run Full Backup"
        case .deleteIncompleteAndRunFull:
            return "Delete Incomplete Backup & Run Full"
        case .openBackupSettings:
            return "Open Backup Settings"
        case .retry:
            return "Retry"
        case .none:
            return nil
        }
    }

    private func handleBackupIssueAction(_ issue: BackupManager.BackupFailure) {
        switch issue.recoveryAction {
        case .runFullBackup:
            backupVM.backupIssue = nil
            Task { await backupVM.runFullBackup(for: issue) }
        case .deleteIncompleteAndRunFull:
            pendingIncompleteBackupIssue = issue
            backupVM.backupIssue = nil
            showIncompleteBackupTrashConfirm = true
        case .openBackupSettings:
            backupVM.backupIssue = nil
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        case .retry:
            Task { await backupVM.retryBackup(for: issue) }
        case .none:
            backupVM.backupIssue = nil
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

    private var backupActivityList: some View {
        VStack(spacing: 0) {
            ForEach(activeBackupActivities) { activity in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: activity.state == .running ? "externaldrive.badge.timemachine" : "clock")
                            .foregroundStyle(Color.brandAccent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(deviceIdentity(for: activity.udid))
                                .font(.system(size: 13, weight: .semibold))
                            Text(activity.displayProgressText)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("\(deviceIdentity(for: activity.udid)), \(activity.displayProgressText)")
                        Spacer()
                        Button("Cancel") {
                            backupVM.cancelBackup(udid: activity.udid)
                        }
                        .controlSize(.small)
                        .accessibilityLabel("Cancel backup for \(deviceIdentity(for: activity.udid))")
                    }
                    if case .running = activity.state {
                        ProgressView(
                            value: activity.displayProgressFraction,
                            total: 1.0
                        )
                        .progressViewStyle(.linear)
                        .tint(.brandAccent)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                if activity.id != activeBackupActivities.last?.id { Divider() }
            }
        }
        .background(Color.brandAccent.opacity(0.06))
    }

    private func deviceIdentity(for udid: String) -> String {
        let suffix = String(udid.suffix(8))
        guard let device = deviceVM.devices.first(where: { $0.id == udid }) else {
            return "Device · ID …\(suffix)"
        }
        return "\(device.name) · \(device.displayModelName) · ID …\(suffix)"
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


struct BackupStateNotice: View {
    let title: String
    let detail: String
    let icon: String
    let tint: Color

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(12)
        .background(tint.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

struct BackupIssueSheet: View {
    let issue: BackupManager.BackupFailure
    let primaryActionTitle: String?
    let primaryAction: () -> Void
    let dismiss: () -> Void
    @State private var showTechnicalDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.system(size: 24))
                VStack(alignment: .leading, spacing: 6) {
                    Text(issue.title)
                        .font(.title3.weight(.semibold))
                    Text(issue.message)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            if let details = issue.technicalDetails, !details.isEmpty {
                DisclosureGroup("Technical details", isExpanded: $showTechnicalDetails) {
                    ScrollView {
                        Text(details)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    }
                    .frame(minHeight: 90, maxHeight: 220)
                    .background(Color.secondary.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                if let primaryActionTitle {
                    Button(primaryActionTitle, role: issue.recoveryAction == .deleteIncompleteAndRunFull ? .destructive : nil) {
                        primaryAction()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(24)
        .frame(width: 520)
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
            GradientIconTile(
                systemName: backup.productType.hasPrefix("iPad") ? "ipad" : "iphone",
                color: .blue,
                size: 44,
                iconSize: 20
            )

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(backup.deviceIdentityLabel)
                        .font(.system(size: 14, weight: .medium))
                        .lineLimit(1)
                        .help("Full device ID: \(backup.udid.isEmpty ? "Unavailable" : backup.udid)")

                    if backup.isEncrypted {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.orange)
                            .help("Encrypted backup")
                    }

                    if backup.isFullBackup {
                        StatusChip(text: "Full", color: .brandAccent)
                    }
                }

                HStack(spacing: 8) {
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
    @EnvironmentObject private var deviceVM: DeviceViewModel
    @EnvironmentObject private var backupVM: BackupViewModel
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
                    ScheduledBackupDevicePicker(
                        targetUDID: Binding(
                            get: { scheduler.schedule.targetUDID },
                            set: { targetUDID in
                                let targetName = deviceVM.devices.first(where: { $0.id == targetUDID })?.name
                                scheduler.selectSchedule(targetUDID: targetUDID, targetName: targetName)
                            }
                        ),
                        targetName: $scheduler.schedule.targetName,
                        devices: deviceVM.devices,
                        wifiOnly: scheduler.schedule.wifiOnly
                    )

                    Toggle("Enable automatic backups", isOn: $scheduler.schedule.enabled)
                        .disabled(
                            !scheduler.schedule.enabled &&
                            scheduler.schedule.targetUDID == nil &&
                            deviceVM.devices.count != 1
                        )

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

                        Toggle("Wi-Fi only (skip if Wi-Fi is not available)", isOn: $scheduler.schedule.wifiOnly)
                        Toggle("Incremental when possible (faster)", isOn: $scheduler.schedule.incrementalOnly)
                        if scheduler.schedule.incrementalOnly {
                            Text("The first scheduled run will create the required full backup if this device does not already have complete backup metadata.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
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
                        .disabled(
                            scheduler.isRunningScheduledBackup ||
                            (scheduler.schedule.targetUDID == nil && deviceVM.devices.count > 1)
                        )
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
        .onChange(of: scheduler.schedule.enabled) { _, _ in scheduler.updateNextRunDate() }
        .onChange(of: scheduler.schedule.frequency) { _, _ in scheduler.updateNextRunDate() }
        .onChange(of: scheduler.schedule.preferredHour) { _, _ in scheduler.updateNextRunDate() }
        .onChange(of: scheduler.schedule.preferredMinute) { _, _ in scheduler.updateNextRunDate() }
        .onAppear { scheduler.attachBackupViewModel(backupVM) }
    }
}
