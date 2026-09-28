import Foundation
import SwiftUI

/// Drives backup list, creation, browsing, and extraction UI.
@MainActor
final class BackupViewModel: ObservableObject {

    struct BackupActivity: Identifiable {
        enum State: Equatable {
            case queued(position: Int)
            case running
            case completed
            case failed
            case cancelled
        }

        var id: String { udid }
        let udid: String
        var state: State
        var progressText: String
        var progressFraction: Double?
        var eta: String?
        var speed: String?
        var isResume: Bool = false
        var resumeBaselineFraction: Double = 0.0
        var isCancelling: Bool = false
        var isAwaitingPasscode: Bool = false
        var errorMessage: String?

        var finalizationMetrics: FinalizationProgressTracker.Metrics?

        var isActive: Bool {
            switch state {
            case .queued, .running: true
            case .completed, .failed, .cancelled: false
            }
        }

        var isFinalizing: Bool {
            if case .running = state {
                return (progressFraction ?? 0.0) >= 0.99 || finalizationMetrics != nil
            }
            return false
        }

        var isNonResumableFinalizationPhase: Bool {
            if case .running = state, isFinalizing {
                return true
            }
            return false
        }

        var displayProgressText: String {
            switch state {
            case .queued(let position): return "Queued · #\(position)"
            case .running:
                if isCancelling {
                    return "Pausing (Saving progress)..."
                }
                var components: [String] = []
                if isFinalizing {
                    let pct = Int(displayProgressFraction * 100)
                    if let metrics = finalizationMetrics {
                        switch metrics.stage {
                        case .moving:
                            components.append("Finalizing \(pct)%")
                            components.append("\(metrics.filesMoved.formatted()) / ~\(metrics.totalFiles.formatted()) files")
                            if let speed = metrics.formattedSpeed {
                                components.append(speed)
                            }
                            if let eta = metrics.formattedETA {
                                components.append("ETA: \(eta)")
                            }
                        case .verifying(let scanned, let total):
                            components.append("Verifying \(Int(metrics.phaseFraction * 100))%")
                            components.append("Bucket \(scanned)/\(total)")
                            if let eta = metrics.formattedETA {
                                components.append("ETA: \(eta)")
                            }
                        }
                    } else {
                        components.append("Finalizing \(pct)%")
                        components.append("Reorganizing & verifying files...")
                    }
                } else if isResume && speed == nil && eta == nil && (progressFraction ?? 0.0) <= resumeBaselineFraction {
                    components.append("Resuming · Preparing...")
                } else {
                    let pct = Int(displayProgressFraction * 100)
                    components.append("Backing up \(pct)%")
                }
                if !isFinalizing {
                    if let speed, !speed.isEmpty {
                        components.append(speed)
                    }
                    if let eta, !eta.isEmpty {
                        components.append("ETA: \(eta)")
                    }
                }
                return components.joined(separator: " · ")
            case .completed: return "Completed"
            case .failed: return "Failed"
            case .cancelled:
                let pct = Int(displayProgressFraction * 100)
                if pct > 0 {
                    return "Paused at \(pct)% · Progress saved"
                }
                return "Paused · Progress saved"
            }
        }

        var displayProgressFraction: Double {
            if isFinalizing {
                if let metrics = finalizationMetrics {
                    // Smoothly map phase fraction across the 0.90 -> 0.99 window
                    let scaled = 0.90 + (metrics.phaseFraction * 0.09)
                    return min(max(scaled, 0.90), 0.99)
                }
                return 0.99
            }
            guard let progressFraction else {
                return resumeBaselineFraction > 0 ? resumeBaselineFraction : 0.05
            }
            if isResume && resumeBaselineFraction > 0 {
                // Compute progress over total: baseline + remaining * sessionFraction
                let remainingFraction = 1.0 - resumeBaselineFraction
                let totalFraction = resumeBaselineFraction + (remainingFraction * progressFraction)
                let bounded = min(max(totalFraction, resumeBaselineFraction), 1.0)
                // Cap in-progress running state at 0.99 so 100% is only shown when state becomes .completed
                return state == .completed ? 1.0 : min(bounded, 0.99)
            }
            let bounded = min(max(progressFraction, 0.05), 1.0)
            return state == .completed ? 1.0 : min(bounded, 0.99)
        }
    }

