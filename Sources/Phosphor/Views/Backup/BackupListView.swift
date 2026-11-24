import AppKit
import SwiftUI

/// Lists all discovered iOS backups with metadata. Allows creating new backups and managing existing ones.
struct BackupListView: View {

    @EnvironmentObject var deviceVM: DeviceViewModel
    @EnvironmentObject var backupVM: BackupViewModel
    var onBrowseBackup: () -> Void = {}
    @State private var showDeleteConfirm = false
    @State private var backupToDelete: BackupInfo?
    @State private var showUnarchiveConfirm = false
    @State private var backupToUnarchive: BackupInfo?
    @State private var showScheduleSheet = false
    @State private var showFullWiFiBackupConfirm = false
    @State private var pendingFullWiFiBackupUDID: String?
    @State private var showIncompleteBackupTrashConfirm = false
    @State private var pendingIncompleteBackupIssue: BackupManager.BackupFailure?
    @State private var showNonResumableCancelConfirm = false
    @State private var pendingCancelActivityUDID: String?
    @State private var diagnosisUDID: String?
    @State private var showDiagnosisSheet = false
    @State private var preflightDevice: DeviceInfo?
    @State private var preflightIncremental = false
    @State private var preflightPreferNetwork = false
    @State private var preflightConfig = DeviceBackupConfiguration()

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
                .tint(deviceVM.selectedDevice.map { hasResumableBackup(for: $0) } == true ? .orange : .brandAccent)
                .disabled(backupVM.isLoadingBackups)
                .help(backupVM.isLoadingBackups ? "Scanning backup folder on disk…" : "Create or manage backups")

