import Foundation
import SwiftUI

/// Drives backup list, creation, browsing, and extraction UI.
@MainActor
final class BackupViewModel: ObservableObject {

    @Published var backups: [BackupInfo] = []
    @Published var selectedBackup: BackupInfo?
    @Published var isCreating = false
    @Published var progressText = ""
    @Published var showAlert = false
    @Published var alertMessage = ""
    @Published var loadError: String?

    // Browser state
    @Published var browserDomains: [String] = []
    @Published var browserFiles: [BackupManifest.FileEntry] = []
    @Published var currentDomain: String?
    @Published var searchQuery = ""
    @Published var searchResults: [BackupManifest.FileEntry] = []

    @Published var showPasswordPrompt = false

    let backupManager = BackupManager()
    private var currentManifest: BackupManifest?
    private var sizeResolutionTask: Task<Void, Never>?
    private var pendingEncryptedBackup: BackupInfo?
    private var activeEncryptedReader: EncryptedBackupReader?

    func loadBackups() {
        sizeResolutionTask?.cancel()
        backupManager.discoverBackups()
        backups = backupManager.backups
        loadError = backupManager.lastError
        resolveBackupSizesInBackground(for: backups)
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
        isCreating = true
        progressText = "Preparing..."

        let success: Bool
        if incremental {
            success = await backupManager.createIncrementalBackup(udid: udid, preferNetwork: preferNetwork) { [weak self] text in
                self?.progressText = text
            }
        } else {
            success = await backupManager.createBackup(udid: udid, preferNetwork: preferNetwork) { [weak self] text in
                self?.progressText = text
            }
        }

        isCreating = false
        alertMessage = success ? "Backup completed" : (backupManager.lastError ?? "Backup failed")
        showAlert = true
        if success { loadBackups() }
    }

    // MARK: - Browsing

    func openBackupBrowser(_ backup: BackupInfo) {
        activeEncryptedReader?.cleanup()
        activeEncryptedReader = nil

        if backup.isEncrypted {
            pendingEncryptedBackup = backup
            showPasswordPrompt = true
            return
        }

        selectedBackup = backup
        currentManifest = backupManager.openManifest(for: backup)

        guard let manifest = currentManifest else {
            // openManifest swallows the error into backupManager.lastError; surface it.
            alertMessage = backupManager.lastError ?? "Failed to open backup."
            showAlert = true
            return
        }

        do {
            browserDomains = try manifest.domains()
        } catch {
            alertMessage = "Failed to read backup: \(error.localizedDescription)"
            showAlert = true
        }
    }

    func unlockBackup(password: String) async {
        guard let backup = pendingEncryptedBackup else { return }
        let reader = EncryptedBackupReader(backupPath: backup.path)
        do {
            let manifest = try await reader.unlock(password: password)
            activeEncryptedReader = reader
            selectedBackup = backup
            currentManifest = manifest
            browserDomains = (try? manifest.domains()) ?? []
            showPasswordPrompt = false
            pendingEncryptedBackup = nil
        } catch {
            reader.cleanup()
            alertMessage = error.localizedDescription
            showAlert = true
            showPasswordPrompt = false
        }
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
