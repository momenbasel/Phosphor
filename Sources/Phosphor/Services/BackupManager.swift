import Foundation
import Combine

/// Handles iOS backup operations: discovery, creation, browsing, and selective restore.
/// Primary: pymobiledevice3 (supports iOS 17-26+). Fallback: idevicebackup2.
@MainActor
final class BackupManager: ObservableObject {

    @Published var backups: [BackupInfo] = []
    @Published var isCreatingBackup = false
    @Published var backupProgress: String = ""
    @Published var backupPercent: Double = 0
    @Published var lastError: String?

    /// Active backup process for cancellation.
    private var activeProcess: Process?

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

            let infoPlist = (fullPath as NSString).appendingPathComponent("Info.plist")
            guard fm.fileExists(atPath: infoPlist) else { continue }

            if let backup = BackupInfo.fromDirectory(fullPath) {
                discovered.append(backup)
            }
        }

        backups = discovered.sorted { ($0.lastBackupDate ?? .distantPast) > ($1.lastBackupDate ?? .distantPast) }
    }

    // MARK: - Backup Creation

    /// Create a new backup. pymobiledevice3 primary, idevicebackup2 fallback.
    func createBackup(
        udid: String,
        encrypted: Bool = false,
        onProgress: @escaping (String) -> Void
    ) async -> Bool {
        isCreatingBackup = true
        backupProgress = "Starting backup..."
        backupPercent = 0
        lastError = nil

        // Ensure backup directory exists
        try? FileManager.default.createDirectory(atPath: Self.activeBackupDir, withIntermediateDirectories: true)

        // Primary: pymobiledevice3
        let pySuccess = await createBackupViaPymobiledevice(udid: udid, full: true, onProgress: onProgress)
        if pySuccess {
            isCreatingBackup = false
            backupProgress = "Backup complete"
            backupPercent = 1.0
            discoverBackups()
            return true
        }

        // Fallback: idevicebackup2
        backupProgress = "Trying idevicebackup2..."
        onProgress("Falling back to idevicebackup2...")

        let args = ["backup", "--full", "-u", udid, Self.activeBackupDir]

        return await withCheckedContinuation { continuation in
            Shell.runStreaming(
                "idevicebackup2",
                arguments: args,
                onOutput: { [weak self] output in
                    let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
                    self?.backupProgress = trimmed
                    if let pct = PyMobileDevice.parseProgress(from: trimmed) {
                        self?.backupPercent = pct
                    }
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
                            self?.backupPercent = 1.0
                            self?.discoverBackups()
                        } else {
                            self?.backupProgress = "Backup failed. Install pymobiledevice3: pip3 install pymobiledevice3"
                            self?.lastError = "Both backup methods failed."
                        }
                        continuation.resume(returning: exitCode == 0)
                    }
                }
            )
        }
    }

    /// Backup using pymobiledevice3.
    private func createBackupViaPymobiledevice(udid: String, full: Bool, onProgress: @escaping (String) -> Void) async -> Bool {
        guard PyMobileDevice.available() else {
            lastError = "pymobiledevice3 not installed"
            return false
        }

        backupProgress = "Creating backup via pymobiledevice3..."
        onProgress("Creating backup via pymobiledevice3...")

        return await withCheckedContinuation { continuation in
            activeProcess = PyMobileDevice.backup(
                directory: Self.activeBackupDir,
                udid: udid,
                full: full,
                onOutput: { [weak self] output in
                    let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        self?.backupProgress = trimmed
                        if let pct = PyMobileDevice.parseProgress(from: trimmed) {
                            self?.backupPercent = pct
                        }
                        onProgress(trimmed)
                    }
                },
                onError: { [weak self] error in
                    let trimmed = error.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        // pymobiledevice3 sends progress on stderr
                        if let pct = PyMobileDevice.parseProgress(from: trimmed) {
                            self?.backupPercent = pct
                            self?.backupProgress = "Backup: \(Int(pct * 100))%"
                        }
                    }
                },
                completion: { [weak self] exitCode in
                    self?.activeProcess = nil
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
        backupPercent = 0
        lastError = nil

        try? FileManager.default.createDirectory(atPath: Self.activeBackupDir, withIntermediateDirectories: true)

        // Primary: pymobiledevice3 (without --full flag)
        if PyMobileDevice.available() {
            let success = await createBackupViaPymobiledevice(udid: udid, full: false, onProgress: onProgress)
            if success {
                isCreatingBackup = false
                backupProgress = "Backup complete"
                backupPercent = 1.0
                discoverBackups()
                return true
            }
        }

        // Fallback: idevicebackup2
        return await withCheckedContinuation { continuation in
            Shell.runStreaming(
                "idevicebackup2",
                arguments: ["backup", "-u", udid, Self.activeBackupDir],
                onOutput: { [weak self] output in
                    let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
                    self?.backupProgress = trimmed
                    if let pct = PyMobileDevice.parseProgress(from: trimmed) {
                        self?.backupPercent = pct
                    }
                    onProgress(output)
                },
                onError: { [weak self] error in
                    self?.lastError = error
                },
                completion: { [weak self] exitCode in
                    Task { @MainActor in
                        self?.isCreatingBackup = false
                        self?.backupProgress = exitCode == 0 ? "Backup complete" : "Backup failed"
                        if exitCode == 0 {
                            self?.backupPercent = 1.0
                            self?.discoverBackups()
                        }
                        continuation.resume(returning: exitCode == 0)
                    }
                }
            )
        }
    }

    // MARK: - Restore

    /// Restore a backup to a device. pymobiledevice3 primary, idevicebackup2 fallback.
    func restoreBackup(
        backupPath: String,
        udid: String,
        onProgress: @escaping (String) -> Void
    ) async -> Bool {
        // Primary: pymobiledevice3
        if PyMobileDevice.available() {
            return await withCheckedContinuation { continuation in
                activeProcess = PyMobileDevice.restore(
                    directory: backupPath,
                    udid: udid,
                    onOutput: { output in onProgress(output) },
                    completion: { [weak self] exitCode in
                        self?.activeProcess = nil
                        continuation.resume(returning: exitCode == 0)
                    }
                )
            }
        }

        // Fallback: idevicebackup2
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

    /// Cancel an active backup/restore.
    func cancelBackup() {
        activeProcess?.terminate()
        activeProcess = nil
        isCreatingBackup = false
        backupProgress = "Cancelled"
    }

    // MARK: - Backup Browsing

    func openManifest(for backup: BackupInfo) -> BackupManifest? {
        do {
            return try BackupManifest(backupPath: backup.path)
        } catch {
            lastError = "Failed to open backup manifest: \(error.localizedDescription)"
            return nil
        }
    }

    // MARK: - Selective Extract

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
                lastError = "Failed to extract \(entry.fileName): \(error.localizedDescription)"
            }
        }

        return extracted
    }

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

    func enableEncryption(udid: String, password: String) async -> Bool {
        if await PyMobileDevice.setEncryption(enabled: true, password: password, udid: udid) { return true }
        return (await Shell.runAsync("idevicebackup2", arguments: ["-u", udid, "encryption", "on", password])).succeeded
    }

    func disableEncryption(udid: String, password: String) async -> Bool {
        if await PyMobileDevice.setEncryption(enabled: false, password: password, udid: udid) { return true }
        return (await Shell.runAsync("idevicebackup2", arguments: ["-u", udid, "encryption", "off", password])).succeeded
    }

    func changeEncryptionPassword(udid: String, oldPassword: String, newPassword: String) async -> Bool {
        return await PyMobileDevice.changeEncryptionPassword(oldPassword: oldPassword, newPassword: newPassword, udid: udid)
    }

    func isEncryptionEnabled(udid: String) async -> Bool {
        if PyMobileDevice.available() {
            return await PyMobileDevice.encryptionStatus(udid: udid)
        }
        let result = await Shell.runAsync("idevicebackup2", arguments: ["-u", udid, "encryption"])
        return result.output.contains("on")
    }

    // MARK: - Cleanup

    func deleteBackup(_ backup: BackupInfo) throws {
        try FileManager.default.removeItem(atPath: backup.path)
        backups.removeAll { $0.id == backup.id }
    }

    var totalBackupSize: UInt64 {
        backups.reduce(0) { $0 + $1.size }
    }
}
