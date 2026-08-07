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
        var errorMessage: String?

        var isActive: Bool {
            switch state {
            case .queued, .running: true
            case .completed, .failed, .cancelled: false
            }
        }

        var displayProgressText: String {
            switch state {
            case .queued(let position): return "Queued · #\(position)"
            case .running:
                guard let progressFraction else { return "Backing up" }
                return "Backing up \(Int(progressFraction * 100))%"
            case .completed: return "Completed"
            case .failed: return "Failed"
            case .cancelled: return "Cancelled"
            }
        }

        var displayProgressFraction: Double {
            guard let progressFraction else { return 0.05 }
            return min(max(progressFraction, 0.05), 1)
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
    private var currentManifest: BackupManifest?
    private var sizeResolutionTask: Task<Void, Never>?
    private var lastBackupRequest: BackupRequest?
    private var jobQueue = BackupJobQueue(maxConcurrent: 2)
    private var pendingBackupRequests: [String: BackupRequest] = [:]
    private var backupManagers: [String: BackupManager] = [:]
    private var backupJobTasks: [String: Task<Void, Never>] = [:]
    private var backupCompletionContinuations: [String: CheckedContinuation<Void, Never>] = [:]
    private var backupJobWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    private struct BackupRequest {
        let udid: String
        let incremental: Bool
        let preferNetwork: Bool
        let encrypted: Bool
    }

    func loadBackups() {
        sizeResolutionTask?.cancel()
        backupManager.discoverBackups()
        backups = backupManager.backups
        loadError = backupManager.lastError
        reconcileSelectedBackupAfterReload()
        resolveBackupSizesInBackground(for: backups)
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

    func createBackup(udid: String, incremental: Bool = false, preferNetwork: Bool = false, encrypted: Bool = false) async {
        let request = BackupRequest(udid: udid, incremental: incremental, preferNetwork: preferNetwork, encrypted: encrypted)
        lastBackupRequest = request

        switch jobQueue.enqueue(udid: udid) {
        case .duplicate:
            await withCheckedContinuation { continuation in
                backupJobWaiters[udid, default: []].append(continuation)
            }
        case .queued(let position):
            pendingBackupRequests[udid] = request
            backupActivities[udid] = BackupActivity(
                udid: udid,
                state: .queued(position: position),
                progressText: "Queued",
                progressFraction: nil,
                errorMessage: nil
            )
            refreshLegacyProgressState()
            await withCheckedContinuation { continuation in
                backupCompletionContinuations[udid] = continuation
            }
        case .started:
            pendingBackupRequests[udid] = request
            backupActivities[udid] = BackupActivity(
                udid: udid,
                state: .running,
                progressText: "Preparing...",
                progressFraction: nil,
                errorMessage: nil
            )
            refreshLegacyProgressState()
            await runBackupJob(udid: udid)
        }
    }

    func activity(for udid: String) -> BackupActivity? {
        backupActivities[udid]
    }

    func isBackupActive(for udid: String) -> Bool {
        backupActivities[udid]?.isActive == true
    }

    func cancelBackup(udid: String) {
        switch jobQueue.cancel(udid: udid) {
        case .removedQueued:
            pendingBackupRequests.removeValue(forKey: udid)
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
            updateActivity(udid: udid) { $0.progressText = "Cancelling..." }
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
        updateActivity(udid: udid) {
            $0.state = .running
            $0.progressText = "Preparing..."
        }
        refreshLegacyProgressState()

        let success: Bool
        if request.incremental {
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
                $0.state = .completed
                $0.progressText = "Completed"
                $0.progressFraction = 1
            }
            loadBackups()
        } else if manager.lastOperationWasCancelled {
            updateActivity(udid: udid) {
                $0.state = .cancelled
                $0.progressText = "Cancelled"
            }
        } else {
            let error = manager.lastBackupFailure?.message ?? manager.lastError ?? "Backup failed"
            updateActivity(udid: udid) {
                $0.state = .failed
                $0.progressText = "Failed"
                $0.errorMessage = error
            }
            if let failure = manager.lastBackupFailure {
                backupIssue = failure
            }
        }

        finishBackupJob(udid: udid)
    }

    private func finishBackupJob(udid: String) {
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

    private func resumeBackupWaiters(for udid: String) {
        let waiters = backupJobWaiters.removeValue(forKey: udid) ?? []
        waiters.forEach { $0.resume() }
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
        issue.udid ?? lastBackupRequest?.udid
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
        updateActivity(udid: udid) { activity in
            activity.progressText = text
            if let pct = PyMobileDevice.parseProgress(from: text) {
                activity.progressFraction = pct
            } else if manager.backupPercent > 0 {
                activity.progressFraction = manager.backupPercent
            }
        }
        refreshLegacyProgressState()
    }

    private func recoveryPrefersNetwork(for udid: String) -> Bool {
        lastBackupRequest?.udid == udid ? (lastBackupRequest?.preferNetwork ?? false) : false
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
        backupIssue = nil
        await createBackup(udid: udid, incremental: false, preferNetwork: recoveryPrefersNetwork(for: udid))
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
            try BackupManager.deleteIncompleteBackup(for: udid, expectedPath: path)
            backupIssue = nil
            loadBackups()
            await createBackup(udid: udid, incremental: false, preferNetwork: recoveryPrefersNetwork(for: udid))
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

    func retryLastBackup() async {
        guard let request = lastBackupRequest else { return }
        backupIssue = nil
        await createBackup(udid: request.udid, incremental: request.incremental, preferNetwork: request.preferNetwork)
    }

    // MARK: - Browsing

    private func clearBrowserState() {
        selectedBackup = nil
        currentManifest = nil
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

        currentManifest = backupManager.openManifest(for: backup)

        guard let manifest = currentManifest else {
            // openManifest swallows the error into backupManager.lastError; surface it.
            alertMessage = backupManager.lastError ?? "Failed to open backup."
            showAlert = true
            return false
        }

        do {
            browserDomains = try manifest.domains()
            selectedBackup = backup
            return true
        } catch {
            clearBrowserState()
            alertMessage = "Failed to read backup: \(error.localizedDescription)"
            showAlert = true
            return false
        }
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
            try await Task.detached(priority: .userInitiated) {
                try BackupUnlockStore.shared.unlock(backupPath: path, password: password)
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
        currentDomain = domain
        guard let manifest = currentManifest else { return }
        do {
            browserFiles = manifest.resolvingSizes(for: try manifest.files(inDomain: domain))
        } catch {
            alertMessage = error.localizedDescription
            showAlert = true
        }
    }

    func searchBackup(_ query: String) {
        guard !query.isEmpty, let manifest = currentManifest else {
            searchResults = []
            return
        }
        do {
            searchResults = manifest.resolvingSizes(for: try manifest.search(query))
        } catch {
            searchResults = []
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