    @Published var backups: [BackupInfo] = []
    @Published var selectedBackup: BackupInfo?
    @Published var isCreating = false
    @Published var progressText = ""
    @Published var progressFraction: Double?
    @Published var showAlert = false
    @Published var alertMessage = ""
    @Published var backupIssue: BackupManager.BackupFailure?
    @Published var loadError: String?
    @Published private(set) var backupActivities: [String: BackupActivity] = [:]

    // Browser state
    @Published var browserDomains: [String] = []
    @Published var browserFiles: [BackupManifest.FileEntry] = []
    @Published var currentDomain: String?
    @Published var searchQuery = ""
    @Published var searchResults: [BackupManifest.FileEntry] = []

    // Encrypted-backup unlock. Set when a browse attempt hits a locked backup;
    // the view presents a password sheet bound to it.
    @Published var pendingUnlock: BackupInfo?
    @Published var unlockError: String?
    @Published var isUnlocking = false

    let backupManager = BackupManager()
    private(set) var queryStore: ManifestQueryStore?
    private var browserLoadTask: Task<Void, Never>?
    private var domainSizeTask: Task<Void, Never>?
    private var searchSizeTask: Task<Void, Never>?
    private var currentDomainToken = UUID()
    private var currentSearchToken = UUID()
    private var sizeResolutionTask: Task<Void, Never>?
    private var latestBackupRequests: [String: BackupRequest] = [:]
    private var failedBackupRequests: [UUID: BackupRequest] = [:]
    private var jobQueue = BackupJobQueue(maxConcurrent: 2)
    private var requestTracker = BackupRequestTracker()
    private var pendingBackupRequests: [String: BackupRequest] = [:]
    private var backupManagers: [String: BackupManager] = [:]
    private var backupJobTasks: [String: Task<Void, Never>] = [:]
    private var finalizationTasks: [String: Task<Void, Never>] = [:]
    private var backupCompletionContinuations: [String: CheckedContinuation<Void, Never>] = [:]
    private var backupJobWaiters: [String: [BackupJobWaiter]] = [:]

    private struct BackupRequest {
        let id: UUID
        let udid: String
        let incremental: Bool
        let preferNetwork: Bool
        let encrypted: Bool
        let isResume: Bool
        let device: DeviceInfo?

        init(
            id: UUID = UUID(),
            udid: String,
            incremental: Bool = false,
            preferNetwork: Bool = false,
            encrypted: Bool = false,
            isResume: Bool = false,
            device: DeviceInfo? = nil
        ) {
            self.id = id
            self.udid = udid
            self.incremental = incremental
            self.preferNetwork = preferNetwork
            self.encrypted = encrypted
            self.isResume = isResume
            self.device = device
        }
    }

    private struct BackupJobWaiter {
        let requestID: UUID
        let continuation: CheckedContinuation<Void, Never>
    }

    private var backupDiscoveryTask: Task<Void, Never>?

