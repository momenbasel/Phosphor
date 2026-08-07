import Foundation
import SwiftUI

/// Drives backup list, creation, browsing, and extraction UI.
@MainActor
final class BackupViewModel: ObservableObject {

    @Published var backups: [BackupInfo] = []
    @Published var selectedBackup: BackupInfo?
    @Published var isCreating = false
    @Published var progressText = ""
    @Published var progressFraction: Double?
    @Published var showAlert = false
    @Published var alertMessage = ""
    @Published var backupIssue: BackupManager.BackupFailure?
    @Published var loadError: String?

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
    private var backupOperationID: UUID?

    private struct BackupRequest {
        let udid: String
        let incremental: Bool
        let preferNetwork: Bool
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

    func createBackup(udid: String, incremental: Bool = false, preferNetwork: Bool = false) async {
        let operationID = UUID()
        backupOperationID = operationID
        lastBackupRequest = BackupRequest(udid: udid, incremental: incremental, preferNetwork: preferNetwork)
        isCreating = true
        progressText = "Preparing..."
        progressFraction = nil

        let success: Bool
        if incremental {
            success = await backupManager.createIncrementalBackup(udid: udid, preferNetwork: preferNetwork) { [weak self, operationID] text in
                guard self?.backupOperationID == operationID else { return }
                self?.updateBackupProgress(text)
            }
        } else {
            success = await backupManager.createBackup(udid: udid, preferNetwork: preferNetwork) { [weak self, operationID] text in
                guard self?.backupOperationID == operationID else { return }
                self?.updateBackupProgress(text)
            }
        }

        guard backupOperationID == operationID else { return }
        backupOperationID = nil
        isCreating = false
        if success {
            alertMessage = "Backup completed"
            showAlert = true
            loadBackups()
        } else if backupManager.lastOperationWasCancelled {
            // User-initiated cancellation is not a backup failure.
            progressText = "Cancelled"
        } else if let failure = backupManager.lastBackupFailure {
            backupIssue = failure
        } else {
            alertMessage = backupManager.lastError ?? "Backup failed"
            showAlert = true
        }
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

    private func updateBackupProgress(_ text: String) {
        progressText = text
        if let pct = PyMobileDevice.parseProgress(from: text) {
            progressFraction = pct
        } else {
            progressFraction = backupManager.backupPercent > 0 ? backupManager.backupPercent : progressFraction
        }
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