                Button {
                    backupVM.loadBackups()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(backupVM.isLoadingBackups)
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
                if backupVM.isLoadingBackups {
                    VStack(spacing: 12) {
                        ProgressView()
                            .controlSize(.regular)
                        Text("Scanning Backup Location…")
                            .font(.headline)
                        Text("Reading existing backups from \(BackupManager.activeBackupDir)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                        BackupRow(
                            backup: backup,
                            activity: backup.isArchivedSnapshot ? nil : backupVM.activity(for: backup.udid),
                            isDeviceConnected: deviceVM.devices.contains(where: { $0.id == backup.udid }),
                            hasActiveSlotForDevice: backupVM.backups.contains { !$0.isArchivedSnapshot && $0.udid == backup.udid },
                            isDeviceBackupRunning: backupVM.isBackupActive(for: backup.udid)
                        ) {
                            if backupVM.openBackupBrowser(backup) {
                                onBrowseBackup()
                            }
                        } onDelete: {
                            let latest = backupVM.backups.first(where: { $0.id == backup.id }) ?? backup
                            backupToDelete = latest
                            showDeleteConfirm = true
                            if !latest.sizeResolved || latest.size == 0 {
                                let targetPath = latest.path
                                let targetId = latest.id
                                Task.detached(priority: .userInitiated) {
                                    let computed = FileManager.default.directorySize(at: targetPath)
                                    await MainActor.run {
                                        if backupToDelete?.id == targetId {
                                            backupToDelete = backupToDelete?.withSize(computed)
                                        }
                                    }
                                }
                            }
                        } onResume: {
                            Task { await backupVM.restartStalledBackup(udid: backup.udid, device: deviceVM.devices.first(where: { $0.id == backup.udid })) }
                        } onRepair: {
                            repairBrokenBackup(backup)
                        } onPause: {
                            pauseBackupActivity(for: backup.udid)
                        } onDiagnose: {
                            diagnosisUDID = backup.udid
                            showDiagnosisSheet = true
                        } onUnarchive: {
                            let latest = backupVM.backups.first(where: { $0.id == backup.id }) ?? backup
                            backupToUnarchive = latest
                            showUnarchiveConfirm = true
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .alert("Delete Backup?", isPresented: $showDeleteConfirm) {
            Button("Delete") {
                if let backup = backupToDelete {
                    backupVM.deleteBackup(backup)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let backup = backupToDelete {
                let current = backupVM.backups.first(where: { $0.id == backup.id }) ?? backup
                let resolvedSize = current.size > 0 ? current.size : backup.size
                let sizeLabel: String = {
                    if resolvedSize > 0 {
                        return resolvedSize.formattedFileSize
                    }
                    if !current.sizeResolved && !backup.sizeResolved {
                        return "Calculating…"
                    }
                    return "Empty or incomplete"
                }()
                let stateLabel = current.isArchivedSnapshot ? "Archived (\(current.healthState.rawValue))" : current.healthState.rawValue
                Text("Permanently delete the \(stateLabel.lowercased()) backup for \"\(current.deviceName)\" (\(current.modelName))?\n\nFolder: \(current.id)\nLast modified: \(current.dateString)\nSize on disk: \(sizeLabel)\n\nThis action cannot be undone.")
            }
        }
        .alert("Unarchive Backup?", isPresented: $showUnarchiveConfirm) {
            Button("Unarchive") {
                if let backup = backupToUnarchive {
                    backupVM.unarchiveBackup(backup)
                }
                backupToUnarchive = nil
            }
            Button("Cancel", role: .cancel) {
                backupToUnarchive = nil
            }
        } message: {
            if let backup = backupToUnarchive {
                let current = backupVM.backups.first(where: { $0.id == backup.id }) ?? backup
                Text("Restore this archived snapshot for \"\(current.deviceName)\" (\(current.modelName)) as the active backup?\n\nFrom: \(current.id)\nTo: \(current.udid)\nBackup date: \(current.dateString)\n\nFuture incremental backups will build upon this snapshot.")
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
            Button("Move to Trash & Run Full Backup") {
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
            Button("Configure & Run Full Wi-Fi Backup") {
                if let udid = pendingFullWiFiBackupUDID,
                   let device = deviceVM.devices.first(where: { $0.id == udid }) ?? deviceVM.selectedDevice {
                    preflightIncremental = false
                    preflightPreferNetwork = true
                    preflightConfig = DeviceBackupConfiguration.load(for: device.id)
                    preflightDevice = device
                }
                pendingFullWiFiBackupUDID = nil
            }
            Button("Cancel", role: .cancel) {
                pendingFullWiFiBackupUDID = nil
            }
        } message: {
            Text(fullWiFiBackupConfirmationMessage)
        }
        .alert("Pause Backup During Finalization?", isPresented: $showNonResumableCancelConfirm) {
            Button("Keep Running", role: .cancel) {
                pendingCancelActivityUDID = nil
            }
            Button("Pause and Keep Incomplete") {
                if let udid = pendingCancelActivityUDID {
                    backupVM.cancelBackup(udid: udid)
                }
                pendingCancelActivityUDID = nil
            }
        } message: {
            Text("All files transferred so far are safely preserved on disk. Because the backup is currently consolidating and sealing its files, stopping now will save it as an Incomplete backup. You can click Resume anytime to finish finalization.")
        }
        .sheet(isPresented: $showScheduleSheet) {
            BackupScheduleSheet()
                .frame(width: 480, height: 500)
        }
        .sheet(isPresented: $showDiagnosisSheet) {
            BackupDiagnosisSheet(
                udid: diagnosisUDID ?? "",
                text: diagnosisUDID.flatMap { backupVM.diagnosisText(for: $0) }
                    ?? "No live activity for this device.",
                dismiss: { showDiagnosisSheet = false; diagnosisUDID = nil }
            )
        }
        .sheet(item: $preflightDevice) { device in
            BackupPreflightSheet(
                device: device,
                incremental: $preflightIncremental,
                preferNetwork: preflightPreferNetwork,
                configuration: $preflightConfig,
                onNavigateToBackups: {},
                onStartBackup: {
                    Task {
                        await backupVM.createBackup(
                            udid: device.id,
                            incremental: preflightIncremental,
                            preferNetwork: preflightPreferNetwork,
                            device: device,
                            configuration: preflightConfig
                        )
                    }
                }
            )
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
            if backupVM.isLoadingBackups {
                Label("Scanning Backups…", systemImage: "hourglass")
            } else if let device = deviceVM.selectedDevice, hasResumableBackup(for: device) {
                Label("Resume Backup", systemImage: "play.circle.fill")
            } else {
                Label("New Backup", systemImage: "plus")
            }
        }
    }

    private var activeBackupActivities: [BackupViewModel.BackupActivity] {
        backupVM.backupActivities.values
            .filter(\.isActive)
            .filter { !hasBackupRow(for: $0.udid) }
            .sorted { lhs, rhs in
                switch (lhs.state, rhs.state) {
                case (.running, .queued): true
                case (.queued, .running): false
                default: lhs.udid < rhs.udid
                }
            }
    }

    /// Pause & Save for a backup rendered inside its persisted row. Finalization
    /// is not resumable, so it needs the same confirmation the activity card shows.
    private func pauseBackupActivity(for udid: String) {
        guard let activity = backupVM.activity(for: udid) else { return }
        if activity.isNonResumableFinalizationPhase {
            pendingCancelActivityUDID = udid
            showNonResumableCancelConfirm = true
        } else {
            backupVM.cancelBackup(udid: udid)
        }
    }

    /// True when a device with an in-flight backup already has a persisted row.
    /// That row renders the activity inline, so the standalone activity card
    /// would be a second surface for the same device.
    private func hasBackupRow(for udid: String) -> Bool {
        backupVM.backups.contains { !$0.isArchivedSnapshot && $0.udid == udid }
    }

    private var backedUpDeviceCount: Int {
        Set(backupVM.backups.map { backup in
            backup.udid.isEmpty ? "backup:\(backup.id)" : "device:\(backup.udid)"
        }).count
    }

    private var backupSummary: String {
        if backupVM.isLoadingBackups && backupVM.backups.isEmpty {
            return "Scanning backup location…"
        }
        let backupWord = backupVM.backups.count == 1 ? "backup" : "backups"
        let deviceWord = backedUpDeviceCount == 1 ? "device" : "devices"
        return "\(backupVM.backups.count) \(backupWord) across \(backedUpDeviceCount) \(deviceWord) - \(backupVM.totalSize) total"
    }

    @ViewBuilder
    private var backupStateNotice: some View {
        if let device = deviceVM.selectedDevice {
            // Suppress notice while scanning backup directory, when a backup is actively running, or when a paused/broken row is already displayed in the list
            if backupVM.isLoadingBackups || backupVM.isBackupActive(for: device.id) || hasResumableBackup(for: device) {
                EmptyView()
            } else {
                let state = backupState(for: device)
                BackupStateNotice(title: state.title, detail: state.detail, icon: state.icon, tint: state.tint)
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
            }
        }
    }

    private func hasResumableBackup(for device: DeviceInfo) -> Bool {
        backupVM.hasResumableBackup(for: device.id)
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
            let isSelectedDeviceBusy = deviceVM.selectedDevice.map { backupVM.isBackupActive(for: $0.id) } ?? true
            Button {
                guard let device = deviceVM.selectedDevice else { return }
                startBackup(for: device, incremental: false)
            } label: {
                Label("Full USB Backup (Fastest)", systemImage: "externaldrive.badge.plus")
            }
            .disabled(isSelectedDeviceBusy)

            Button {
                guard let device = deviceVM.selectedDevice else { return }
                startBackup(for: device, incremental: true)
            } label: {
                Label("Incremental Backup", systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(isSelectedDeviceBusy || deviceVM.selectedDevice.map { shouldOfferIncremental(for: $0) } != true)
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
        if let existing = backupVM.backups.first(where: { !$0.isArchivedSnapshot && ($0.udid == device.id || $0.id == device.id) }) {
            return existing.healthState == .complete
        }
        return BackupManager.hasExistingBackup(for: device.id) && backupVM.backups.contains { backup in
            !backup.isArchivedSnapshot && (backup.udid == device.id || backup.id == device.id)
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
            showFullWiFiBackupConfirm = true
            return
        }
        preflightIncremental = incremental
        preflightPreferNetwork = device.connectionType == .wifi
        preflightConfig = DeviceBackupConfiguration.load(for: device.id)
        preflightDevice = device
    }

    private func repairBrokenBackup(_ backup: BackupInfo) {
        guard let device = deviceVM.devices.first(where: { $0.id == backup.udid }) else { return }
        _ = BackupManager.quarantineBrokenBackup(at: backup.path)
        backupVM.loadBackups()
        startBackup(for: device, incremental: false)
    }

    private func importPhosphorArchive() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.init(filenameExtension: BackupArchiver.fileExtension)].compactMap { $0 }
        panel.message = "Select a .phosphor backup archive to import"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        Task {
            let result = await BackupArchiver.importArchive(from: url.path) { _ in }
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
                        Image(systemName: activity.state == .running ? (activity.isFinalizing ? "arrow.triangle.2.circlepath.circle.fill" : "externaldrive.badge.timemachine") : "clock")
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
                        if activity.isBusy {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                let elapsed = activity.transitionElapsedSeconds.map { " (\($0)s)" } ?? ""
                                Text(activity.transition == .restarting ? "Restarting…\(elapsed)" : "Pausing…\(elapsed)")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                        } else if activity.isStalled {
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
                            .help("Stops the backup and saves progress. You can resume later.")
                            Button("Diagnose…") {
                                diagnosisUDID = activity.udid
                                showDiagnosisSheet = true
                            }
                            .controlSize(.small)
                            .help("Show why this backup stalled")
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
                            if activity.isCalculatingResumeBaseline {
                                ProgressView()
                                    .progressViewStyle(.linear)
                                    .tint(.orange)
                            } else {
                                ProgressView(
                                    value: activity.displayProgressFraction,
                                    total: 1.0
                                )
                                .progressViewStyle(.linear)
                                .tint(activity.isAwaitingPasscode ? .orange : (activity.isQuiet ? .secondary : .brandAccent))
                            }

                            Text(activity.isFinalizing ? (activity.finalizationMetrics != nil ? "Reorganizing files from snapshot onto disk. Do not disconnect." : "Consolidating files and sealing backup manifest on disk...") : (activity.isQuiet ? "Waiting for device response…" : "Progress is saved automatically. You can stop or unplug and resume later."))
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
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

            if let details = issue.technicalDetails,
               !details.isEmpty,
               details != issue.recoveryPath {
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

/// Live diagnosis for a stalled or failing backup. The stalled state used to
/// show a Resume button and nothing else, so a backup that produced no progress
/// gave the user no way to tell whether it was transferring, wedged, or dead.
struct BackupDiagnosisSheet: View {
    let udid: String
    let text: String
    let dismiss: () -> Void
    @EnvironmentObject private var backupVM: BackupViewModel
    @State private var liveText: String = ""
    @State private var refreshTimer: Timer?

    private var currentText: String {
        if !liveText.isEmpty { return liveText }
        return text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "stethoscope")
                    .foregroundStyle(.orange)
                    .font(.system(size: 24))
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text("Backup Diagnosis")
                            .font(.title3.weight(.semibold))
                        if backupVM.isBackupActive(for: udid) {
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(Color.green)
                                    .frame(width: 7, height: 7)
                                Text("Live (Updating 1s)")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    Text("What Phosphor last observed for this backup.")
                        .foregroundStyle(.secondary)
                }
            }

            ScrollView {
                Text(currentText)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(minHeight: 160, maxHeight: 360)
            .background(Color.secondary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            HStack {
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(currentText, forType: .string)
                }
                Spacer()
                Button("Done") {
                    refreshTimer?.invalidate()
                    refreshTimer = nil
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 560)
        .onAppear {
            liveText = backupVM.diagnosisText(for: udid) ?? text
            refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
                Task { @MainActor in
                    if let updated = backupVM.diagnosisText(for: udid) {
                        liveText = updated
                    }
                }
            }
        }
        .onDisappear {
            refreshTimer?.invalidate()
            refreshTimer = nil
        }
    }
}

struct BackupRow: View {
    let backup: BackupInfo
    var activity: BackupViewModel.BackupActivity?
    var isDeviceConnected: Bool = true
    var hasActiveSlotForDevice: Bool = true
    var isDeviceBackupRunning: Bool = false
    let onBrowse: () -> Void
    let onDelete: () -> Void
    let onResume: () -> Void
    var onRepair: () -> Void = {}
    let onPause: () -> Void
    var onDiagnose: () -> Void = {}
    var onUnarchive: () -> Void = {}
    @State private var isExporting = false
    @State private var liveNow: Date = Date()
    private let rowSecondTicker = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    private var isActive: Bool { activity?.isActive == true }
    private var isStalled: Bool { activity?.isStalled == true }
    private var isQuiet: Bool { activity?.isQuiet == true }
    private var isBusy: Bool { activity?.isBusy == true }

    /// Progress for a backup running inside this row. The row keeps its identity
    /// while resuming instead of handing the device off to a separate card.
    @ViewBuilder
    private var activityStatus: some View {
        if let activity, isActive {
            VStack(alignment: .leading, spacing: 4) {
                if activity.isAwaitingPasscode {
                    HStack(spacing: 8) {
                        Image(systemName: "lock.shield.fill")
                            .foregroundStyle(.orange)
                            .font(.system(size: 13, weight: .semibold))
                        Text("Action Required on iPhone: Unlock your device and enter your passcode to continue the backup...")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.orange)
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 8)
                    .background(Color.orange.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }

                if activity.isCalculatingResumeBaseline {
                    ProgressView()
                        .progressViewStyle(.linear)
                        .tint(.orange)
                } else {
                    ProgressView(value: activity.displayProgressFraction, total: 1.0)
                        .progressViewStyle(.linear)
                        .tint(activity.isAwaitingPasscode ? .orange : (isStalled ? .orange : (isQuiet ? .secondary : .brandAccent)))
                }

            HStack(spacing: 6) {
                let pct = Int(activity.displayProgressFraction * 100)
                let statusText: String = {
                    if isStalled {
                        return "Quiet (>5 min) · Device may be processing large files (\(pct)%)"
                    }
                    if isQuiet {
                        let quietSecs = max(1, Int(Date().timeIntervalSince(activity.lastProgressUpdate)))
                        return "Waiting for device response… (\(quietSecs)s quiet · \(pct)%)"
                    }
                    if activity.isFinalizing {
                        return "Finalizing & sealing (\(pct)%)"
                    }
                    if activity.isResume {
                        if activity.isCalculatingResumeBaseline {
                            return "Resuming · Calculating previous progress…"
                        }
                        if activity.hasReceivedTransferProgress && pct > 0 {
                            return "Backing up (\(pct)%)"
                        }
                        if pct > 0 {
                            return "Resuming (\(pct)%)"
                        }
                        return "Resuming…"
                    }
                    return "Backing up (\(pct)%)"
                }()
                Text(statusText)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(isStalled ? Color.orange : Color.secondary)
                    .lineLimit(1)
                if let speed = activity.speed, !speed.isEmpty {
                    Text("· Speed: \(speed)")
                }
                if let consolidatedETA = activity.consolidatedETADescription(at: liveNow) {
                    Text("· ETA: \(consolidatedETA)")
                } else if let predicted = activity.predictiveETA,
                          predicted.confidence != .none,
                          predicted.estimatedSeconds > 0,
                          activity.hasReceivedTransferProgress {
                    Text("· ETA: ~\(predicted.estimatedSeconds.formattedDuration)")
                } else if !activity.isAwaitingPasscode && !activity.isFinalizing && !isStalled && !isQuiet {
                    Text("· Calculating ETA…")
                        .foregroundStyle(.tertiary)
                }
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)

            if let phase = activity.phaseMetrics?.phase {
                let phaseText = activity.phaseMetrics?.phaseDetail?.description ?? phase.displayName
                HStack(spacing: 8) {
                    Label {
                        Text(phaseText)
                    } icon: {
                        Image(systemName: phase.systemImage)
                    }
                    if let phaseMetrics = activity.phaseMetrics {
                        if let transferred = phaseMetrics.filesTransferred, let total = phaseMetrics.totalFiles, total > 0 {
                            let remaining = max(0, total - transferred)
                            Text("· Files: \(transferred.formatted()) / \(total.formatted()) (\(remaining.formatted()) left)")
                        }
                        if activity.phaseMetrics?.phaseDetail == nil,
                           let bytes = phaseMetrics.bytesTransferred,
                           let totalB = phaseMetrics.totalBytes,
                           totalB > 0 {
                            Text("· Data: \(bytes.formattedFileSize) / \(totalB.formattedFileSize)")
                        }
                    }
                }
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            }

            if let stats = activity.throughputStats, stats.samplesCount >= 5 {
                HStack(spacing: 6) {
                    Text("Avg: \(Self.formatRate(stats.averageBytesPerSecond))")
                    Text("· Peak: \(Self.formatRate(stats.peakBytesPerSecond))")
                    if activity.throughputTrend != .insufficient {
                        Text("· Trend: \(activity.throughputTrend.description)")
                    }
                }
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            }

            if let metrics = activity.finalizationMetrics, activity.phaseMetrics?.phaseDetail == nil {
                Text("Finalizing: \(metrics.filesMoved.formatted()) / ~\(metrics.totalFiles.formatted()) files moved")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            }
        }
    }

    private static func formatRate(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond > 0 else { return "-" }
        return ByteCountFormatter.string(fromByteCount: Int64(bytesPerSecond), countStyle: .file) + "/s"
    }

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

                    if backup.isArchivedSnapshot {
                        StatusChip(text: "Archived", color: .secondary, icon: "archivebox.fill")
                            .help("Preserved historical snapshot (\(backup.id))")
                    }

                    if isActive {
                        let activeChipText: String = {
                            if activity?.isFinalizing == true { return "Finalizing" }
                            if activity?.isResume == true { return "Resuming" }
                            return "Backing Up"
                        }()
                        StatusChip(
                            text: activeChipText,
                            color: isStalled ? .orange : .brandAccent,
                            icon: "arrow.triangle.2.circlepath.circle.fill"
                        )
                        .help("Live backup in progress for this device")
                    } else {
                        switch backup.healthState {
                        case .complete:
                            StatusChip(text: "Full", color: .brandAccent)
                                .help(backup.isFullBackup
                                    ? "Self-contained full snapshot created in a single session"
                                    : "Self-contained full snapshot updated across multiple incremental or resumed sessions")
                            StatusChip(text: "Complete", color: .green, icon: "checkmark.circle.fill")
                        case .paused:
                            StatusChip(text: "Full", color: .brandAccent)
                            StatusChip(text: "Paused", color: .orange, icon: "pause.circle.fill")
                        case .broken:
                            StatusChip(text: "Broken", color: .red, icon: "exclamationmark.triangle.fill")
                                .help("Metadata exists, but zero payload files were found on disk")
                        }
                    }
                }

                HStack(spacing: 8) {
                    Text("iOS \(backup.iosVersion)")
                }
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

                HStack(spacing: 6) {
                    if let activity, isActive {
                        Text(activity.activeTimelineDescription(at: liveNow))
                    } else {
                        Text(backup.statusTimestampDescription)
                    }
                    Text("·")
                    if backup.sizeResolved {
                        Text(backup.sizeString)
                    } else {
                        Label("Calculating...", systemImage: "clock")
                    }
                    if backup.appCount > 0 {
                        Text("·")
                        Text("\(backup.appCount) apps")
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)

                activityStatus
            }

            Spacer()

            HStack(spacing: 8) {
                if isBusy {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        let elapsed = activity?.transitionElapsedSeconds(at: liveNow).map { " (\($0)s)" } ?? ""
                        Text(activity?.transition == .restarting ? "Restarting…\(elapsed)" : "Pausing…\(elapsed)")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                } else if isActive {
                    Button("Pause & Save", action: onPause)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("Stops the backup and saves progress. You can resume later.")
                    if isStalled {
                        Button("Diagnose…") { onDiagnose() }
                            .controlSize(.small)
                            .help("Show why this backup stalled")
                    }
                } else {
                    switch backup.healthState {
                    case .complete:
                        if backup.isArchivedSnapshot && !hasActiveSlotForDevice {
                            Button(action: onUnarchive) {
                                Label("Unarchive", systemImage: "arrow.uturn.backward.circle")
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.brandAccent)
                            .controlSize(.small)
                            .disabled(isDeviceBackupRunning)
                            .help("Restore this archived snapshot as the active backup for \(backup.deviceName)")
                        }
                    case .paused:
                        if backup.isArchivedSnapshot {
                            if !hasActiveSlotForDevice {
                                Button(action: onUnarchive) {
                                    Label("Unarchive", systemImage: "arrow.uturn.backward.circle")
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .disabled(isDeviceBackupRunning)
                                .help("Restore this archived snapshot as the active backup for \(backup.deviceName)")
                            }
                        } else {
                            Button("Resume", action: onResume)
                                .buttonStyle(.borderedProminent)
                                .tint(.orange)
                                .controlSize(.small)
                                .disabled(!isDeviceConnected)
                                .help(isDeviceConnected
                                    ? "Resume paused backup from saved progress"
                                    : "Connect \(backup.deviceName) to resume this backup")
                        }
                    case .broken:
                        if !backup.isArchivedSnapshot {
                            Button("Repair", action: onRepair)
                                .buttonStyle(.borderedProminent)
                                .tint(.orange)
                                .controlSize(.small)
                                .disabled(!isDeviceConnected)
                                .help(isDeviceConnected
                                    ? "Quarantine this broken folder and start a clean full backup"
                                    : "Connect \(backup.deviceName) to repair this backup")
                        }
                        Button("Delete", role: .destructive, action: onDelete)
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .help("Delete this broken backup folder")
                    }
                }

                if !isActive && backup.healthState != .broken {
                    Button("Browse") { onBrowse() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }

                Menu {
                    Button("Browse Contents") { onBrowse() }

                    if backup.isArchivedSnapshot && !hasActiveSlotForDevice && backup.healthState != .broken {
                        Divider()

                        Button {
                            onUnarchive()
                        } label: {
                            Label(
                                "Set as Active Backup (Unarchive)…",
                                systemImage: "arrow.uturn.backward.circle"
                            )
                        }
                        .disabled(isDeviceBackupRunning)
                    }

                    Divider()

                    Button {
                        exportAsArchive()
                    } label: {
                        Label("Export as .phosphor Archive", systemImage: "archivebox")
                    }

                    Divider()

                    Button {
                        onDiagnose()
                    } label: {
                        Label("Diagnose & Activity Log…", systemImage: "stethoscope")
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
        .onReceive(rowSecondTicker) { tick in
            if isActive || isBusy {
                liveNow = tick
            }
        }
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