    func loadBackups() {
        sizeResolutionTask?.cancel()
        backupDiscoveryTask?.cancel()
        backupDiscoveryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.backupManager.discoverBackupsAsync()
            guard !Task.isCancelled else { return }
            self.backups = self.backupManager.backups
            self.loadError = self.backupManager.lastError
            self.reconcileSelectedBackupAfterReload()
            self.resolveBackupSizesInBackground(for: self.backups)
        }
    }

    private func reconcileSelectedBackupAfterReload() {
        guard let selectedBackup else { return }
        guard backups.contains(where: { $0.id == selectedBackup.id && $0.path == selectedBackup.path }) else {
            clearBrowserState()
            return
        }
    }

    private func resolveBackupSizesInBackground(for snapshot: [BackupInfo]) {
        guard !snapshot.isEmpty else { return }
        let snapshotIds = Set(snapshot.map(\.id))
        sizeResolutionTask = Task.detached(priority: .utility) { [weak self] in
            for backup in snapshot {
                if Task.isCancelled { return }
                let sized = backup.withSize(FileManager.default.directorySize(at: backup.path))
                if Task.isCancelled { return }
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    let currentIds = Set(self.backups.map(\.id))
                    guard currentIds == snapshotIds,
                          let idx = self.backups.firstIndex(where: { $0.id == sized.id }) else { return }
                    self.backups[idx] = sized
                    self.backupManager.backups = self.backups
                }
            }
        }
    }

    func openExistingBackupFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Use Folder"
        panel.message = "Pick a folder containing iOS backups, or a single UDID backup folder."

        guard panel.runModal() == .OK, let url = panel.url else { return }
        let path = url.path

        let target: String
        if BackupManager.looksLikeBackupFolder(path) {
            // User picked a single UDID backup. Point the directory at its parent so
            // sibling backups also appear, and discovery falls into the normal path.
            target = (path as NSString).deletingLastPathComponent
        } else {
            target = path
        }

        UserDefaults.standard.set(target, forKey: BackupManager.backupDirectoryUserDefaultsKey)
        loadBackups()
        if backups.isEmpty {
            alertMessage = loadError ?? "No backups found in \(target)."
            showAlert = true
        }
    }

    func createBackup(udid: String, incremental: Bool = false, preferNetwork: Bool = false, encrypted: Bool = false, isResume: Bool = false, device: DeviceInfo? = nil) async {
        let request = BackupRequest(
            id: UUID(),
            udid: udid,
            incremental: incremental,
            preferNetwork: preferNetwork,
            encrypted: encrypted,
            isResume: isResume,
            device: device
        )
        latestBackupRequests[udid] = request

        await withTaskCancellationHandler {
            guard !Task.isCancelled else { return }

            switch jobQueue.enqueue(udid: udid) {
            case .duplicate:
                requestTracker.registerWaiter(request.id, udid: udid)
                await withCheckedContinuation { continuation in
                    backupJobWaiters[udid, default: []].append(
                        BackupJobWaiter(requestID: request.id, continuation: continuation)
                    )
                    if Task.isCancelled {
                        cancelBackupRequest(udid: udid, requestID: request.id)
                    }
                }
            case .queued(let position):
                requestTracker.registerOwner(request.id, udid: udid)
                pendingBackupRequests[udid] = request
                backupActivities[udid] = BackupActivity(
                    udid: udid,
                    state: .queued(position: position),
                    progressText: "Queued",
                    progressFraction: nil,
                    isResume: request.isResume,
                    errorMessage: nil
                )
                refreshLegacyProgressState()
                await withCheckedContinuation { continuation in
                    backupCompletionContinuations[udid] = continuation
                    if Task.isCancelled {
                        cancelBackupRequest(udid: udid, requestID: request.id)
                    }
                }
            case .started:
                requestTracker.registerOwner(request.id, udid: udid)
                pendingBackupRequests[udid] = request
                backupActivities[udid] = BackupActivity(
                    udid: udid,
                    state: .running,
                    progressText: request.isResume ? "Preparing to resume..." : "Preparing...",
                    progressFraction: nil,
                    isResume: request.isResume,
                    errorMessage: nil
                )
                refreshLegacyProgressState()
                await withCheckedContinuation { continuation in
                    backupCompletionContinuations[udid] = continuation
                    let task = Task { [weak self] in
                        guard let self else { return }
                        await self.runBackupJob(udid: udid)
                    }
                    backupJobTasks[udid] = task
                    if Task.isCancelled {
                        cancelBackupRequest(udid: udid, requestID: request.id)
                    }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelBackupRequest(udid: udid, requestID: request.id)
            }
        }
    }

    func activity(for udid: String) -> BackupActivity? {
        backupActivities[udid]
    }

    func isBackupActive(for udid: String) -> Bool {
        backupActivities[udid]?.isActive == true
    }

    func dismissActivity(for udid: String) {
        backupActivities.removeValue(forKey: udid)
    }

    func cancelBackup(udid: String) {
        switch jobQueue.cancel(udid: udid) {
        case .removedQueued:
            pendingBackupRequests.removeValue(forKey: udid)
            requestTracker.finish(udid: udid)
            backupCompletionContinuations.removeValue(forKey: udid)?.resume()
            resumeBackupWaiters(for: udid)
            updateActivity(udid: udid) {
                $0.state = .cancelled
                $0.progressText = "Cancelled"
            }
            renumberQueuedActivities()
            refreshLegacyProgressState()
        case .cancelRunning:
            if let manager = backupManagers[udid] {
                manager.cancelBackup()
            } else {
                // A queued job is marked running when it is promoted, just before
                // its task creates a BackupManager. Preserve cancellation through
                // that handoff instead of letting the promoted job start anyway.
                backupJobTasks[udid]?.cancel()
            }
            updateActivity(udid: udid) {
                $0.isCancelling = true
                $0.isAwaitingPasscode = false
                $0.progressText = "Cancelling..."
            }
        case .notFound:
            break
        }
    }

    func resumeBackup(udid: String, preferNetwork: Bool = false, encrypted: Bool = false, device: DeviceInfo? = nil) async {
        // If a stale .cancelled activity exists the job slot may still be held
        // in jobQueue (finishBackupJob not yet called from runBackupJob because
        // the drain task is still in-flight). Force-eject it so enqueue returns
        // .started instead of .duplicate — which would silently discard the resume.
        if backupActivities[udid]?.state == .cancelled {
            jobQueue.finish(udid: udid)
            backupActivities.removeValue(forKey: udid)
        }
        await createBackup(
            udid: udid,
            incremental: false,
            preferNetwork: preferNetwork,
            encrypted: encrypted,
            isResume: true,
            device: device
        )
    }

    private func cancelBackupRequest(udid: String, requestID: UUID) {
        switch requestTracker.cancel(requestID, udid: udid) {
        case .cancelJob:
            cancelBackup(udid: udid)
        case .detachRequest:
            if pendingBackupRequests[udid]?.id == requestID {
                backupCompletionContinuations.removeValue(forKey: udid)?.resume()
            } else if let index = backupJobWaiters[udid]?.firstIndex(where: { $0.requestID == requestID }) {
                let waiter = backupJobWaiters[udid]?.remove(at: index)
                if backupJobWaiters[udid]?.isEmpty == true {
                    backupJobWaiters.removeValue(forKey: udid)
                }
                waiter?.continuation.resume()
            }
        case .notFound:
            break
        }
    }

    private func runBackupJob(udid: String) async {
        guard !Task.isCancelled else {
            updateActivity(udid: udid) {
                $0.state = .cancelled
                $0.progressText = "Cancelled"
            }
            finishBackupJob(udid: udid)
            return
        }
        guard let request = pendingBackupRequests[udid] else {
            finishBackupJob(udid: udid)
            return
        }

        let manager = BackupManager()
        backupManagers[udid] = manager
        let isResume = request.isResume
        var baselineFraction: Double = 0.0
        if isResume {
            let stats = await Task.detached(priority: .utility) {
                BackupManager.incompleteBackupStats(for: udid)
            }.value
            if let stats {
                if let device = request.device, let calculatedFraction = stats.completionFraction(for: device) {
                    // Accurately reflect preserved progress up to 99%
                    baselineFraction = min(max(calculatedFraction, 0.05), 0.99)
                } else if stats.totalBytes > 1_000_000_000 {
                    // Fallback when device capacity is unknown: scale generously up to 95%
                    baselineFraction = min(Double(stats.totalBytes) / 70_000_000_000.0, 0.95)
                    baselineFraction = max(baselineFraction, 0.10)
                } else if stats.fileCount > 5000 {
                    baselineFraction = 0.10
                } else {
                    baselineFraction = 0.05
                }
            } else {
                baselineFraction = 0.05
            }
        }
        updateActivity(udid: udid) {
            $0.state = .running
            $0.isResume = isResume
            $0.resumeBaselineFraction = baselineFraction
            $0.progressText = isResume ? "Resuming..." : "Preparing..."
        }
        refreshLegacyProgressState()

        let success: Bool
        if request.isResume {
            success = await manager.resumeIncompleteBackup(
                udid: udid,
                encrypted: request.encrypted,
                preferNetwork: request.preferNetwork
            ) { [weak self, weak manager] text in
                guard let manager else { return }
                self?.updateBackupProgress(udid: udid, text: text, manager: manager)
            }
        } else if request.incremental {
            success = await manager.createIncrementalBackup(udid: udid, preferNetwork: request.preferNetwork) { [weak self, weak manager] text in
                guard let manager else { return }
                self?.updateBackupProgress(udid: udid, text: text, manager: manager)
            }
        } else {
            success = await manager.createBackup(udid: udid, encrypted: request.encrypted, preferNetwork: request.preferNetwork) { [weak self, weak manager] text in
                guard let manager else { return }
                self?.updateBackupProgress(udid: udid, text: text, manager: manager)
            }
        }

        if success {
            updateActivity(udid: udid) {
                $0.isCancelling = false
                $0.state = .completed
                $0.progressText = "Completed"
                $0.progressFraction = 1
            }
            loadBackups()
        } else if manager.lastOperationWasCancelled {
            updateActivity(udid: udid) {
                $0.isCancelling = false
                $0.state = .cancelled
                $0.progressText = "Stopped (Progress Saved)"
            }
        } else {
            let error = manager.lastBackupFailure?.message ?? manager.lastError ?? "Backup failed"
            updateActivity(udid: udid) {
                $0.isCancelling = false
                $0.state = .failed
                $0.progressText = "Failed"
                $0.errorMessage = error
            }
            if let failure = manager.lastBackupFailure {
                failedBackupRequests[failure.id] = request
                backupIssue = failure
            }
        }

        finishBackupJob(udid: udid)
    }

    private func finishBackupJob(udid: String) {
        finalizationTasks.removeValue(forKey: udid)?.cancel()
        requestTracker.finish(udid: udid)
        pendingBackupRequests.removeValue(forKey: udid)
        backupManagers.removeValue(forKey: udid)
        backupJobTasks.removeValue(forKey: udid)
        backupCompletionContinuations.removeValue(forKey: udid)?.resume()
        resumeBackupWaiters(for: udid)
        let nextUDID = jobQueue.finish(udid: udid)
        renumberQueuedActivities()
        refreshLegacyProgressState()

        if let nextUDID {
            let task = Task { [weak self] in
                guard let self else { return }
                await self.runBackupJob(udid: nextUDID)
            }
            backupJobTasks[nextUDID] = task
        }
    }

    private func updateActivity(udid: String, update: (inout BackupActivity) -> Void) {
        guard var activity = backupActivities[udid] else { return }
        guard !activity.isCancelling else { return }
        update(&activity)
        backupActivities[udid] = activity
    }

    private func resumeBackupWaiters(for udid: String) {
        let waiters = backupJobWaiters.removeValue(forKey: udid) ?? []
        waiters.forEach { $0.continuation.resume() }
    }

    private func renumberQueuedActivities() {
        for (offset, udid) in jobQueue.queuedUDIDs.enumerated() {
            updateActivity(udid: udid) {
                $0.state = .queued(position: offset + 1)
                $0.progressText = "Queued · #\(offset + 1)"
            }
        }
    }

    private func refreshLegacyProgressState() {
        let active = backupActivities.values.filter(\.isActive)
        isCreating = !active.isEmpty
        let representative = active.first(where: { $0.state == .running }) ?? active.first
        progressText = representative?.progressText ?? ""
        progressFraction = representative?.progressFraction
    }

    private func recoveryUdid(for issue: BackupManager.BackupFailure) -> String? {
        issue.udid ?? recoveryRequest(for: issue)?.udid
    }

    private func recoveryRequest(for issue: BackupManager.BackupFailure) -> BackupRequest? {
        if let request = failedBackupRequests[issue.id] { return request }
        if let udid = issue.udid { return latestBackupRequests[udid] }
        return latestBackupRequests.count == 1 ? latestBackupRequests.values.first : nil
    }

    var displayProgressText: String {
        guard let progressFraction else { return "Backing up" }
        return "Backing up \(Int(progressFraction * 100))%"
    }

    var displayProgressFraction: Double {
        guard let progressFraction else { return 0.05 }
        return min(max(progressFraction, 0.05), 1.0)
    }

    private func updateBackupProgress(udid: String, text: String, manager: BackupManager) {
        let lower = text.lowercased()
        let awaitingPasscode = lower.contains("passcode")
            || lower.contains("pin")
            || lower.contains("trust")
            || lower.contains("unlock")
            || lower.contains("not paired")
            || lower.contains("pairing")
        updateActivity(udid: udid) { activity in
            activity.progressText = text
            if awaitingPasscode {
                activity.isAwaitingPasscode = true
            }
            if let details = PyMobileDevice.parseProgressDetails(from: text) {
                // If we receive active transfer speed or progress, user has completed unlocking
                if details.speed != nil || details.fraction > 0.001 {
                    activity.isAwaitingPasscode = false
                }
                // Ignore transient sub-phase 100% resets unless truly completing
                if details.fraction >= 0.99 && activity.progressFraction ?? 0 < 0.85 {
                    // Transient 100% on metadata preparation phase - do not jump UI to 100%
                } else {
                    let current = activity.progressFraction ?? 0.0
                    activity.progressFraction = max(current, details.fraction)
                }
                if let eta = details.eta { activity.eta = eta }
                if let speed = details.speed { activity.speed = speed }
            } else if let pct = PyMobileDevice.parseProgress(from: text) {
                if pct > 0.001 {
                    activity.isAwaitingPasscode = false
                }
                if pct >= 0.99 && activity.progressFraction ?? 0 < 0.85 {
                    // Transient subphase
                } else {
                    let current = activity.progressFraction ?? 0.0
                    activity.progressFraction = max(current, pct)
                }
            } else if manager.backupPercent > 0 {
                activity.isAwaitingPasscode = false
                let current = activity.progressFraction ?? 0.0
                activity.progressFraction = max(current, manager.backupPercent)
            }

            if activity.isFinalizing {
                startFinalizationWatchdogIfNeeded(udid: udid)
            }
        }
        refreshLegacyProgressState()
    }

    private func startFinalizationWatchdogIfNeeded(udid: String) {
        guard finalizationTasks[udid] == nil else { return }
        let backupDir = BackupManager.activeBackupDir
        let tracker = FinalizationProgressTracker(backupDirectory: backupDir, udid: udid)

        finalizationTasks[udid] = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if Task.isCancelled { break }
                let metrics = tracker.sampleMetrics()
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    guard let metrics else { return }
                    self.updateActivity(udid: udid) { activity in
                        guard case .running = activity.state else { return }
                        activity.finalizationMetrics = metrics
                    }
                    self.refreshLegacyProgressState()
                }
            }
        }
    }

    func runFullBackup(for issue: BackupManager.BackupFailure) async {
        guard let udid = recoveryUdid(for: issue) else {
            backupIssue = BackupManager.BackupFailure(
                title: "Could Not Start Full Backup",
                message: "Phosphor could not identify which device needs the full backup. Re-select the device and start a full backup manually.",
                technicalDetails: issue.technicalDetails,
                recoveryAction: nil
            )
            return
        }
        let request = recoveryRequest(for: issue)
        backupIssue = nil
        await createBackup(
            udid: udid,
            incremental: false,
            preferNetwork: request?.preferNetwork ?? false,
            encrypted: request?.encrypted ?? false
        )
    }

    func resumeBackup(for issue: BackupManager.BackupFailure) async {
        guard let udid = recoveryUdid(for: issue) else {
            backupIssue = BackupManager.BackupFailure(
                title: "Could Not Resume Backup",
                message: "Phosphor could not identify which device needs to resume the backup. Re-select the device and start a backup manually.",
                technicalDetails: issue.technicalDetails,
                recoveryAction: nil
            )
            return
        }
        let request = recoveryRequest(for: issue)
        backupIssue = nil
        await resumeBackup(
            udid: udid,
            preferNetwork: request?.preferNetwork ?? false,
            encrypted: request?.encrypted ?? false
        )
    }

    func deleteIncompleteBackupAndRunFull(for issue: BackupManager.BackupFailure) async {
        guard let udid = recoveryUdid(for: issue), let path = issue.recoveryPath else {
            backupIssue = BackupManager.BackupFailure(
                title: "Could Not Move Incomplete Backup",
                message: "Phosphor could not identify the incomplete backup folder. Delete it manually or choose another backup folder, then run a full backup again.",
                technicalDetails: issue.technicalDetails,
                recoveryAction: .openBackupSettings
            )
            return
        }
        do {
            let request = recoveryRequest(for: issue)
            let recoveryRoot = (path as NSString).deletingLastPathComponent
            try BackupManager.deleteIncompleteBackup(for: udid, expectedPath: path, in: recoveryRoot)
            backupIssue = nil
            loadBackups()
            await createBackup(
                udid: udid,
                incremental: false,
                preferNetwork: request?.preferNetwork ?? false,
                encrypted: request?.encrypted ?? false
            )
        } catch {
            backupIssue = BackupManager.BackupFailure(
                title: "Could Not Move Incomplete Backup",
                message: "Phosphor could not move the incomplete backup folder to Trash. Choose another backup folder or move it manually, then try a full backup again.",
                technicalDetails: error.localizedDescription,
                recoveryAction: .openBackupSettings,
                udid: udid,
                recoveryPath: path
            )
        }
    }

    func retryBackup(for issue: BackupManager.BackupFailure) async {
        guard let request = recoveryRequest(for: issue) else { return }
        backupIssue = nil
        await createBackup(
            udid: request.udid,
            incremental: request.incremental,
            preferNetwork: request.preferNetwork,
            encrypted: request.encrypted
        )
    }

    // MARK: - Browsing

    private func clearBrowserState() {
        browserLoadTask?.cancel()
        browserLoadTask = nil
        domainSizeTask?.cancel()
        domainSizeTask = nil
        searchSizeTask?.cancel()
        searchSizeTask = nil
        selectedBackup = nil
        queryStore = nil
        browserDomains = []
        browserFiles = []
        currentDomain = nil
        searchQuery = ""
        searchResults = []
    }

    @discardableResult
    func openBackupBrowser(_ backup: BackupInfo) -> Bool {
        clearBrowserState()

        // An encrypted backup that has not been unlocked this session needs a
        // password before anything can be read. Ask for it instead of reporting
        // a failure the user cannot act on.
        if backup.isEncrypted && !BackupUnlockStore.shared.isUnlocked(backup.path) {
            // A remembered password unlocks silently; otherwise ask.
            if !unlockFromKeychain(backup) {
                unlockError = nil
                pendingUnlock = backup
                return false
            }
        }

        guard let manifest = backupManager.openManifest(for: backup) else {
            alertMessage = backupManager.lastError ?? "Failed to open backup."
            showAlert = true
            return false
        }
        let store = ManifestQueryStore(manifest: manifest)
        queryStore = store
        selectedBackup = backup

        browserLoadTask?.cancel()
        browserLoadTask = Task { [weak self] in
            do {
                let domains = try await store.domains()
                if Task.isCancelled { return }
                self?.browserDomains = domains
            } catch {
                guard let self else { return }
                self.clearBrowserState()
                self.alertMessage = "Failed to read backup: \(error.localizedDescription)"
                self.showAlert = true
            }
        }
        return true
    }

    /// Derive the backup's keys and open it. Key derivation runs two PBKDF2 chains,
    /// so it is deliberately slow and belongs off the main actor.
    func submitUnlock(password: String, remember: Bool) async {
        guard let backup = pendingUnlock, !password.isEmpty else { return }
        isUnlocking = true
        unlockError = nil
        defer { isUnlocking = false }

        let path = backup.path
        do {
            try await Task.detached(priority: .userInitiated) { () throws -> Void in
                // Keep the decryptor in BackupUnlockStore. Returning it from this
                // detached task would cross the MainActor boundary with a non-Sendable value.
                _ = try BackupUnlockStore.shared.unlock(backupPath: path, password: password)
            }.value
        } catch {
            unlockError = error.localizedDescription
            return
        }

        if remember {
            // Best effort: a Keychain refusal must not block a successful unlock.
            BackupPasswordKeychain.save(password: password, backupPath: path)
        }
        pendingUnlock = nil
        openBackupBrowser(backup)
    }

    func cancelUnlock() {
        pendingUnlock = nil
        unlockError = nil
    }

    /// Try a password the user previously chose to remember. Returns false when
    /// nothing is stored or the stored password no longer works.
    func unlockFromKeychain(_ backup: BackupInfo) -> Bool {
        guard let stored = BackupPasswordKeychain.password(for: backup.path) else { return false }
        guard (try? BackupUnlockStore.shared.unlock(backupPath: backup.path, password: stored)) != nil else {
            BackupPasswordKeychain.delete(backupPath: backup.path)
            return false
        }
        return true
    }

    func browseDomain(_ domain: String) {
        domainSizeTask?.cancel()
        currentDomain = domain
        let token = UUID()
        currentDomainToken = token
        browserFiles = []
        guard let store = queryStore else { return }
        domainSizeTask = Task { [weak self] in
            do {
                let entries = try await store.files(inDomain: domain)
                try Task.checkCancellation()
                guard let self, self.currentDomainToken == token else { return }
                self.browserFiles = entries
                let chunkSize = 500
                var idx = 0
                while idx < entries.count {
                    try Task.checkCancellation()
                    let end = Swift.min(idx + chunkSize, entries.count)
                    let sized = try await store.resolveSizes(for: Array(entries[idx..<end]))
                    guard self.currentDomainToken == token else { return }
                    self.splice(&self.browserFiles, sized, at: idx)
                    idx = end
                }
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.currentDomainToken == token else { return }
                self.alertMessage = error.localizedDescription
                self.showAlert = true
            }
        }
    }

    /// Navigate out of the current domain, cancelling any in-flight size work.
    func leaveDomain() {
        domainSizeTask?.cancel()
        domainSizeTask = nil
        currentDomainToken = UUID()
        currentDomain = nil
        browserFiles = []
    }

    func searchBackup(_ query: String) {
        searchSizeTask?.cancel()
        let token = UUID()
        currentSearchToken = token
        guard !query.isEmpty, let store = queryStore else {
            searchResults = []
            return
        }
        searchResults = []
        searchSizeTask = Task { [weak self] in
            do {
                let entries = try await store.search(query)
                try Task.checkCancellation()
                guard let self, self.currentSearchToken == token else { return }
                self.searchResults = entries
                let chunkSize = 500
                var idx = 0
                while idx < entries.count {
                    try Task.checkCancellation()
                    let end = Swift.min(idx + chunkSize, entries.count)
                    let sized = try await store.resolveSizes(for: Array(entries[idx..<end]))
                    guard self.currentSearchToken == token else { return }
                    self.splice(&self.searchResults, sized, at: idx)
                    idx = end
                }
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.currentSearchToken == token else { return }
                self.searchResults = []
            }
        }
    }

    /// Overwrite entries in `destination` starting at `offset` with `sized`,
    /// bounds-checked so a stale chunk from an obsolete query cannot corrupt
    /// the freshly published array.
    private func splice(
        _ destination: inout [BackupManifest.FileEntry],
        _ sized: [BackupManifest.FileEntry],
        at offset: Int
    ) {
        guard destination.count >= offset + sized.count else { return }
        for (i, entry) in sized.enumerated() {
            let idx = offset + i
            if destination[idx].id == entry.id {
                destination[idx] = entry
            }
        }
    }

    func extractFiles(_ files: [BackupManifest.FileEntry], to destination: String) -> Int {
        guard let backup = selectedBackup else { return 0 }
        do {
            return try backupManager.extractFiles(from: backup, entries: files, to: destination)
        } catch {
            alertMessage = error.localizedDescription
            showAlert = true
            return 0
        }
    }

    func deleteBackup(_ backup: BackupInfo) {
        do {
            try backupManager.deleteBackup(backup)
            loadBackups()
        } catch {
            alertMessage = "Failed to delete: \(error.localizedDescription)"
            showAlert = true
        }
    }

    var totalSize: String {
        if backups.contains(where: { !$0.sizeResolved }) {
            return "calculating..."
        }
        return backupManager.totalBackupSize.formattedFileSize
    }
}

