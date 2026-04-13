import Foundation
import Combine

/// Handles iOS backup operations: discovery, creation, browsing, and selective restore.
/// Wraps idevicebackup2 CLI and directly parses Apple's backup format (Manifest.db + hashed files).
@MainActor
final class BackupManager: ObservableObject {

    @Published var backups: [BackupInfo] = []
    @Published var isCreatingBackup = false
    @Published var backupProgress: String = ""
    @Published var lastError: String?

    /// Default backup location used by Apple and libimobiledevice.
    static let defaultBackupDir: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/Library/Application Support/MobileSync/Backup"
    }()

    /// Active backup directory - reads from UserDefaults if customized, falls back to default.
    static var activeBackupDir: String {
        let custom = UserDefaults.standard.string(forKey: "phosphor.backupDirectory")
        if let custom, !custom.isEmpty, custom != defaultBackupDir {
            return custom
        }
        return defaultBackupDir
    }

    // MARK: - Discovery

    /// Scan the backup directory for all iOS backups and parse their metadata.
    func discoverBackups(at directory: String? = nil) {
        let dir = directory ?? Self.activeBackupDir
        let fm = FileManager.default

        guard fm.fileExists(atPath: dir) else {
            backups = []
            return
        }

        let contents = fm.sortedContents(atPath: dir)
        var discovered: [BackupInfo] = []

        for item in contents {
            let fullPath = (dir as NSString).appendingPathComponent(item)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: fullPath, isDirectory: &isDir), isDir.boolValue else { continue }

            // Valid backup directories contain Info.plist
            let infoPlist = (fullPath as NSString).appendingPathComponent("Info.plist")
            guard fm.fileExists(atPath: infoPlist) else { continue }

            if let backup = BackupInfo.fromDirectory(fullPath) {
                discovered.append(backup)
            }
        }

        // Sort by date, newest first
        backups = discovered.sorted { ($0.lastBackupDate ?? .distantPast) > ($1.lastBackupDate ?? .distantPast) }
    }

    // MARK: - Backup Creation

    /// Create a new backup for the specified device.
    /// Default method: pymobiledevice3 (supports latest iOS).
    /// Fallback: idevicebackup2 (libimobiledevice).
    func createBackup(
        udid: String,
        encrypted: Bool = false,
        onProgress: @escaping (String) -> Void
    ) async -> Bool {
        isCreatingBackup = true
        backupProgress = "Starting backup..."
        lastError = nil

        // Primary: pymobiledevice3 (supports all iOS versions including latest)
        let pySuccess = await createBackupViaPymobiledevice(udid: udid, full: true, onProgress: onProgress)
        if pySuccess {
            isCreatingBackup = false
            backupProgress = "Backup complete"
            discoverBackups()
            return true
        }

        // Fallback: idevicebackup2 (libimobiledevice)
        backupProgress = "pymobiledevice3 unavailable, trying idevicebackup2..."
        onProgress("Falling back to idevicebackup2...")

        let args = ["backup", "--full", "-u", udid, Self.activeBackupDir]

        return await withCheckedContinuation { continuation in
            Shell.runStreaming(
                "idevicebackup2",
                arguments: args,
                onOutput: { [weak self] output in
                    self?.backupProgress = output.trimmingCharacters(in: .whitespacesAndNewlines)
                    onProgress(output)
                },
                onError: { [weak self] error in
                    self?.lastError = error
                },
                completion: { [weak self] exitCode in
                    Task { @MainActor in
                        self?.isCreatingBackup = false
                        if exitCode == 0 {
                            self?.backupProgress = "Backup complete"
                            self?.discoverBackups()
                        } else {
                            self?.backupProgress = "Backup failed. Install pymobiledevice3: pip3 install pymobiledevice3"
                            self?.lastError = "Both backup methods failed. Your iOS version may require pymobiledevice3."
                        }
                        continuation.resume(returning: exitCode == 0)
                    }
                }
            )
        }
    }

    /// Backup using pymobiledevice3 (Python, supports latest iOS).
    private func createBackupViaPymobiledevice(udid: String, full: Bool, onProgress: @escaping (String) -> Void) async -> Bool {
        // Check if pymobiledevice3 is available
        let check = await Shell.runAsync("python3", arguments: ["-c", "import pymobiledevice3"], timeout: 10)
        guard check.succeeded else {
            lastError = "pymobiledevice3 not installed"
            return false
        }

        backupProgress = "Creating backup via pymobiledevice3..."
        onProgress("Creating backup via pymobiledevice3...")

        var args = ["backup2", "backup"]
        if full { args.append("--full") }
        args.append(Self.activeBackupDir)

        return await withCheckedContinuation { continuation in
            Shell.runStreaming(
                "python3",
                arguments: ["-m", "pymobiledevice3"] + args,
                onOutput: { [weak self] output in
                    let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        self?.backupProgress = trimmed
                        onProgress(trimmed)
                    }
                },
                onError: { [weak self] error in
                    self?.lastError = error
                },
                completion: { exitCode in
                    continuation.resume(returning: exitCode == 0)
                }
            )
        }
    }

    /// Create an incremental backup (only changed files).
    func createIncrementalBackup(
        udid: String,
        onProgress: @escaping (String) -> Void
    ) async -> Bool {
        isCreatingBackup = true
        backupProgress = "Starting incremental backup..."
        lastError = nil

        return await withCheckedContinuation { continuation in
            Shell.runStreaming(
                "idevicebackup2",
                arguments: ["backup", "-u", udid, Self.activeBackupDir],
                onOutput: { [weak self] output in
                    self?.backupProgress = output.trimmingCharacters(in: .whitespacesAndNewlines)
                    onProgress(output)
                },
                onError: { [weak self] error in
                    self?.lastError = error
                },
                completion: { [weak self] exitCode in
                    Task { @MainActor in
                        self?.isCreatingBackup = false
                        self?.backupProgress = exitCode == 0 ? "Backup complete" : "Backup failed"
                        if exitCode == 0 { self?.discoverBackups() }
                        continuation.resume(returning: exitCode == 0)
                    }
                }
            )
        }
    }

    // MARK: - Restore

    /// Restore a full backup to a device.
    func restoreBackup(
        backupPath: String,
        udid: String,
        onProgress: @escaping (String) -> Void
    ) async -> Bool {
        return await withCheckedContinuation { continuation in
            Shell.runStreaming(
                "idevicebackup2",
                arguments: ["restore", "--system", "--reboot", "-u", udid, backupPath],
                onOutput: { output in onProgress(output) },
                onError: { _ in },
                completion: { exitCode in
                    continuation.resume(returning: exitCode == 0)
                }
            )
        }
    }

    // MARK: - Backup Browsing

    /// Open a BackupManifest for browsing backup contents.
    func openManifest(for backup: BackupInfo) -> BackupManifest? {
        do {
            return try BackupManifest(backupPath: backup.path)
        } catch {
            lastError = "Failed to open backup manifest: \(error.localizedDescription)"
            return nil
        }
    }

    // MARK: - Selective Extract

    /// Extract specific files from a backup to a destination directory.
    func extractFiles(
        from backup: BackupInfo,
        entries: [BackupManifest.FileEntry],
        to destination: String
    ) throws -> Int {
        let manifest = try BackupManifest(backupPath: backup.path)
        var extracted = 0

        for entry in entries where entry.isFile {
            let destPath = (destination as NSString).appendingPathComponent(entry.fileName)
            do {
                try manifest.extractFile(entry, to: destPath)
                extracted += 1
            } catch {
                // Log but continue extracting other files
                lastError = "Failed to extract \(entry.fileName): \(error.localizedDescription)"
            }
        }

        return extracted
    }

    /// Extract an entire domain (e.g., CameraRollDomain) from a backup.
    func extractDomain(
        from backup: BackupInfo,
        domain: String,
        to destination: String
    ) throws -> Int {
        let manifest = try BackupManifest(backupPath: backup.path)
        let files = try manifest.files(inDomain: domain)
        return try extractFiles(from: backup, entries: files, to: destination)
    }

    // MARK: - Encryption

    /// Enable backup encryption for a device.
    func enableEncryption(udid: String, password: String) async -> Bool {
        let result = await Shell.runAsync(
            "idevicebackup2",
            arguments: ["-u", udid, "encryption", "on", password]
        )
        return result.succeeded
    }

    /// Disable backup encryption.
    func disableEncryption(udid: String, password: String) async -> Bool {
        let result = await Shell.runAsync(
            "idevicebackup2",
            arguments: ["-u", udid, "encryption", "off", password]
        )
        return result.succeeded
    }

    /// Check if backup encryption is enabled for a device.
    func isEncryptionEnabled(udid: String) async -> Bool {
        let result = await Shell.runAsync(
            "idevicebackup2",
            arguments: ["-u", udid, "encryption"]
        )
        return result.output.contains("on")
    }

    // MARK: - Cleanup

    /// Delete a backup from disk.
    func deleteBackup(_ backup: BackupInfo) throws {
        try FileManager.default.removeItem(atPath: backup.path)
        backups.removeAll { $0.id == backup.id }
    }

    /// Get total size of all backups.
    var totalBackupSize: UInt64 {
        backups.reduce(0) { $0 + $1.size }
    }
}
