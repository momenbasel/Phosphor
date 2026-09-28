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
    @State private var cachedIncompleteStats: BackupManager.IncompleteBackupStats?
    @State private var isLoadingIncompleteStats = false
    @State private var showNonResumableCancelConfirm = false
    @State private var pendingCancelActivityUDID: String?
    @State private var hasCurrentResumableBackup: Bool = false

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
                .tint(hasCurrentResumableBackup ? .orange : .brandAccent)

                Button {
                    backupVM.loadBackups()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .padding(20)

            Divider()

            backupStateNotice

            if !visibleBackupActivities.isEmpty {
                backupActivityList
            }

            if let err = backupVM.loadError, backupVM.backups.isEmpty {
                backupLoadErrorBanner(err)
            }

            if backupVM.backups.isEmpty {
                if let device = deviceVM.selectedDevice, hasResumableBackup(for: device), !backupVM.isBackupActive(for: device.id) {
                    resumableBackupHeroCard(for: device)
                } else if activeBackupActivities.isEmpty {
                    EmptyStateView(
                        icon: "externaldrive",
                        title: "No Backups Found",
                        subtitle: "Back up your device, or pick an existing backup folder via New Backup -> Open Existing Backup Folder.",
                        action: {
                            guard let device = deviceVM.selectedDevice else { return }
                            startBackup(for: device, incremental: shouldOfferIncremental(for: device))
                        },
                        actionLabel: emptyStateBackupActionLabel,
                        color: .brandAccent
                    )
                } else {
                    Spacer(minLength: 0)
                }
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
                secondaryActionTitle: issue.recoveryAction == .resumeBackup ? "Delete & Start Fresh" : nil,
                secondaryAction: issue.recoveryAction == .resumeBackup ? {
                    pendingIncompleteBackupIssue = issue
                    backupVM.backupIssue = nil
                    showIncompleteBackupTrashConfirm = true
                } : nil,
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
        .alert("Stop Backup During Finalization?", isPresented: $showNonResumableCancelConfirm) {
            Button("Keep Running", role: .cancel) {
                pendingCancelActivityUDID = nil
            }
            Button("Stop Anyway (Non-Resumable)", role: .destructive) {
                if let udid = pendingCancelActivityUDID {
                    backupVM.cancelBackup(udid: udid)
                }
                pendingCancelActivityUDID = nil
            }
        } message: {
            Text("The backup is currently consolidating and sealing its manifest on disk. This finalization phase is not partially resumable — stopping now will discard this completed backup and require starting fresh. Are you sure you want to stop?")
        }
        .sheet(isPresented: $showScheduleSheet) {
            BackupScheduleSheet()
                .frame(width: 480, height: 500)
        }
        .onAppear { backupVM.loadBackups() }
        .task(id: deviceVM.selectedDevice?.id) {
            await updateResumableStatus()
        }
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
            if let device = deviceVM.selectedDevice, hasResumableBackup(for: device) {
                Label("Resume Backup", systemImage: "play.circle.fill")
            } else {
                Label("New Backup", systemImage: "plus")
            }
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

    private var visibleBackupActivities: [BackupViewModel.BackupActivity] {
        backupVM.backupActivities.values
            .filter { $0.isActive || $0.state == .cancelled }
            .sorted { lhs, rhs in
                switch (lhs.state, rhs.state) {
                case (.running, .queued): true
                case (.queued, .running): false
                case (.running, .cancelled): true
                case (.queued, .cancelled): true
                case (.cancelled, .running): false
                case (.cancelled, .queued): false
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
            // Suppress banner notice when the empty state already acts as the dedicated resumable hero card
            // or when a backup for this device is already actively running or docked in the activity list
            let hasDockedActivity = visibleBackupActivities.contains { $0.udid == device.id }
            if (backupVM.backups.isEmpty && hasCurrentResumableBackup) || hasDockedActivity {
                EmptyView()
            } else {
                let state = backupState(for: device)
                BackupStateNotice(title: state.title, detail: state.detail, icon: state.icon, tint: state.tint)
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
            }
        }
    }

    private func updateResumableStatus() async {
        guard let device = deviceVM.selectedDevice else {
            hasCurrentResumableBackup = false
            return
        }
        let udid = device.id
        let isResumable = await Task.detached(priority: .utility) { () -> Bool in
            if case .incomplete(let path) = BackupManager.backupMetadataHealth(for: udid) {
                return BackupManager.incompleteBackupHasPayloadData(path)
            }
            return false
        }.value
        await MainActor.run {
            self.hasCurrentResumableBackup = isResumable
        }
    }

    private func hasResumableBackup(for device: DeviceInfo) -> Bool {
        if device.id == deviceVM.selectedDevice?.id {
            return hasCurrentResumableBackup
        }
        if case .incomplete(let path) = BackupManager.backupMetadataHealth(for: device.id) {
            return BackupManager.incompleteBackupHasPayloadData(path)
        }
        return false
    }

    private func backupState(for device: DeviceInfo) -> (title: String, detail: String, icon: String, tint: Color) {
        if hasResumableBackup(for: device) {
            return (
                "Interrupted backup found",
                "Saved files from your previous backup were preserved. Resume will continue transferring where it left off.",
                "pause.circle.fill",
                .orange
            )
        }

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
        if let device = deviceVM.selectedDevice, hasResumableBackup(for: device) {
            Button {
                Task { await backupVM.resumeBackup(udid: device.id, preferNetwork: device.connectionType == .wifi, device: device) }
            } label: {
                Label("Resume Saved Backup", systemImage: "play.circle.fill")
            }
            .disabled(deviceVM.selectedDevice == nil)

            Divider()
        }

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

    @ViewBuilder
    private func resumableBackupHeroCard(for device: DeviceInfo) -> some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color.orange.opacity(0.22), Color.orange.opacity(0.06)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: 92, height: 92)
                Image(systemName: "pause.circle.fill")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(Color.orange)
            }
            .padding(.bottom, 2)

            VStack(spacing: 4) {
                Text("Backup Paused for \(device.name)")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)

                HStack(spacing: 6) {
                    Circle()
                        .fill(Color.secondary.opacity(0.4))
                        .frame(width: 7, height: 7)
                    Text("Idle · Safe to disconnect or exit")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }

            if let stats = cachedIncompleteStats {
                let activity = backupVM.activity(for: device.id)
                let activityFraction = activity?.displayProgressFraction
                let calculatedFraction = stats.completionFraction(for: device)
                let rawFraction = activityFraction ?? calculatedFraction ?? (stats.totalBytes > 1_000_000_000 ? min(Double(stats.totalBytes) / 70_000_000_000.0, 0.95) : nil)
                // A paused/interrupted backup is never 100% complete (which would be finalized). Cap at 0.99.
                let fraction = rawFraction.map { min($0, 0.99) }

                let remaining = stats.remainingBytes(for: device)
                let eta = activity?.eta ?? stats.estimatedResumeTime(for: device)

                VStack(spacing: 8) {
                    // Header progress metrics: % completed and remaining data
                    HStack(spacing: 6) {
                        if let fraction {
                            Text("\(Int(fraction * 100))% saved")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Color.orange)
                        } else {
                            Text("Saved")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }

                        Text("•")
                            .foregroundStyle(.secondary)

                        if let remaining, remaining > 0 {
                            Text("\(remaining.formattedFileSize) remaining")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.secondary)
                        } else if let fraction, fraction > 0, fraction < 0.99 {
                            let totalEst = Double(stats.totalBytes) / fraction
                            let remBytes = UInt64(max(totalEst - Double(stats.totalBytes), 0))
                            Text("~\(remBytes.formattedFileSize) remaining")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Ready to finalize")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                    }

                    // Progress bar
                    if let fraction {
                        ProgressView(value: fraction, total: 1.0)
                            .progressViewStyle(.linear)
                            .tint(Color.orange)
                            .frame(maxWidth: 320)
                    }

                    // Saved file count, total saved size, and paused time
                    Text("\(stats.fileCount.formatted()) files saved (\(stats.formattedSize)) • Paused \(stats.relativeTimeDescription)")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary.opacity(0.85))
                }
            } else if isLoadingIncompleteStats {
                HStack(spacing: 6) {
                    ProgressView().scaleEffect(0.7)
                    Text("Reading saved files from disk…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

            Text("Progress is saved. You can safely disconnect your device or close Phosphor. When ready, reconnect and resume anytime without starting over.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)

            HStack(spacing: 12) {
                Button {
                    Task { await backupVM.resumeBackup(udid: device.id, preferNetwork: device.connectionType == .wifi, device: device) }
                } label: {
                    Label("Resume Backup", systemImage: "play.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .controlSize(.regular)

                Button("Discard & Start Fresh...", role: .destructive) {
                    if case .incomplete(let path) = BackupManager.backupMetadataHealth(for: device.id) {
                        pendingIncompleteBackupIssue = BackupManager.BackupFailure(
                            title: "Discard Incomplete Backup",
                            message: "Move preserved partial data to Trash and run a fresh backup.",
                            technicalDetails: path,
                            recoveryAction: .deleteIncompleteAndRunFull,
                            udid: device.id,
                            recoveryPath: path
                        )
                        showIncompleteBackupTrashConfirm = true
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: device.id) {
            await loadIncompleteStatsInBackground(for: device.id)
        }
    }

    private func loadIncompleteStatsInBackground(for udid: String) async {
        isLoadingIncompleteStats = true
        let stats = await Task.detached(priority: .utility) {
            BackupManager.incompleteBackupStats(for: udid)
        }.value
        if !Task.isCancelled {
            cachedIncompleteStats = stats
            isLoadingIncompleteStats = false
        }
    }

    private var emptyStateBackupActionLabel: String? {
        guard let device = deviceVM.selectedDevice else { return nil }
        if hasResumableBackup(for: device) {
            return "Resume Backup"
        }
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
        case .resumeBackup:
            return "Resume Backup"
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
        case .resumeBackup:
            backupVM.backupIssue = nil
            Task { await backupVM.resumeBackup(for: issue) }
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
            ForEach(visibleBackupActivities) { activity in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: activity.state == .running ? (activity.isFinalizing ? "arrow.triangle.2.circlepath.circle.fill" : "externaldrive.badge.timemachine") : (activity.state == .cancelled ? "pause.circle.fill" : "clock"))
                            .foregroundStyle(activity.state == .cancelled ? Color.orange : Color.brandAccent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(deviceIdentity(for: activity.udid))
                                .font(.system(size: 13, weight: .semibold))
                            Text(activity.displayProgressText)
                                .font(.system(size: 11))
                                .foregroundStyle(activity.state == .cancelled ? .primary : .secondary)
                                .lineLimit(1)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("\(deviceIdentity(for: activity.udid)), \(activity.displayProgressText)")
                        Spacer()

                        if activity.state == .cancelled {
                            Button {
                                if let device = deviceVM.devices.first(where: { $0.id == activity.udid }) {
                                    Task { await backupVM.resumeBackup(udid: activity.udid, preferNetwork: device.connectionType == .wifi, device: device) }
                                } else {
                                    Task { await backupVM.resumeBackup(udid: activity.udid, preferNetwork: false) }
                                }
                            } label: {
                                Label("Resume", systemImage: "play.fill")
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.orange)
                            .controlSize(.small)

                            Button {
                                backupVM.dismissActivity(for: activity.udid)
                            } label: {
                                Image(systemName: "xmark.circle")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Dismiss")
                        } else if activity.isCancelling {
                            Button {
                            } label: {
                                HStack(spacing: 4) {
                                    ProgressView()
                                        .controlSize(.mini)
                                    Text("Pausing...")
                                }
                            }
                            .controlSize(.small)
                            .disabled(true)
                            .accessibilityLabel("Pausing backup for \(deviceIdentity(for: activity.udid))")
                        } else {
                            Button {
                                if activity.isNonResumableFinalizationPhase {
                                    pendingCancelActivityUDID = activity.udid
                                    showNonResumableCancelConfirm = true
                                } else {
                                    backupVM.cancelBackup(udid: activity.udid)
                                }
                            } label: {
                                Label("Pause & Save", systemImage: "pause.circle")
                            }
                            .controlSize(.small)
                            .help(activity.isNonResumableFinalizationPhase ? "Warning: Finalization is non-resumable. Stopping now will abort this completed backup." : "Stops the backup and saves progress. You can resume later.")
                            .accessibilityLabel("Cancel backup for \(deviceIdentity(for: activity.udid))")
                        }
                    }
                    if case .running = activity.state {
                        if activity.isAwaitingPasscode {
                            HStack(spacing: 8) {
                                Image(systemName: "lock.shield.fill")
                                    .foregroundStyle(.orange)
                                    .font(.system(size: 14, weight: .semibold))
                                Text("Please unlock your device and enter your passcode or tap 'Trust' to proceed...")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(.orange)
                            }
                            .padding(.vertical, 4)
                            .padding(.horizontal, 8)
                            .background(Color.orange.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            ProgressView(
                                value: activity.displayProgressFraction,
                                total: 1.0
                            )
                            .progressViewStyle(.linear)
                            .tint(activity.isAwaitingPasscode ? .orange : .brandAccent)

                            Text(activity.isFinalizing ? (activity.finalizationMetrics != nil ? "Reorganizing files from snapshot onto disk. Do not disconnect." : "Consolidating files and sealing backup manifest on disk...") : "Progress is saved automatically. You can stop or unplug and resume later.")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                    } else if case .cancelled = activity.state {
                        VStack(alignment: .leading, spacing: 4) {
                            ProgressView(
                                value: activity.displayProgressFraction,
                                total: 1.0
                            )
                            .progressViewStyle(.linear)
                            .tint(.orange)

                            Text("Progress is saved. You can reconnect or click Resume anytime to continue.")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                if activity.id != visibleBackupActivities.last?.id { Divider() }
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
    var secondaryActionTitle: String? = nil
    var secondaryAction: (() -> Void)? = nil
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
                if let secondaryActionTitle, let secondaryAction {
                    Button(secondaryActionTitle, role: .destructive) {
                        secondaryAction()
                    }
                }
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
                                Text(LocalizedStringKey(freq.rawValue)).tag(freq)
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
