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

    /// Maximum number of trailing stderr lines to retain for diagnostics on failure.
    private static let stderrTailLineLimit = 20

    /// Lines retained from the most recent pymobiledevice3 stderr stream.
    private var pymobiledeviceStderrTail: [String] = []

    /// Translate a pymobiledevice3 or idevicebackup2 stderr blob into a short actionable hint.
    private static func diagnosticHint(for stderr: String) -> String? {
        let lower = stderr.lowercased()
        if lower.contains("not paired") || lower.contains("pairingdialogresponsepending") || lower.contains("trust this computer") {
            return "Device is not trusted. Unlock it and tap 'Trust' when prompted, then try again."
        }
        if lower.contains("passcodesetuprequired") || lower.contains("setpasscode") {
            return "Set a passcode on the device before running an encrypted backup."
        }
        if lower.contains("no device found") || lower.contains("no devices connected") {
            return "No device detected. Reconnect the cable and ensure the device is unlocked."
        }
        if lower.contains("backupdomainoverridden") || lower.contains("mobilebackup2error") {
            return "iOS rejected the backup request. Disable/re-enable encryption or reboot the device."
        }
        if lower.contains("modulenotfounderror") || lower.contains("no module named") {
            return "pymobiledevice3 is installed but missing dependencies. Reinstall with: pip3 install --upgrade pymobiledevice3"
        }
        if lower.contains("invalidservice") || lower.contains("remotexpc") || lower.contains("tunneld") {
            return "Backup requires an up-to-date pymobiledevice3. Upgrade with: pip3 install --upgrade pymobiledevice3"
        }
        if lower.contains("is not readable") || lower.contains("permission denied") || lower.contains("operation not permitted") {
            return """
            macOS is blocking access to the backup directory. The easiest fix is to switch Phosphor's backup directory to a user-owned location:
            Phosphor -> Settings -> Backup Directory -> ~/Documents/Phosphor Backups.
            Only if you specifically want Phosphor to read Apple's shared MobileSync backups do you need to grant Full Disk Access (System Settings -> Privacy & Security -> Full Disk Access). Full Disk Access is not recommended - Phosphor does not need it for its own backups.
            """
        }
        return nil
    }

    /// Preflight check: verify the active backup directory exists and is readable/writable
    /// by this process. ~/Library/Application Support/MobileSync/Backup is TCC-protected
    /// on macOS 10.15+ and requires Full Disk Access for sandboxed or unsigned apps.
    static func validateBackupDirectory(_ path: String) -> (ok: Bool, reason: String?) {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        if !fm.fileExists(atPath: path, isDirectory: &isDir) {
            do {
                try fm.createDirectory(atPath: path, withIntermediateDirectories: true)
            } catch {
                return (false, "Cannot create backup directory at \(path): \(error.localizedDescription)")
            }
            return (true, nil)
        }
        if !isDir.boolValue {
            return (false, "\(path) exists but is not a directory.")
        }
        if !fm.isReadableFile(atPath: path) || !fm.isWritableFile(atPath: path) {
            let isDefault = (path == defaultBackupDir)
            var msg = "Phosphor cannot read or write \(path)."
            if isDefault {
                msg += """


                This is the system MobileSync directory which macOS protects with TCC.
                Grant Phosphor 'Full Disk Access':
                System Settings -> Privacy & Security -> Full Disk Access -> enable Phosphor, then restart the app.
                Alternatively, pick a different backup directory in Phosphor > Settings (for example ~/Documents/Phosphor Backups).
                """
            }
            return (false, msg)
        }
        return (true, nil)
    }

    /// Build a composite error string combining stderr tail and diagnostic hint.
    private static func composeFailureMessage(primary: String, stderr: String) -> String {
        let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let hint = diagnosticHint(for: trimmed)
        var lines: [String] = [primary]
        if let hint { lines.append(hint) }
        if !trimmed.isEmpty {
            let tail = trimmed
                .components(separatedBy: "\n")
                .suffix(stderrTailLineLimit)
                .joined(separator: "\n")
            lines.append("Details:\n\(tail)")
        }
        return lines.joined(separator: "\n\n")
    }

    /// Phosphor's default backup location: inside ~/Documents so no special permission
    /// grant is needed, and so Phosphor never shares a directory with Finder's backups
    /// (a misbehaving run could otherwise corrupt the user's Finder backups).
    static let defaultBackupDir: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/Documents/Phosphor Backups"
    }()

    /// Apple's MobileSync directory. Kept as a named constant so settings UI and
    /// migration logic can offer it to users who explicitly opt in.
    static let systemMobileSyncDir: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/Library/Application Support/MobileSync/Backup"
    }()

    /// UserDefaults key for the active backup directory.
    static let backupDirectoryUserDefaultsKey = "phosphor.backupDirectory"

    /// Active backup directory. Falls back to the default when no override is set.
    static var activeBackupDir: String {
        let custom = UserDefaults.standard.string(forKey: backupDirectoryUserDefaultsKey)
        if let custom, !custom.isEmpty {
            return custom
        }
        return defaultBackupDir
    }

    /// One-time migration for users upgrading from <= 1.0.3. Earlier versions defaulted to
    /// the system MobileSync directory without recording the choice in UserDefaults. Rather
    /// than silently orphan their backups when the default flipped to Documents, pin the
    /// MobileSync path as an explicit override if it actually contains Phosphor-visible
    /// backup directories. Safe to call on every launch - the `migrated` flag makes it idempotent.
    static func migrateLegacyBackupDirectory(defaults: UserDefaults = .standard) {
        let migrationKey = "phosphor.backupDirectory.migratedFromMobileSync"
        if defaults.bool(forKey: migrationKey) { return }
        defer { defaults.set(true, forKey: migrationKey) }

        // User already has a chosen directory - nothing to migrate.
        if let existing = defaults.string(forKey: backupDirectoryUserDefaultsKey),
           !existing.isEmpty {
            return
        }

        let fm = FileManager.default
        guard fm.fileExists(atPath: systemMobileSyncDir) else { return }

        // Only pin MobileSync if we can actually read it AND it holds a UDID-shaped backup
        // Info.plist. Otherwise the new Documents default is strictly better.
        let contents = (try? fm.contentsOfDirectory(atPath: systemMobileSyncDir)) ?? []
        let hasBackup = contents.contains { name in
            let info = "\(systemMobileSyncDir)/\(name)/Info.plist"
            return fm.isReadableFile(atPath: info)
        }
        if hasBackup {
            defaults.set(systemMobileSyncDir, forKey: backupDirectoryUserDefaultsKey)
        }
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

        // Preflight: bail early with a clear message when the directory is unreadable
        // (most commonly a Full Disk Access grant missing on the default location).
        let preflight = Self.validateBackupDirectory(Self.activeBackupDir)
        if !preflight.ok {
            isCreatingBackup = false
            backupProgress = "Backup failed"
            lastError = preflight.reason
            onProgress(preflight.reason ?? "Backup directory is not accessible.")
            return false
        }

        // Primary: pymobiledevice3
        let pySuccess = await createBackupViaPymobiledevice(udid: udid, full: true, onProgress: onProgress)
        if pySuccess {
            isCreatingBackup = false
            backupProgress = "Backup complete"
            backupPercent = 1.0
            discoverBackups()
            return true
        }

        let pymobiledeviceStderr = pymobiledeviceStderrTail.joined(separator: "\n")

        // Fallback: idevicebackup2
        backupProgress = "Trying idevicebackup2..."
        onProgress("Falling back to idevicebackup2...")

        let args = ["backup", "--full", "-u", udid, Self.activeBackupDir]
        var idevicebackupStderr = ""

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
                onError: { error in
                    idevicebackupStderr.append(error)
                },
                completion: { [weak self] exitCode in
                    Task { @MainActor in
                        guard let self else {
                            continuation.resume(returning: exitCode == 0)
                            return
                        }
                        self.isCreatingBackup = false
                        if exitCode == 0 {
                            self.backupProgress = "Backup complete"
                            self.backupPercent = 1.0
                            self.discoverBackups()
                        } else {
                            let combinedStderr = [pymobiledeviceStderr, idevicebackupStderr]
                                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                                .joined(separator: "\n---\n")
                            self.backupProgress = "Backup failed"
                            self.lastError = Self.composeFailureMessage(
                                primary: "Both backup methods failed.",
                                stderr: combinedStderr
                            )
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
            lastError = "pymobiledevice3 not installed. Install with: pip3 install pymobiledevice3"
            return false
        }

        backupProgress = "Creating backup via pymobiledevice3..."
        onProgress("Creating backup via pymobiledevice3...")
        pymobiledeviceStderrTail.removeAll()

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
                    guard !trimmed.isEmpty else { return }
                    // pymobiledevice3 sends progress on stderr.
                    if let pct = PyMobileDevice.parseProgress(from: trimmed) {
                        self?.backupPercent = pct
                        self?.backupProgress = "Backup: \(Int(pct * 100))%"
                        return
                    }
                    // Retain non-progress stderr lines so a failure surfaces the real reason.
                    guard let self else { return }
                    for line in trimmed.components(separatedBy: "\n") {
                        let l = line.trimmingCharacters(in: .whitespacesAndNewlines)
                        if l.isEmpty { continue }
                        self.pymobiledeviceStderrTail.append(l)
                        if self.pymobiledeviceStderrTail.count > Self.stderrTailLineLimit {
                            self.pymobiledeviceStderrTail.removeFirst(
                                self.pymobiledeviceStderrTail.count - Self.stderrTailLineLimit
                            )
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

        let preflight = Self.validateBackupDirectory(Self.activeBackupDir)
        if !preflight.ok {
            isCreatingBackup = false
            backupProgress = "Backup failed"
            lastError = preflight.reason
            onProgress(preflight.reason ?? "Backup directory is not accessible.")
            return false
        }

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

        let pymobiledeviceStderr = pymobiledeviceStderrTail.joined(separator: "\n")
        var idevicebackupStderr = ""

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
                onError: { error in
                    idevicebackupStderr.append(error)
                },
                completion: { [weak self] exitCode in
                    Task { @MainActor in
                        guard let self else {
                            continuation.resume(returning: exitCode == 0)
                            return
                        }
                        self.isCreatingBackup = false
                        if exitCode == 0 {
                            self.backupProgress = "Backup complete"
                            self.backupPercent = 1.0
                            self.discoverBackups()
                        } else {
                            let combinedStderr = [pymobiledeviceStderr, idevicebackupStderr]
                                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                                .joined(separator: "\n---\n")
                            self.backupProgress = "Backup failed"
                            self.lastError = Self.composeFailureMessage(
                                primary: "Incremental backup failed via both backends.",
                                stderr: combinedStderr
                            )
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
