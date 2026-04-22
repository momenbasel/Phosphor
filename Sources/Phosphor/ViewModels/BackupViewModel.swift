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

    // Browser state
    @Published var browserDomains: [String] = []
    @Published var browserFiles: [BackupManifest.FileEntry] = []
    @Published var currentDomain: String?
    @Published var searchQuery = ""
    @Published var searchResults: [BackupManifest.FileEntry] = []

    let backupManager = BackupManager()
    private var currentManifest: BackupManifest?

    func loadBackups() {
        backupManager.discoverBackups()
        backups = backupManager.backups
    }

    func createBackup(udid: String, incremental: Bool = false) async {
        isCreating = true
        progressText = "Preparing..."

        let success: Bool
        if incremental {
            success = await backupManager.createIncrementalBackup(udid: udid) { [weak self] text in
                self?.progressText = text
            }
        } else {
            success = await backupManager.createBackup(udid: udid) { [weak self] text in
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

    func browseDomain(_ domain: String) {
        currentDomain = domain
        guard let manifest = currentManifest else { return }
        do {
            browserFiles = try manifest.files(inDomain: domain)
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
            searchResults = try manifest.search(query)
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
        backupManager.totalBackupSize.formattedFileSize
    }
}
