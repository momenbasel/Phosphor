import AppKit
import Foundation
import SwiftUI
@preconcurrency import UserNotifications

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
        /// Files already on disk when this resume started, from the pre-resume
        /// incomplete-backup stats. Real baseline for the resume phase detail.
        var resumeFileBaseline: Int?
        /// Bytes already on disk when this resume started.
        var resumeBytesBaseline: UInt64?
        /// Target device's total used bytes (`totalDiskCapacity - availableDiskSpace`), queried independently for this backup.
        var targetDeviceUsedBytes: UInt64?
        /// Total bytes written to disk by the active backup process in this session (`proc_pid_rusage` `ri_diskio_byteswritten`).
        var sessionBytesWritten: UInt64 = 0
        /// Rolling 1-second samples of `(Date, sessionBytesWritten)` from kernel process I/O accounting,
        /// used to compute live `MB/s` transfer speed and true byte-based ETA without relying on `tqdm` integer `%` steps.
        var byteWriteSamples: [(date: Date, bytes: UInt64)] = []
        /// Last `sessionBytesWritten` value at which the backup row's displayed on-disk size was refreshed.
        var lastRowSizeUpdateBytes: UInt64 = 0
        /// Rolling samples of `(Date, sessionFraction)` once active transfer begins (`sessionFraction > 0.01`),
        /// used to compute a coherent ETA unaffected by pre-transfer manifest reconciliation dead time.
        var transferFractionSamples: [(date: Date, fraction: Double)] = []
        /// First post-reconciliation transfer sample (`sessionFraction > 0.005`), retained for the entire session
        /// so ETA never blanks out when integer percentage steps take several minutes on 200+ GB backups.
        var transferAnchorSample: (date: Date, fraction: Double)?
        /// Last computed remaining ETA seconds and the timestamp when it was computed, allowing smooth
        /// countdown between integer percentage updates without flickering to nil.
        var lastComputedEtaSeconds: TimeInterval?
        var lastComputedEtaAt: Date?
        var isAwaitingPasscode: Bool = false
        var hasReceivedTransferProgress: Bool = false
        var hasNotifiedPasscodePrompt: Bool = false
        var errorMessage: String?

        // Enhanced phase tracking
        var manifestSizeBytes: Int64 = 0
        var lastSizeUpdate: Date?
        var processAlive: Bool = true
        var lastProgressUpdate: Date = Date()

        // Observability integration
        var observabilityCoordinator: BackupObservabilityCoordinator?

        /// Set while a pause/restart is in flight. The backup process dies
        /// asynchronously, so without this the activity sits on a stale
        /// "running" state: the button stays live, a second click stacks, and
        /// a slow termination reads as a stall.
        enum Transition: Equatable { case pausing, restarting }
        var transition: Transition?
        var transitionStartTime: Date?
        var isBusy: Bool { transition != nil }
        /// Explicit phase override set by progress signals (sanitization, fallback, terminal).
        var explicitPhase: BackupPhase?
        var sanitizationScanned: Int?
        var sanitizationCleaned: Int?
        var sanitizationWalCheckpointed: Bool?
        var fallbackReason: String?
        var startTime: Date = Date()
        /// Updated on every 1-second liveness tick so SwiftUI sees a value mutation on `BackupActivity`
        /// and re-renders elapsed time, transition countdowns, and live ETA every second.
        var currentTick: Date = Date()
        var terminalPhaseDetail: PhaseDetail?
        var currentDomain: String?

        var observabilityPhase: BackupPhase {
            if let explicitPhase { return explicitPhase }
            if isFinalizing { return .finalization }
            if isResume { return .incrementalResume }
            return .fullBackup
        }

        // Enhanced observability fields
        var phaseMetrics: PhaseMetrics?
        var throughputStats: ThroughputHistory.ThroughputStats?
        var predictiveETA: ThroughputHistory.PredictiveETA?
        var throughputTrend: ThroughputHistory.ThroughputTrend = .insufficient

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

        var isStalled: Bool {
            guard transition == nil else { return false }
            guard case .running = state else { return false }
            return currentTick.timeIntervalSince(lastProgressUpdate) > 300 // 5 minutes without progress
        }

        var transitionElapsedSeconds: Int? {
            transitionElapsedSeconds(at: currentTick)
        }

        func transitionElapsedSeconds(at now: Date) -> Int? {
            guard let transitionStartTime else { return nil }
            return max(0, Int(now.timeIntervalSince(transitionStartTime)))
        }

        var isQuiet: Bool {
            guard transition == nil else { return false }
            guard case .running = state else { return false }
            let interval = currentTick.timeIntervalSince(lastProgressUpdate)
            return interval > 30 && interval <= 300 // 30 seconds quiet, not yet stalled
        }

        var displayProgressText: String {
            if let transition {
                let elapsed = transitionElapsedSeconds.map { " (\($0)s)" } ?? ""
                switch transition {
                case .pausing:
                    return "Pausing…\(elapsed) · Saving state to disk"
                case .restarting:
                    return "Restarting…\(elapsed) · Preparing fresh session"
                }
            }
            switch state {
            case .queued(let position): return "Queued · #\(position)"
            case .running:
                var components: [String] = []
                
                // Prepend phase info if available
                if let phaseMetrics = phaseMetrics {
                    components.append("\(phaseMetrics.phase.displayName)")
                    if let detail = phaseMetrics.phaseDetail {
                        components.append(detail.description)
                    }
                }
                
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
                } else if isResume {
                    let pct = Int(displayProgressFraction * 100)
                    if resumeBaselineFraction > 0 {
                        components.append("Resuming \(pct)%")
                    } else {
                        components.append("Resuming · Preparing...")
                    }
                } else {
                    let pct = Int(displayProgressFraction * 100)
                    components.append("Backing up \(pct)%")
                }
                if isQuiet {
                    let quietSeconds = Int(Date().timeIntervalSince(lastProgressUpdate))
                    components.append("Waiting for device… (quiet \(quietSeconds)s) · Transfer in progress")
                } else {
                    if !isFinalizing {
                        if let speed, !speed.isEmpty {
                            components.append(speed)
                        }
                        if let eta, !eta.isEmpty {
                            components.append("ETA: \(eta)")
                        }
                    }
                    // Add predictive ETA if available
                    if let predictiveETA = predictiveETA, predictiveETA.confidence != .none {
                        components.append("Predicted: \(predictiveETA.formattedETA) (\(predictiveETA.confidence.rawValue))")
                    }
                    // Add throughput trend
                    if throughputTrend != .insufficient {
                        components.append("Trend: \(throughputTrend.description)")
                    }
                }
                return components.joined(separator: " · ")
            case .completed:
                if let terminalPhaseDetail {
                    return terminalPhaseDetail.description
                }
                return "Completed"
            case .failed: return "Failed"
            case .cancelled: return "Cancelled"
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
                if let targetUsed = targetDeviceUsedBytes, targetUsed > 0, sessionBytesWritten > 0 {
                    let currentOnDisk = (isResume ? (resumeBytesBaseline ?? 0) : 0) + sessionBytesWritten
                    let byteFraction = Double(currentOnDisk) / Double(targetUsed)
                    return min(max(byteFraction, resumeBaselineFraction), 0.99)
                }
                return resumeBaselineFraction > 0 ? resumeBaselineFraction : 0.0
            }
            if isResume && resumeBaselineFraction > 0 {
                // Compute progress over total: baseline + remaining * sessionFraction
                let remainingFraction = 1.0 - resumeBaselineFraction
                var totalFraction = resumeBaselineFraction + (remainingFraction * progressFraction)
                if let targetUsed = targetDeviceUsedBytes, targetUsed > 0, sessionBytesWritten > 0 {
                    let currentOnDisk = (resumeBytesBaseline ?? 0) + sessionBytesWritten
                    let byteFraction = Double(currentOnDisk) / Double(targetUsed)
                    totalFraction = max(totalFraction, byteFraction)
                }
                let bounded = min(max(totalFraction, resumeBaselineFraction), 1.0)
                // Cap in-progress running state at 0.99 so 100% is only shown when state becomes .completed
                return state == .completed ? 1.0 : min(bounded, 0.99)
            }
            var rawFraction = progressFraction
            if let targetUsed = targetDeviceUsedBytes, targetUsed > 0, sessionBytesWritten > 0 {
                let byteFraction = Double(sessionBytesWritten) / Double(targetUsed)
                rawFraction = max(rawFraction, byteFraction)
            }
            let bounded = min(max(rawFraction, 0.0), 1.0)
            return state == .completed ? 1.0 : min(bounded, 0.99)
        }

        /// True when a resumable backup is active but the true baseline fraction
        /// is still calculating in the background.
        var isCalculatingResumeBaseline: Bool {
            isResume && resumeBaselineFraction <= 0.0 && progressFraction == nil
        }

        /// Consolidated ETA string including remaining duration and estimated wall-clock finish time
        /// (with date when crossing midnight or >24h, e.g. "2h 24m (~22:34)" or "14h 10m (~Tomorrow at 10:25)").
        var consolidatedETADescription: String? {
            consolidatedETADescription(at: currentTick)
        }

        func consolidatedETADescription(at now: Date) -> String? {
            if let baseSecs = lastComputedEtaSeconds, let baseAt = lastComputedEtaAt, baseSecs > 0 {
                let elapsedSinceCalc = max(0, now.timeIntervalSince(baseAt))
                let liveSecs = max(30, baseSecs - elapsedSinceCalc)
                let durationStr = liveSecs.formattedDuration
                let finish = now.addingTimeInterval(liveSecs)
                return "\(durationStr) (~\(finish.contextualClockString()))"
            }
            if let eta, !eta.isEmpty, let secs = BackupViewModel.parseEtaToSeconds(eta), secs > 0 {
                let finish = now.addingTimeInterval(secs)
                return "\(eta) (~\(finish.contextualClockString()))"
            }
            return nil
        }

        /// Formatted elapsed time since this backup job started:
        /// - `< 60s`: `"24s elapsed"` (ticks every second)
        /// - `1m ..< 60m`: `"4m 12s elapsed"` (ticks every second during the first hour)
        /// - `1h ..< 24h`: `"2h 14m elapsed"`
        /// - `>= 24h`: `"1d 3h elapsed"`
        var elapsedTimeDescription: String {
            elapsedTimeDescription(at: currentTick)
        }

        func elapsedTimeDescription(at now: Date) -> String {
            let secs = max(0, Int(now.timeIntervalSince(startTime)))
            if secs < 60 {
                return "\(max(1, secs))s elapsed"
            } else if secs < 3600 {
                let m = secs / 60
                let s = secs % 60
                return "\(m)m \(s)s elapsed"
            } else if secs < 86400 {
                let h = secs / 3600
                let m = (secs % 3600) / 60
                return m > 0 ? "\(h)h \(m)m elapsed" : "\(h)h elapsed"
            } else {
                let d = secs / 86400
                let h = (secs % 86400) / 3600
                return h > 0 ? "\(d)d \(h)h elapsed" : "\(d)d elapsed"
            }
        }

        /// Explicit start time + elapsed duration for the active backup subtitle row.
        var activeTimelineDescription: String {
            activeTimelineDescription(at: currentTick)
        }

        func activeTimelineDescription(at now: Date) -> String {
            let startStr = startTime.contextualClockString(includeTodayPrefix: true)
            return "Started \(startStr) (\(elapsedTimeDescription(at: now)))"
        }
    }

    @Published var backups: [BackupInfo] = []
    @Published var selectedBackup: BackupInfo?

    /// Backups eligible for browsing in Data tabs (excludes `.broken` zero-payload directories).
    var browsableBackups: [BackupInfo] {
        backups.filter { $0.healthState != .broken }
    }

    /// Preferred default backup for Data tabs: selects the newest `.complete` backup first,
    /// falling back to `.paused` only when no complete snapshot exists on disk.
    var preferredBrowsableBackup: BackupInfo? {
        browsableBackups.first(where: { $0.healthState == .complete }) ?? browsableBackups.first
    }
    @Published var isCreating = false
    /// True until the initial backup directory scan completes (or while a folder reload is in flight with no loaded list yet).
    /// Prevents starting a new backup before existing complete/paused/broken backups on external disks are known.
    @Published private(set) var isLoadingBackups = true
    @Published private(set) var hasCompletedInitialLoad = false
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
    private var discoveryTask: Task<Void, Never>?
    private var sizeResolutionTasksByPath: [String: Task<Void, Never>] = [:]
    private var resolvedSizesByPath: [String: (size: UInt64, date: Date?)] = [:]
    private var latestBackupRequests: [String: BackupRequest] = [:]
    private var failedBackupRequests: [UUID: BackupRequest] = [:]
    private var jobQueue = BackupJobQueue(maxConcurrent: 2)
    private var requestTracker = BackupRequestTracker()
    private var pendingBackupRequests: [String: BackupRequest] = [:]
    private var backupManagers: [String: BackupManager] = [:]
    private var backupJobTasks: [String: Task<Void, Never>] = [:]
    private var finalizationTasks: [String: Task<Void, Never>] = [:]
    private var livenessTasks: [String: Task<Void, Never>] = [:]
    private var resumeBaselineTasks: [String: Task<Void, Never>] = [:]
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
        let configuration: DeviceBackupConfiguration?

        init(
            id: UUID = UUID(),
            udid: String,
            incremental: Bool = false,
            preferNetwork: Bool = false,
            encrypted: Bool = false,
            isResume: Bool = false,
            device: DeviceInfo? = nil,
            configuration: DeviceBackupConfiguration? = nil
        ) {
            self.id = id
            self.udid = udid
            self.incremental = incremental
            self.preferNetwork = preferNetwork
            self.encrypted = encrypted
            self.isResume = isResume
            self.device = device
            self.configuration = configuration
        }
    }

    private struct BackupJobWaiter {
        let requestID: UUID
        let continuation: CheckedContinuation<Void, Never>
    }

    private var loadedBackupDirectory: String?

    func loadBackups() {
        discoveryTask?.cancel()
        let activeDir = BackupManager.activeBackupDir
        if loadedBackupDirectory != activeDir {
            hasCompletedInitialLoad = false
            backups = []
        }
        if !hasCompletedInitialLoad || backups.isEmpty {
            isLoadingBackups = true
        }
        let cachedSizes = resolvedSizesByPath
        discoveryTask = Task.detached(priority: .userInitiated) { [weak self] in
            let scanned = BackupManager.scanBackupDirectory(at: activeDir)
            if Task.isCancelled { return }
            let hydrated = scanned.backups.map { backup -> BackupInfo in
                if let cached = cachedSizes[backup.path] {
                    // For active or paused backups whose plist date updates mid-run, retain the last resolved
                    // size rather than resetting the row back to "Calculating..." on every refresh.
                    if cached.date == backup.lastBackupDate || cached.size > 0 {
                        return backup.withSize(cached.size)
                    }
                }
                return backup
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.loadedBackupDirectory = activeDir
                self.backupManager.backups = hydrated
                self.backupManager.lastError = scanned.error
                self.backups = hydrated
                self.loadError = scanned.error
                self.hasCompletedInitialLoad = true
                self.isLoadingBackups = false
                self.reconcileSelectedBackupAfterReload()
                self.resolveBackupSizesInBackground(for: hydrated)
            }
        }
    }

    /// Ensures the active backup directory has been scanned and `backups` is populated before starting any backup action.
    func ensureBackupsLoaded() async {
        let activeDir = BackupManager.activeBackupDir
        if !hasCompletedInitialLoad || loadedBackupDirectory != activeDir || isLoadingBackups {
            if discoveryTask == nil || loadedBackupDirectory != activeDir {
                loadBackups()
            }
            await discoveryTask?.value
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
        let validPaths = Set(snapshot.map(\.path))
        // Cancel tasks only for backup paths that no longer exist in the snapshot
        for (path, task) in sizeResolutionTasksByPath where !validPaths.contains(path) {
            task.cancel()
            sizeResolutionTasksByPath.removeValue(forKey: path)
        }

        let unresolved = snapshot.filter { !$0.sizeResolved }
        guard !unresolved.isEmpty else { return }

        // Resolve each backup's size independently in its own background task so a 400k-file active backup
        // never blocks broken or archived backups from resolving immediately, and mid-run loadBackups()
        // refreshes never cancel in-flight size calculations.
        for backup in unresolved {
            let path = backup.path
            guard sizeResolutionTasksByPath[path] == nil else { continue }
            let backupId = backup.id
            let backupDate = backup.lastBackupDate
            sizeResolutionTasksByPath[path] = Task.detached(priority: .utility) { [weak self] in
                let computedSize = FileManager.default.directorySize(at: path)
                if Task.isCancelled { return }
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.sizeResolutionTasksByPath.removeValue(forKey: path)
                    self.resolvedSizesByPath[path] = (computedSize, backupDate)
                    guard let idx = self.backups.firstIndex(where: { $0.id == backupId && $0.path == path }) else { return }
                    self.backups[idx] = self.backups[idx].withSize(computedSize)
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
        hasCompletedInitialLoad = false
        backups = []
        loadBackups()
    }

    func createBackup(udid: String, incremental: Bool = false, preferNetwork: Bool = false) async {
        await createBackup(
            udid: udid,
            incremental: incremental,
            preferNetwork: preferNetwork,
            encrypted: false,
            isResume: false,
            device: nil,
            configuration: DeviceBackupConfiguration.load(for: udid)
        )
    }

    func createBackup(udid: String, incremental: Bool = false, preferNetwork: Bool = false, encrypted: Bool = false, isResume: Bool = false, device: DeviceInfo? = nil, configuration: DeviceBackupConfiguration? = nil) async {
        // Wait for the backup directory scan to finish so existing complete/paused/broken backups are loaded first
        await ensureBackupsLoaded()

        // If a paused resumable backup already exists for this device and caller did not explicitly request a full non-resume run,
        // promote to resume so we never blindly start a fresh session while unaware of paused progress.
        let effectiveIsResume: Bool = {
            if isResume { return true }
            if incremental {
                if backups.contains(where: { !$0.isArchivedSnapshot && ($0.udid == udid || $0.id == udid) && $0.healthState == .paused }) {
                    return true
                }
            }
            return false
        }()

        let request = BackupRequest(
            id: UUID(),
            udid: udid,
            incremental: incremental,
            preferNetwork: preferNetwork,
            encrypted: encrypted,
            isResume: effectiveIsResume,
            device: device,
            configuration: configuration
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

    func hasResumableBackup(for udid: String) -> Bool {
        guard !isBackupActive(for: udid) else { return false }
        if let existing = backups.first(where: { !$0.isArchivedSnapshot && ($0.udid == udid || $0.id == udid) }) {
            return existing.healthState == .paused
        }
        if case .incomplete(let path) = BackupManager.backupMetadataHealth(for: udid) {
            return BackupManager.incompleteBackupHasPayloadData(path)
        }
        return false
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
            }
            backupJobTasks[udid]?.cancel()
            updateActivity(udid: udid) {
                $0.progressText = "Pausing..."
                $0.transition = .pausing
                $0.transitionStartTime = Date()
            }
        case .notFound:
            break
        }
    }

    func resumeBackup(udid: String, preferNetwork: Bool = false, encrypted: Bool = false, device: DeviceInfo? = nil, configuration: DeviceBackupConfiguration? = nil) async {
        let resolvedConfig = configuration
            ?? latestBackupRequests[udid]?.configuration
            ?? DeviceBackupConfiguration.load(for: udid)
        await createBackup(
            udid: udid,
            incremental: false,
            preferNetwork: preferNetwork,
            encrypted: encrypted,
            isResume: true,
            device: device,
            configuration: resolvedConfig
        )
    }

    /// Resume click while a job is stalled: the in-flight job is wedged, so a
    /// second enqueue returns .duplicate and parks a waiter on a job that may
    /// never finish — the click looks dead. Cancel it, wait for teardown (the
    /// queue entry is removed on a task hop), then resume fresh.
    /// Never during finalization: cancelling there discards a completed backup.
    func restartStalledBackup(udid: String, device: DeviceInfo? = nil) async {
        guard activity(for: udid)?.isStalled == true else {
            await resumeBackup(udid: udid, device: device)
            return
        }
        guard activity(for: udid)?.isNonResumableFinalizationPhase != true else { return }
        cancelBackup(udid: udid)
        // The user pressed Resume, not Pause: label the teardown accordingly.
        updateActivity(udid: udid) {
            $0.transition = .restarting
            $0.transitionStartTime = Date()
            $0.progressText = "Restarting..."
        }
        for _ in 0..<20 where backupActivities[udid]?.isActive == true {
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        await resumeBackup(udid: udid, device: device)
    }

    /// Human-readable diagnosis of a stalled or failing backup: what phase it
    /// was in, when it last made progress, what the phase timeline and
    /// throughput samples say. This is the answer to "why is Resume doing
    /// nothing" — previously that state produced no visible information at all.
    func diagnosisText(for udid: String) -> String? {
        guard let activity = backupActivities[udid] else {
            // If there's no in-flight activity, provide diagnosis based on preserved backup on disk
            guard let backup = backups.first(where: { $0.udid == udid || $0.id == udid }) else {
                return nil
            }
            var lines: [String] = []
            lines.append("Device: \(backup.deviceName) (\(backup.modelName))")
            lines.append("Identifier: \(backup.deviceIdentityLabel)")
            switch backup.healthState {
            case .complete:
                lines.append("Status: Complete backup (\(backup.isFullBackup ? "single session" : "multi-session / incremental"))")
            case .paused:
                lines.append("Status: Paused backup (resumable)")
            case .broken:
                lines.append("Status: Broken backup (metadata exists, zero payload files on disk)")
            }
            lines.append("Path: \(backup.path)")
            lines.append("Last modified: \(backup.dateString) (\(backup.relativeDate))")
            lines.append("Size on disk: \(backup.sizeResolved ? backup.sizeString : "Calculating...")")
            if backup.appCount > 0 {
                lines.append("Installed applications: \(backup.appCount)")
            }
            lines.append("Encrypted: \(backup.isEncrypted ? "Yes" : "No")")
            lines.append("")
            lines.append("Activity: Idle (No live backup process currently active).")
            return lines.joined(separator: "\n")
        }
        var lines: [String] = []
        lines.append("State: \(activity.state)")
        lines.append("Phase: \((activity.phaseMetrics?.phase ?? activity.observabilityPhase).displayName)")
        lines.append("Last progress: \(activity.progressText)")
        if let fraction = activity.progressFraction {
            lines.append("Progress fraction: \(Int(fraction * 100))%")
        }
        if let transition = activity.transition {
            let elapsed = activity.transitionElapsedSeconds.map { " (\($0)s)" } ?? ""
            lines.append("Transition: \(transition == .restarting ? "restarting" : "pausing")\(elapsed)")
        }
        lines.append("Last progress update: \(Int(Date().timeIntervalSince(activity.lastProgressUpdate)))s ago")
        lines.append("Stalled (no progress for 5+ min): \(activity.isStalled ? "yes" : "no")")
        lines.append("Quiet (waiting for device >30s): \(activity.isQuiet ? "yes" : "no")")
        if activity.sessionBytesWritten > 0 {
            let formattedWritten = ByteCountFormatter.string(fromByteCount: Int64(activity.sessionBytesWritten), countStyle: .file)
            lines.append("Session bytes written (kernel I/O): \(formattedWritten)")
        }
        if let speed = activity.speed { lines.append("Last speed: \(speed)") }
        if let eta = activity.eta { lines.append("Last ETA: \(eta)") }
        if let error = activity.errorMessage { lines.append("Error: \(error)") }

        if let snapshot = activity.observabilityCoordinator?.exportSnapshot() {
            if !snapshot.phaseTransitions.isEmpty {
                lines.append("")
                lines.append("Phase timeline:")
                for transition in snapshot.phaseTransitions {
                    let duration = transition.duration.map { " (\(Int($0))s)" } ?? ""
                    lines.append("  \(transition.from.displayName) -> \(transition.to.displayName) at \(transition.timestamp.formatted(date: .omitted, time: .standard))\(duration)")
                }
            }
            if !snapshot.phaseDurations.isEmpty {
                lines.append("")
                lines.append("Time per phase:")
                for (phase, seconds) in snapshot.phaseDurations.sorted(by: { $0.value > $1.value }) {
                    let name = BackupPhase(rawValue: phase)?.displayName ?? phase
                    lines.append("  \(name): \(seconds.formattedDuration)")
                }
            }
            let stats = snapshot.throughputStats
            if stats.samplesCount > 0 {
                lines.append("")
                lines.append("Throughput (\(stats.samplesCount) samples):")
                lines.append("  last: \(formatBytesPerSecond(stats.currentBytesPerSecond))")
                lines.append("  avg:  \(formatBytesPerSecond(stats.averageBytesPerSecond))")
                lines.append("  peak: \(formatBytesPerSecond(stats.peakBytesPerSecond))")
                if snapshot.throughputTrend != .insufficient {
                    lines.append("  trend: \(snapshot.throughputTrend.description)")
                }
            } else {
                lines.append("")
                lines.append("Throughput: no speed samples received — the backup tool produced no throughput output.")
            }
        }
        return lines.joined(separator: "\n")
    }

    private func formatBytesPerSecond(_ value: Double) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .file) + "/s"
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
        guard !Task.isCancelled else {
            updateActivity(udid: udid) {
                $0.state = .cancelled
                $0.progressText = "Cancelled"
            }
            finishBackupJob(udid: udid)
            return
        }
        updateActivity(udid: udid) {
            $0.state = .running
            $0.isResume = isResume
            $0.resumeBaselineFraction = 0.0
            $0.resumeFileBaseline = nil
            $0.resumeBytesBaseline = nil
            $0.targetDeviceUsedBytes = nil
            $0.sessionBytesWritten = 0
            $0.byteWriteSamples = []
            $0.lastRowSizeUpdateBytes = 0
            $0.transferFractionSamples = []
            $0.transferAnchorSample = nil
            $0.lastComputedEtaSeconds = nil
            $0.lastComputedEtaAt = nil
            $0.eta = nil
            $0.progressText = isResume ? "Resuming..." : "Preparing..."
            $0.lastProgressUpdate = Date()
        }
        startObservability(udid: udid, isResume: isResume)
        startLivenessMonitor(udid: udid)
        let requestDevice = request.device
        let knownDirSize = backups.first(where: { !$0.isArchivedSnapshot && ($0.udid == udid || $0.id == udid) && $0.sizeResolved && $0.size > 0 })?.size
        resumeBaselineTasks[udid]?.cancel()
        resumeBaselineTasks[udid] = Task { [weak self] in
            // Always resolve the target device's own used bytes independently (from passed DeviceInfo or live lockdown disk_usage)
            let deviceUsedFromInfo: UInt64? = {
                guard let dev = requestDevice else { return nil }
                if let total = dev.totalDiskCapacity, let avail = dev.availableDiskSpace, total > avail {
                    return total - avail
                }
                if let totalData = dev.totalDataCapacity, let avail = dev.availableDiskSpace, totalData > avail {
                    return totalData - avail
                }
                if let totalData = dev.totalDataCapacity, totalData > 0 {
                    return totalData
                }
                return nil
            }()
            let resolvedDeviceUsed: UInt64?
            if let deviceUsedFromInfo, deviceUsedFromInfo > 0 {
                resolvedDeviceUsed = deviceUsedFromInfo
            } else {
                resolvedDeviceUsed = await BackupManager.fetchTargetDeviceUsedBytes(for: udid)
            }
            guard !Task.isCancelled, let self else { return }

            if isResume {
                let stats = await Task.detached(priority: .utility) {
                    BackupManager.incompleteBackupStats(for: udid, knownDirectorySize: knownDirSize)
                }.value
                guard !Task.isCancelled else { return }
                var baselineFraction: Double = 0.0
                var resumeFileCount: Int?
                var resumeBytesCount: UInt64?
                if let stats {
                    resumeFileCount = stats.fileCount
                    resumeBytesCount = stats.totalBytes
                    if let targetUsed = resolvedDeviceUsed, targetUsed > 0 {
                        // Self-contained ratio of this backup's on-disk bytes against the target device's own used storage
                        let fraction = Double(stats.totalBytes) / Double(targetUsed)
                        baselineFraction = min(max(fraction, 0.01), 0.99)
                    } else if let device = requestDevice, let calculatedFraction = stats.completionFraction(for: device) {
                        baselineFraction = min(max(calculatedFraction, 0.01), 0.99)
                    } else if stats.fileCount > 5000 {
                        // Only used when the device is unreachable for disk_usage queries
                        baselineFraction = min(Double(stats.fileCount) / 450_000.0, 0.90)
                        baselineFraction = max(baselineFraction, 0.05)
                    } else {
                        baselineFraction = 0.0
                    }
                }
                // Immediately hydrate the active backup row's on-disk size from the fast incompleteBackupStats
                // so the row never sits on "Calculating..." while the external drive is busy resuming.
                if let resumeBytesCount, resumeBytesCount > 0 {
                    let backupPath = BackupManager.backupPath(for: udid)
                    if let idx = self.backups.firstIndex(where: { !$0.isArchivedSnapshot && ($0.udid == udid || $0.id == udid) }) {
                        if !self.backups[idx].sizeResolved || self.backups[idx].size == 0 {
                            self.resolvedSizesByPath[backupPath] = (resumeBytesCount, self.backups[idx].lastBackupDate)
                            self.backups[idx] = self.backups[idx].withSize(resumeBytesCount)
                            self.backupManager.backups = self.backups
                        }
                    }
                }
                self.updateActivity(udid: udid) {
                    $0.targetDeviceUsedBytes = resolvedDeviceUsed
                    $0.resumeBaselineFraction = baselineFraction
                    $0.resumeFileBaseline = resumeFileCount
                    $0.resumeBytesBaseline = resumeBytesCount
                    if let coordinator = $0.observabilityCoordinator {
                        var context = PhaseContext()
                        context.filesResumed = resumeFileCount
                        context.resumeBaselineFraction = baselineFraction > 0 ? baselineFraction : nil
                        context.sanitizationScanned = $0.sanitizationScanned
                        context.sanitizationCleaned = $0.sanitizationCleaned
                        context.sanitizationWalCheckpointed = $0.sanitizationWalCheckpointed
                        context.fallbackReason = $0.fallbackReason
                        context.currentDomain = $0.currentDomain
                        coordinator.updateMetrics(
                            phase: $0.observabilityPhase,
                            progressFraction: $0.progressFraction,
                            bytesTransferred: nil,
                            filesTransferred: nil,
                            totalBytes: nil,
                            totalFiles: nil,
                            currentFile: nil,
                            speedBytesPerSec: $0.speed.flatMap(Self.parseSpeedToBytesPerSecond),
                            speedFilesPerSec: nil,
                            eta: $0.eta.flatMap(Self.parseEtaToSeconds),
                            isFinalizing: $0.isFinalizing,
                            finalizationMetrics: $0.finalizationMetrics,
                            context: context
                        )
                        $0.phaseMetrics = coordinator.phaseMetrics
                    }
                }
                self.refreshLegacyProgressState()
            } else {
                self.updateActivity(udid: udid) {
                    $0.targetDeviceUsedBytes = resolvedDeviceUsed
                }
            }
        }
        refreshLegacyProgressState()
        loadBackups()

        let success: Bool
        if request.isResume {
            success = await manager.resumeIncompleteBackup(
                udid: udid,
                encrypted: request.encrypted,
                preferNetwork: request.preferNetwork,
                configuration: request.configuration
            ) { [weak self, weak manager] text in
                guard let manager else { return }
                self?.updateBackupProgress(udid: udid, text: text, manager: manager)
            }
        } else if request.incremental {
            success = await manager.createIncrementalBackup(
                udid: udid,
                preferNetwork: request.preferNetwork,
                configuration: request.configuration
            ) { [weak self, weak manager] text in
                guard let manager else { return }
                self?.updateBackupProgress(udid: udid, text: text, manager: manager)
            }
        } else {
            success = await manager.createBackup(
                udid: udid,
                encrypted: request.encrypted,
                preferNetwork: request.preferNetwork,
                configuration: request.configuration
            ) { [weak self, weak manager] text in
                guard let manager else { return }
                self?.updateBackupProgress(udid: udid, text: text, manager: manager)
            }
        }

        if success {
            let duration = Date().timeIntervalSince(activity(for: udid)?.startTime ?? Date())
            let finalStats = await Task.detached(priority: .utility) {
                BackupManager.incompleteBackupStats(for: udid)
            }.value
            let totalBytes = Int64(finalStats?.totalBytes ?? 0)
            let totalFiles = finalStats?.fileCount ?? 0
            let completedDetail = (totalBytes > 0 && totalFiles > 0)
                ? PhaseDetail.completed(totalBytes: totalBytes, totalFiles: totalFiles, duration: duration)
                : nil

            updateActivity(udid: udid) {
                $0.state = .completed
                $0.progressText = "Completed"
                $0.progressFraction = 1
                $0.explicitPhase = .completed
                $0.terminalPhaseDetail = completedDetail
                if let coordinator = $0.observabilityCoordinator {
                    var context = PhaseContext()
                    context.terminalBytes = totalBytes > 0 ? totalBytes : nil
                    context.terminalFiles = totalFiles > 0 ? totalFiles : nil
                    context.terminalDuration = duration
                    coordinator.updateMetrics(
                        phase: .completed,
                        progressFraction: 1.0,
                        bytesTransferred: totalBytes > 0 ? totalBytes : nil,
                        filesTransferred: totalFiles > 0 ? totalFiles : nil,
                        totalBytes: totalBytes > 0 ? totalBytes : nil,
                        totalFiles: totalFiles > 0 ? totalFiles : nil,
                        currentFile: nil,
                        speedBytesPerSec: nil,
                        speedFilesPerSec: nil,
                        eta: nil,
                        isFinalizing: false,
                        finalizationMetrics: nil,
                        context: context
                    )
                    $0.phaseMetrics = coordinator.phaseMetrics
                }
            }
            // Invalidate the live proc_pid_rusage size estimate so loadBackups() shows
            // "Calculating size…" and resolves the true sealed on-disk size automatically.
            resolvedSizesByPath.removeValue(forKey: BackupManager.backupPath(for: udid))
            loadBackups()
        } else if manager.lastOperationWasCancelled {
            updateActivity(udid: udid) {
                $0.state = .cancelled
                $0.progressText = "Stopped (Progress Saved)"
            }
            loadBackups()
        } else {
            let error = manager.lastBackupFailure?.message ?? manager.lastError ?? "Backup failed"
            updateActivity(udid: udid) {
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
        backupActivities[udid]?.observabilityCoordinator?.stopObserving()
        updateActivity(udid: udid) { $0.transition = nil }
        finalizationTasks.removeValue(forKey: udid)?.cancel()
        livenessTasks.removeValue(forKey: udid)?.cancel()
        resumeBaselineTasks.removeValue(forKey: udid)?.cancel()
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
        update(&activity)
        backupActivities[udid] = activity
    }

    /// Republishes activity state on a timer so time-derived flags
    /// (`isStalled`, `isProcessAlive`) flip in the UI even when the
    /// backup emits no further progress. Without this the row would only
    /// refresh on the next progress line — i.e. never, when stalled.
    private func startLivenessMonitor(udid: String) {
        livenessTasks[udid]?.cancel()
        livenessTasks[udid] = Task { [weak self] in
            var hasTriggeredMidRunRefresh = false
            var tickCount = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { break }
                guard let self else { return }
                tickCount += 1

                // Immediately republish on every 1-second tick BEFORE any blocking disk/lsof I/O
                // so transition timers ("Pausing… (1s)", "(2s)"), elapsed time, live speed, and ETA countdown
                // tick smoothly in the UI without freezing at (0s).
                let now = Date()
                let writtenBytes = self.backupManagers[udid]?.activeProcessBytesWritten ?? 0
                var isTransitioning = false
                var updatedOnDiskSize: UInt64?
                var shouldNotifyPasscode = false
                self.updateActivity(udid: udid) {
                    $0.processAlive = true
                    $0.currentTick = now
                    isTransitioning = ($0.transition != nil)
                    guard !isTransitioning else { return }

                    if writtenBytes > 0 {
                        let prevWritten = $0.sessionBytesWritten
                        let prevSampleDate = $0.byteWriteSamples.last?.date
                        if writtenBytes > prevWritten {
                            $0.lastProgressUpdate = now
                            // Only treat kernel disk writes as post-PIN payload transfer once tqdm reports >0%
                            // OR when writes resume after the >20s PIN/diffing pause (the initial 0% write is
                            // just pymobiledevice3 downloading the existing Manifest.db before iOS asks for the PIN).
                            let resumedAfterPinPause = prevSampleDate.map { now.timeIntervalSince($0) > 20.0 } ?? false
                            if ($0.progressFraction ?? 0) > 0.001 || resumedAfterPinPause {
                                $0.hasReceivedTransferProgress = true
                                $0.isAwaitingPasscode = false
                            }
                        }
                        $0.sessionBytesWritten = writtenBytes
                        Self.recordKernelByteSample(on: &$0, bytesWritten: writtenBytes, now: now)

                        // Compute 15-second rolling byte write rate for live UI speed ("8.7 MB/s")
                        let liveRate = Self.computeKernelByteSpeed(for: $0, windowSeconds: 15.0, now: now)
                        if let liveRate, liveRate > 0, $0.hasReceivedTransferProgress {
                            $0.speed = self.formatBytesPerSecond(liveRate)
                        } else if ($0.progressFraction ?? 0) <= 0.01 {
                            // Clear pre-diffing Manifest.db download speed during the PIN/diffing pause
                            $0.speed = nil
                            $0.lastComputedEtaSeconds = nil
                            $0.lastComputedEtaAt = nil
                            $0.eta = nil
                        }

                        // Recompute coherent ETA on every 1s tick using exact kernel byte accounting
                        Self.updateCoherentETA(
                            on: &$0,
                            rawTqdmEta: nil,
                            speedBytesPerSec: $0.hasReceivedTransferProgress ? (liveRate ?? $0.speed.flatMap(Self.parseSpeedToBytesPerSecond)) : nil,
                            transferredBytes: nil,
                            totalBytes: nil
                        )

                        if let coordinator = $0.observabilityCoordinator, let liveRate, liveRate > 0, $0.hasReceivedTransferProgress {
                            let baseline = $0.isResume ? ($0.resumeBytesBaseline ?? 0) : 0
                            let currentOnDisk = Int64(baseline + writtenBytes)
                            let targetTotal = $0.targetDeviceUsedBytes.map { Int64($0) }
                            var context = PhaseContext()
                            context.filesResumed = $0.resumeFileBaseline
                            context.resumeBaselineFraction = $0.resumeBaselineFraction > 0 ? $0.resumeBaselineFraction : nil
                            context.sanitizationScanned = $0.sanitizationScanned
                            context.sanitizationCleaned = $0.sanitizationCleaned
                            context.sanitizationWalCheckpointed = $0.sanitizationWalCheckpointed
                            context.fallbackReason = $0.fallbackReason
                            context.currentDomain = $0.currentDomain
                            coordinator.updateMetrics(
                                phase: $0.observabilityPhase,
                                progressFraction: $0.progressFraction,
                                bytesTransferred: currentOnDisk,
                                filesTransferred: nil,
                                totalBytes: targetTotal,
                                totalFiles: nil,
                                currentFile: nil,
                                speedBytesPerSec: liveRate,
                                speedFilesPerSec: nil,
                                eta: $0.eta.flatMap(Self.parseEtaToSeconds),
                                isFinalizing: $0.isFinalizing,
                                finalizationMetrics: $0.finalizationMetrics,
                                context: context
                            )
                            $0.phaseMetrics = coordinator.phaseMetrics
                            $0.predictiveETA = coordinator.predictiveETA
                            $0.throughputStats = coordinator.throughputStats
                            $0.throughputTrend = coordinator.throughputTrend
                        }

                        // Periodically refresh the backup row's displayed on-disk size (every ~25 MB written)
                        if writtenBytes >= $0.lastRowSizeUpdateBytes + 25_000_000 {
                            $0.lastRowSizeUpdateBytes = writtenBytes
                            let baseline = $0.isResume ? ($0.resumeBytesBaseline ?? 0) : 0
                            updatedOnDiskSize = baseline + writtenBytes
                        }
                    }

                    // Show the orange Passcode banner & alert on Attempt 1 (for both Full and Resume backups)
                    // as soon as 3 seconds have elapsed without active payload transfer (or once initial Manifest.db
                    // download finishes and stops writing for >= 2 seconds while waiting on the iPhone PIN screen).
                    let idleSinceLastWrite = $0.byteWriteSamples.last.map { now.timeIntervalSince($0.date) >= 2.0 } ?? true
                    if !$0.hasReceivedTransferProgress,
                       ($0.progressFraction ?? 0) <= 0.001,
                       $0.transition == nil,
                       $0.explicitPhase != .sanitization,
                       now.timeIntervalSince($0.startTime) >= 3.0,
                       idleSinceLastWrite {
                        $0.isAwaitingPasscode = true
                        if !$0.hasNotifiedPasscodePrompt {
                            $0.hasNotifiedPasscodePrompt = true
                            shouldNotifyPasscode = true
                        }
                    }
                }
                if shouldNotifyPasscode {
                    self.notifyUserDevicePasscodeRequired(for: udid)
                }
                if let newSize = updatedOnDiskSize {
                    let backupPath = BackupManager.backupPath(for: udid)
                    if let idx = self.backups.firstIndex(where: { !$0.isArchivedSnapshot && ($0.udid == udid || $0.id == udid) }) {
                        if newSize > self.backups[idx].size {
                            self.resolvedSizesByPath[backupPath] = (newSize, self.backups[idx].lastBackupDate)
                            self.backups[idx] = self.backups[idx].withSize(newSize)
                            self.backupManager.backups = self.backups
                        }
                    }
                }
                self.refreshLegacyProgressState()

                // Skip lsof / external USB directory scanning while pausing/restarting so teardown
                // never contends with disk I/O, and throttle disk scans to every 5 seconds while running.
                // Throttle expensive SQLite Manifest.db domain lookups to once every 30 seconds so
                // reading a 250+ MB Manifest.db never competes with pymobiledevice3 for USB disk writes.
                guard !isTransitioning, tickCount % 5 == 1 else { continue }
                let shouldSampleDomain = (tickCount % 30 == 1)

                let (domain, diskDate) = await Task.detached(priority: .utility) {
                    (
                        shouldSampleDomain ? BackupManager.sampleActiveDomain(for: udid) : nil,
                        BackupManager.latestBackupDiskActivityDate(for: udid)
                    )
                }.value
                if Task.isCancelled { break }
                var shouldNotifyPasscode5s = false
                self.updateActivity(udid: udid) {
                    $0.processAlive = true
                    if let domain { $0.currentDomain = domain }
                    if let diskDate, diskDate > $0.lastProgressUpdate {
                        $0.lastProgressUpdate = diskDate
                        if diskDate > $0.startTime.addingTimeInterval(1.0), ($0.progressFraction ?? 0) > 0.001 {
                            $0.hasReceivedTransferProgress = true
                            $0.isAwaitingPasscode = false
                        }
                    }
                    // Check if user passcode is needed without blocking MainActor on external disk I/O
                    if !$0.hasReceivedTransferProgress,
                       ($0.progressFraction ?? 0) <= 0.001,
                       $0.transition == nil,
                       $0.explicitPhase != .sanitization,
                       Date().timeIntervalSince($0.startTime) >= 3.0 {
                        $0.isAwaitingPasscode = true
                        if !$0.hasNotifiedPasscodePrompt {
                            $0.hasNotifiedPasscodePrompt = true
                            shouldNotifyPasscode5s = true
                        }
                    }
                }
                if shouldNotifyPasscode5s {
                    self.notifyUserDevicePasscodeRequired(for: udid)
                }
                if !hasTriggeredMidRunRefresh, diskDate != nil {
                    hasTriggeredMidRunRefresh = true
                    self.loadBackups()
                }
                self.refreshLegacyProgressState()
            }
        }
    }

    /// Alerts the user via Dock bounce, system sound, and macOS UserNotifications when the iPhone/iPad
    /// is waiting for passcode entry or unlock during backup/resume handshake.
    private func notifyUserDevicePasscodeRequired(for udid: String) {
        let deviceName = latestBackupRequests[udid]?.device?.name
            ?? backups.first(where: { $0.udid == udid || $0.id == udid })?.deviceName
            ?? "your iPhone or iPad"

        NSSound.beep()
        if !NSApp.isActive {
            NSApp.requestUserAttention(.informationalRequest)
        }

        // UNUserNotificationCenter requires a valid app bundle identifier at runtime; guard so CLI test probes never trap.
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "Action Required on \(deviceName)"
            content.body = "Unlock \(deviceName) and enter your passcode on the device screen to continue the backup."
            content.sound = .default
            let request = UNNotificationRequest(
                identifier: "phosphor.passcode.\(udid)",
                content: content,
                trigger: nil
            )
            center.add(request)
        }
    }

    private func startObservability(udid: String, isResume: Bool) {
        let coordinator = BackupObservabilityCoordinator()
        coordinator.startObserving(udid: udid, configuration: nil)
        // Seed initial phase
        let initialPhase: BackupPhase = isResume ? .incrementalResume : .fullBackup
        coordinator.updateMetrics(
            phase: initialPhase,
            progressFraction: nil,
            bytesTransferred: nil,
            filesTransferred: nil,
            totalBytes: nil,
            totalFiles: nil,
            currentFile: nil,
            speedBytesPerSec: nil,
            speedFilesPerSec: nil,
            eta: nil,
            isFinalizing: false,
            finalizationMetrics: nil
        )
        updateActivity(udid: udid) { $0.observabilityCoordinator = coordinator }
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
        guard let progressFraction else { return 0.0 }
        return min(max(progressFraction, 0.0), 1.0)
    }

    private func updateBackupProgress(udid: String, text: String, manager: BackupManager) {
        let lower = text.lowercased()
        let passcodeDismissed = lower.contains("passcode prompt dismissed")
            || lower.contains("localauthentication.ui.dismissed")
            || lower.contains("domain_changed")
        let awaitingPasscode = !passcodeDismissed && (
            lower.contains("passcode")
            || lower.contains("enter pin")
            || lower.contains("trust this computer")
            || lower.contains("unlock")
            || lower.contains("not paired")
        )
        var transferredBytes: Int64?
        var totalBytes: Int64?
        var shouldNotifyPasscode = false
        updateActivity(udid: udid) { activity in
            // A pause/restart is tearing the process down; late progress lines
            // must not overwrite the "Pausing..." status the user was promised.
            guard activity.transition == nil else { return }
            activity.progressText = text
            activity.lastProgressUpdate = Date()
            activity.processAlive = true
            if passcodeDismissed {
                activity.isAwaitingPasscode = false
                activity.hasReceivedTransferProgress = true
                if Bundle.main.bundleIdentifier != nil {
                    UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["phosphor.passcode.\(udid)"])
                }
            } else if awaitingPasscode {
                // Device explicitly requesting user interaction/unlock.
                // Reset hasReceivedTransferProgress for this lock gate so existing on-disk files do not suppress UI banner.
                activity.isAwaitingPasscode = true
                activity.hasReceivedTransferProgress = false
                if !activity.hasNotifiedPasscodePrompt {
                    activity.hasNotifiedPasscodePrompt = true
                    shouldNotifyPasscode = true
                }
            } else if !text.isEmpty && !awaitingPasscode && activity.isAwaitingPasscode {
                // Any regular log line after passcode prompt indicates device responded
                if lower.contains("mb2") || lower.contains("progress") || lower.contains("transfer") || lower.contains("file") || lower.contains("uploading") {
                    activity.isAwaitingPasscode = false
                    activity.hasReceivedTransferProgress = true
                }
            }
            var parsedProgress = false
            if let details = PyMobileDevice.parseProgressDetails(from: text) {
                parsedProgress = true
                // Only mark passcode entry as completed when tqdm reports actual transfer progress (>0.1%) or a real byte speed (not `it/s`).
                // On resumed backups, pymobiledevice3 emits `0%| | 0/100 [00:01<?, 1.12it/s]` while downloading Manifest.db
                // BEFORE the user has entered the PIN on the iPhone, so a 0% or `it/s` frame must NEVER dismiss `isAwaitingPasscode`.
                let byteSpeed = details.speed.flatMap(Self.parseSpeedToBytesPerSecond)
                if (byteSpeed ?? 0) > 0 || details.fraction > 0.001 {
                    activity.hasReceivedTransferProgress = true
                    activity.isAwaitingPasscode = false
                }
                // Ignore transient sub-phase 100% resets unless truly completing
                if details.fraction >= 0.99 && activity.progressFraction ?? 0 < 0.85 {
                    // Transient 100% on metadata preparation phase - do not jump UI to 100%
                } else {
                    let current = activity.progressFraction ?? 0.0
                    let next = max(current, details.fraction)
                    activity.progressFraction = next
                    Self.recordTransferSample(on: &activity, sessionFraction: next)
                }
                if let speed = details.speed, !speed.lowercased().contains("it/s") {
                    activity.speed = speed
                }
                if let t = details.transferred { transferredBytes = Self.parseByteCount(t) }
                if let t = details.total { totalBytes = Self.parseByteCount(t) }
                Self.updateCoherentETA(
                    on: &activity,
                    rawTqdmEta: details.eta,
                    speedBytesPerSec: activity.speed.flatMap(Self.parseSpeedToBytesPerSecond),
                    transferredBytes: transferredBytes,
                    totalBytes: totalBytes
                )
            } else if let pct = PyMobileDevice.parseProgress(from: text) {
                parsedProgress = true
                if pct > 0.001 {
                    activity.hasReceivedTransferProgress = true
                    activity.isAwaitingPasscode = false
                }
                if pct >= 0.99 && activity.progressFraction ?? 0 < 0.85 {
                    // Transient subphase
                } else {
                    let current = activity.progressFraction ?? 0.0
                    let next = max(current, pct)
                    activity.progressFraction = next
                    Self.recordTransferSample(on: &activity, sessionFraction: next)
                }
                Self.updateCoherentETA(
                    on: &activity,
                    rawTqdmEta: nil,
                    speedBytesPerSec: activity.speed.flatMap(Self.parseSpeedToBytesPerSecond),
                    transferredBytes: transferredBytes,
                    totalBytes: totalBytes
                )
            } else if manager.backupPercent > 0 {
                parsedProgress = true
                activity.hasReceivedTransferProgress = true
                activity.isAwaitingPasscode = false
                let current = activity.progressFraction ?? 0.0
                let next = max(current, manager.backupPercent)
                activity.progressFraction = next
                Self.recordTransferSample(on: &activity, sessionFraction: next)
                Self.updateCoherentETA(
                    on: &activity,
                    rawTqdmEta: nil,
                    speedBytesPerSec: activity.speed.flatMap(Self.parseSpeedToBytesPerSecond),
                    transferredBytes: transferredBytes,
                    totalBytes: totalBytes
                )
            }

            // Detect phase signals emitted by BackupManager
            if text.hasPrefix("Sanitizing:") {
                activity.explicitPhase = .sanitization
                // Format: "Sanitizing: <scanned> scanned, <cleaned> cleaned, wal: <wal>"
                if let regex = try? NSRegularExpression(pattern: #"Sanitizing:\s*(\d+)\s*scanned,\s*(\d+)\s*cleaned,\s*wal:\s*(true|false)"#) {
                    if let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) {
                        if let r1 = Range(m.range(at: 1), in: text), let s = Int(text[r1]) { activity.sanitizationScanned = s }
                        if let r2 = Range(m.range(at: 2), in: text), let c = Int(text[r2]) { activity.sanitizationCleaned = c }
                        if let r3 = Range(m.range(at: 3), in: text) { activity.sanitizationWalCheckpointed = text[r3] == "true" }
                    }
                }
            } else if text.hasPrefix("Fallback:") {
                activity.explicitPhase = .fallbackIdevicebackup2
                let reason = String(text.dropFirst("Fallback:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
                if !reason.isEmpty { activity.fallbackReason = reason }
            } else if activity.explicitPhase == .sanitization && (parsedProgress || text.contains("Resuming")) {
                activity.explicitPhase = nil
            }

            if activity.isFinalizing {
                startFinalizationWatchdogIfNeeded(udid: udid)
            }

            if let coordinator = activity.observabilityCoordinator {
                let isPostPinTransfer = activity.hasReceivedTransferProgress
                coordinator.updateMetrics(
                    phase: activity.observabilityPhase,
                    progressFraction: activity.progressFraction,
                    bytesTransferred: isPostPinTransfer ? transferredBytes : nil,
                    filesTransferred: nil,
                    totalBytes: isPostPinTransfer ? totalBytes : nil,
                    totalFiles: nil,
                    currentFile: nil,
                    speedBytesPerSec: isPostPinTransfer ? activity.speed.flatMap(Self.parseSpeedToBytesPerSecond) : nil,
                    speedFilesPerSec: nil,
                    eta: isPostPinTransfer ? activity.eta.flatMap(Self.parseEtaToSeconds) : nil,
                    isFinalizing: activity.isFinalizing,
                    finalizationMetrics: activity.finalizationMetrics,
                    context: {
                        var context = PhaseContext()
                        context.filesResumed = activity.resumeFileBaseline
                        context.resumeBaselineFraction = activity.resumeBaselineFraction > 0 ? activity.resumeBaselineFraction : nil
                        context.sanitizationScanned = activity.sanitizationScanned
                        context.sanitizationCleaned = activity.sanitizationCleaned
                        context.sanitizationWalCheckpointed = activity.sanitizationWalCheckpointed
                        context.fallbackReason = activity.fallbackReason
                        context.currentDomain = activity.currentDomain
                        return context
                    }()
                )
                activity.phaseMetrics = coordinator.phaseMetrics
                activity.predictiveETA = coordinator.predictiveETA
                activity.throughputStats = coordinator.throughputStats
                activity.throughputTrend = coordinator.throughputTrend
            }
        }
        if shouldNotifyPasscode {
            notifyUserDevicePasscodeRequired(for: udid)
        }
        refreshLegacyProgressState()
    }

    /// Parse a speed string ("39.5MB/s", "8,7 MB/s", "1.2GB/s") into bytes/sec.
    /// "it/s" is iteration rate, not a byte rate, so it returns nil.
    private static func parseSpeedToBytesPerSecond(_ s: String) -> Double? {
        let trimmed = s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard !trimmed.lowercased().contains("it/s") else { return nil }
        guard let regex = try? NSRegularExpression(pattern: #"^([\d.]+)\s*([kKmMgG]?)[bB]?/?s"#) else { return nil }
        guard let m = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)) else { return nil }
        guard let numRange = Range(m.range(at: 1), in: trimmed), let num = Double(String(trimmed[numRange])) else { return nil }
        let unit = Range(m.range(at: 2), in: trimmed).map { String(trimmed[$0]) } ?? ""
        let factor: Double = switch unit.lowercased() {
        case "g": 1_073_741_824
        case "m": 1_048_576
        case "k": 1_024
        default: 1
        }
        return num * factor
    }

    /// Parse a tqdm size string ("12.3G", "123M", "456K", "789") into bytes.
    private static func parseByteCount(_ s: String) -> Int64? {
        let trimmed = s.trimmingCharacters(in: .whitespaces).uppercased()
        guard let regex = try? NSRegularExpression(pattern: #"^([\d.]+)\s*([KMGT]?)B?$"#) else { return nil }
        guard let m = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)) else { return nil }
        guard let numRange = Range(m.range(at: 1), in: trimmed),
              let num = Double(trimmed[numRange]) else { return nil }
        let unit = Range(m.range(at: 2), in: trimmed).map { String(trimmed[$0]) } ?? ""
        let factor: Double = switch unit {
        case "K": 1_024
        case "M": 1_048_576
        case "G": 1_073_741_824
        case "T": 1_099_511_627_776
        default: 1
        }
        return Int64(num * factor)
    }

    /// Parse a formatted ETA ("5m 30s", "1h 2m 10s") into seconds.
    nonisolated static func parseEtaToSeconds(_ s: String) -> TimeInterval? {
        var total: TimeInterval = 0
        for part in s.lowercased().components(separatedBy: " ") {
            let token = part.trimmingCharacters(in: .whitespaces)
            if token.hasSuffix("h"), let v = Double(token.dropLast(1)) { total += v * 3600 }
            else if token.hasSuffix("m"), let v = Double(token.dropLast(1)) { total += v * 60 }
            else if token.hasSuffix("s"), let v = Double(token.dropLast(1)) { total += v }
        }
        return total > 0 ? total : nil
    }

    /// Records a 1-second sample of kernel `ri_diskio_byteswritten` (`proc_pid_rusage`), keeping a 10-minute
    /// rolling window of active payload writes so live `MB/s` and byte-based ETA are immune to `tqdm` integer `%` quantization.
    ///
    /// To prevent the pre-transfer `Manifest.db` download + multi-minute PIN/diffing pause from diluting the denominator
    /// of the rolling transfer rate, samples only append when `bytesWritten` actually increases (`> last.bytes`), and if
    /// the first write after a `>20s` startup/diffing pause occurs while `(activity.progressFraction ?? 0) <= 0.01`, the
    /// pre-diffing `Manifest.db` sample is replaced by the start of real payload transfer.
    private static func recordKernelByteSample(on activity: inout BackupActivity, bytesWritten: UInt64, now: Date) {
        guard bytesWritten > 0 else { return }
        if let last = activity.byteWriteSamples.last {
            guard bytesWritten > last.bytes else { return }
            let gap = now.timeIntervalSince(last.date)
            if gap > 20.0, (activity.progressFraction ?? 0) <= 0.01 {
                // First payload write after the startup PIN + manifest-diffing pause:
                // anchor the rolling window right at the start of payload transfer (`last.bytes` 1s before `now`).
                activity.byteWriteSamples = [
                    (now.addingTimeInterval(-1.0), last.bytes),
                    (now, bytesWritten)
                ]
                return
            }
        }
        activity.byteWriteSamples.append((now, bytesWritten))
        let cutoff = now.addingTimeInterval(-600) // 10-minute rolling window
        if activity.byteWriteSamples.count > 2 {
            activity.byteWriteSamples.removeAll { $0.date < cutoff }
        }
    }

    /// Computes rolling byte write throughput (`bytes/sec`) over `windowSeconds` from `byteWriteSamples`.
    private static func computeKernelByteSpeed(
        for activity: BackupActivity,
        windowSeconds: TimeInterval,
        now: Date
    ) -> Double? {
        guard let last = activity.byteWriteSamples.last else { return nil }
        // If no new bytes have been written in the last 15 seconds (e.g. during PIN prompt or manifest diffing),
        // live throughput is currently 0, so return nil rather than reporting a stale pre-pause speed.
        guard now.timeIntervalSince(last.date) <= 15.0 else { return nil }
        let targetStart = now.addingTimeInterval(-windowSeconds)
        // Find the sample closest to `targetStart` (or the oldest sample if window hasn't filled yet)
        let ref = activity.byteWriteSamples.first(where: { $0.date >= targetStart }) ?? activity.byteWriteSamples.first
        guard let ref, last.bytes > ref.bytes else { return nil }
        let dt = now.timeIntervalSince(ref.date)
        guard dt >= 1.5 else { return nil }
        return Double(last.bytes - ref.bytes) / dt
    }

    /// Records a timestamped sample of `sessionFraction` once active payload transfer begins (`> 0.005`),
    /// retaining `transferAnchorSample` and a 2-hour rolling window of distinct percentage step transitions
    /// so velocity remains stable across multi-minute integer percentage steps on 200+ GB backups.
    private static func recordTransferSample(on activity: inout BackupActivity, sessionFraction: Double) {
        guard sessionFraction > 0.005 else { return }
        let now = Date()
        if activity.transferAnchorSample == nil {
            activity.transferAnchorSample = (now, sessionFraction)
        }
        if let last = activity.transferFractionSamples.last {
            // Only append when the percentage actually advances. Never overwrite `transferFractionSamples[0]`'s timestamp
            // while `sessionFraction` stays at the same integer percentage, otherwise the elapsed time for a 6-minute `1% -> 2%`
            // step gets collapsed to the last few seconds before `2%` arrives.
            if sessionFraction > last.fraction + 0.0005 {
                activity.transferFractionSamples.append((now, sessionFraction))
            }
        } else {
            activity.transferFractionSamples.append((now, sessionFraction))
        }
        // Keep up to 20 distinct percentage transition steps (within the last 2 hours)
        let cutoff = now.addingTimeInterval(-7200)
        if activity.transferFractionSamples.count > 3 {
            activity.transferFractionSamples.removeAll { $0.date < cutoff }
        }
        if activity.transferFractionSamples.count > 20 {
            activity.transferFractionSamples.removeFirst(activity.transferFractionSamples.count - 20)
        }
    }

    private static func updateCoherentETA(
        on activity: inout BackupActivity,
        rawTqdmEta: String?,
        speedBytesPerSec: Double?,
        transferredBytes: Int64?,
        totalBytes: Int64?
    ) {
        if let computed = computeCoherentETA(
            for: activity,
            rawTqdmEta: rawTqdmEta,
            speedBytesPerSec: speedBytesPerSec,
            transferredBytes: transferredBytes,
            totalBytes: totalBytes
        ) {
            activity.eta = computed
            if let secs = parseEtaToSeconds(computed), secs > 0 {
                activity.lastComputedEtaSeconds = secs
                activity.lastComputedEtaAt = Date()
            }
        } else if let prevSecs = activity.lastComputedEtaSeconds,
                  let prevAt = activity.lastComputedEtaAt,
                  (activity.progressFraction ?? 0) < 0.995 {
            // Never blank out an already-established ETA to nil between integer percentage ticks
            let elapsed = max(0, Date().timeIntervalSince(prevAt))
            let remaining = max(30, prevSecs - elapsed)
            activity.eta = remaining.formattedDuration
        } else {
            activity.eta = nil
        }
    }

    /// Computes a coherent, self-contained ETA for `activity` based on first-principles kernel byte accounting
    /// (`remainingBytes / rollingBytesPerSecond`), falling back to session-fraction velocity only when byte totals
    /// are unavailable.
    private static func computeCoherentETA(
        for activity: BackupActivity,
        rawTqdmEta: String?,
        speedBytesPerSec: Double?,
        transferredBytes: Int64?,
        totalBytes: Int64?
    ) -> String? {
        if let sessionFraction = activity.progressFraction, sessionFraction >= 0.995 {
            return nil
        }

        // 1. First-principles kernel byte-write ETA:
        //    remainingBytes = targetDeviceUsedBytes - (resumeBytesBaseline + sessionBytesWritten)
        //    divided by the 10-minute rolling kernel byte write rate (`byteWriteSamples`).
        if let targetUsed = activity.targetDeviceUsedBytes,
           activity.sessionBytesWritten > 0,
           let firstSample = activity.byteWriteSamples.first,
           let lastSample = activity.byteWriteSamples.last {
            // Do not compute a premature ETA while the process is sitting in the pre-transfer PIN/diffing pause
            let isInPreTransferDiffing = (activity.progressFraction ?? 0) <= 0.01 && Date().timeIntervalSince(lastSample.date) > 10.0
            if !isInPreTransferDiffing {
                let baselineBytes = activity.isResume ? (activity.resumeBytesBaseline ?? 0) : 0
                let currentOnDisk = baselineBytes + activity.sessionBytesWritten
                if targetUsed > currentOnDisk {
                    let dt = lastSample.date.timeIntervalSince(firstSample.date)
                    let dBytes = lastSample.bytes > firstSample.bytes ? (lastSample.bytes - firstSample.bytes) : 0
                    // Require at least 5 seconds and 5 MB of active payload writes in the rolling window
                    if dt >= 5.0, dBytes >= 5_000_000 {
                        let rollingRate = Double(dBytes) / dt
                        let remainingBytes = Double(targetUsed - currentOnDisk)
                        let estSeconds = remainingBytes / rollingRate
                        if estSeconds > 0, estSeconds < 86_400 * 7 {
                            return estSeconds.formattedDuration
                        }
                    }
                }
            }
        }

        guard let sessionFraction = activity.progressFraction, sessionFraction < 0.995 else {
            return nil
        }

        // 2. If explicit byte counts and byte speed are present from CLI output, compute directly from remaining bytes
        if let speed = speedBytesPerSec, speed > 0 {
            if let total = totalBytes, let transferred = transferredBytes, total > transferred {
                let remaining = Double(total - transferred)
                return (remaining / speed).formattedDuration
            }
            if let targetUsed = activity.targetDeviceUsedBytes {
                let baselineBytes = activity.isResume ? (activity.resumeBytesBaseline ?? 0) : 0
                if targetUsed > baselineBytes {
                    let sessionTargetBytes = Double(targetUsed - baselineBytes)
                    let remainingSessionBytes = sessionTargetBytes * max(0.0, 1.0 - sessionFraction)
                    if remainingSessionBytes > 0 {
                        return (remainingSessionBytes / speed).formattedDuration
                    }
                }
            }
        }

        // 3. Fallback: compute from rolling active session-fraction velocity
        if let last = activity.transferFractionSamples.last {
            let referenceSample: (date: Date, fraction: Double)? = {
                if let first = activity.transferFractionSamples.first, (last.fraction - first.fraction) >= 0.003 {
                    return first
                }
                return activity.transferAnchorSample
            }()
            if let ref = referenceSample {
                let dt = last.date.timeIntervalSince(ref.date)
                let df = last.fraction - ref.fraction
                if dt >= 4.0, df >= 0.003 {
                    let ratePerSec = df / dt
                    let remainingFraction = max(0.0, 1.0 - sessionFraction)
                    let estSeconds = remainingFraction / ratePerSec
                    if estSeconds > 0, estSeconds < 86_400 * 3 {
                        return estSeconds.formattedDuration
                    }
                }
            }
        }

        // 4. Before active transfer velocity is established:
        // On a resumed backup (or while sessionFraction <= 3%), suppress tqdm's cumulative ETA because
        // tqdm divides by total time since process launch (including PIN wait + 380k-file manifest diffing),
        // which produces absurd multi-hour ETAs (e.g. 14h 27m at 95%).
        if activity.isResume || sessionFraction <= 0.03 {
            return nil
        }

        return rawTqdmEta
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
                        // On-disk consolidation is real progress. Without this a
                        // finalization longer than 5 minutes reads as "stalled" and
                        // the row swaps Pause & Save for a resume that cannot run.
                        activity.lastProgressUpdate = Date()
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
        let recoveryRoot = issue.recoveryPath.map { ($0 as NSString).deletingLastPathComponent }
        await Task.detached(priority: .userInitiated) {
            _ = BackupManager.archiveExistingBackup(for: udid, in: recoveryRoot)
        }.value
        loadBackups()
        await createBackup(
            udid: udid,
            incremental: false,
            preferNetwork: request?.preferNetwork ?? false,
            encrypted: request?.encrypted ?? false,
            device: request?.device,
            configuration: request?.configuration
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
            encrypted: request?.encrypted ?? false,
            device: request?.device,
            configuration: request?.configuration
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
                encrypted: request?.encrypted ?? false,
                device: request?.device,
                configuration: request?.configuration
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
            encrypted: request.encrypted,
            isResume: request.isResume,
            device: request.device,
            configuration: request.configuration
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

    func unarchiveBackup(_ backup: BackupInfo) {
        do {
            _ = try BackupManager.unarchiveBackup(backup)
            loadBackups()
        } catch {
            alertMessage = "Failed to unarchive backup: \(error.localizedDescription)"
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