/// Serializes Manifest.db access off the main actor. All SQLite queries and any
/// FileManager stat calls for size resolution run inside the actor's executor,
/// leaving the UI free from disk I/O.
actor ManifestQueryStore {
    private let manifest: BackupManifest

    init(manifest: BackupManifest) {
        self.manifest = manifest
    }

    func domains() throws -> [String] {
        try manifest.domains()
    }

    func files(inDomain domain: String) throws -> [BackupManifest.FileEntry] {
        try manifest.files(inDomain: domain)
    }

    func children(ofPath path: String, inDomain domain: String) throws -> [BackupManifest.FileEntry] {
        try manifest.children(ofPath: path, inDomain: domain)
    }

    func search(_ query: String) throws -> [BackupManifest.FileEntry] {
        try manifest.search(query)
    }

    /// Resolve on-disk sizes for one chunk. Callers drive chunking from the
    /// main actor so they can splice updates into the published array and
    /// react to cancellation without the store holding a closure.
    func resolveSizes(for slice: [BackupManifest.FileEntry]) throws -> [BackupManifest.FileEntry] {
        try Task.checkCancellation()
        return manifest.resolvingSizes(for: slice)
    }

    func readablePath(for entry: BackupManifest.FileEntry) throws -> String {
        try Task.checkCancellation()
        return try manifest.readablePath(for: entry)
    }

    func extractFile(_ entry: BackupManifest.FileEntry, to destination: String) throws {
        try manifest.extractFile(entry, to: destination)
    }
}
