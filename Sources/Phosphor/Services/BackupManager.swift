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
    @Published var lastBackupFailure: BackupFailure?
    @Published var lastOperationWasCancelled = false

    enum RecoveryAction: String, Hashable {
        case runFullBackup
        case deleteIncompleteAndRunFull
        case openBackupSettings
        case retry
    }

    struct BackupFailure: Identifiable, Hashable {
        let id = UUID()
        let title: String
        let message: String
        let technicalDetails: String?
        let recoveryAction: RecoveryAction?
        let udid: String?
        let recoveryPath: String?

        init(
            title: String,
            message: String,
            technicalDetails: String?,
            recoveryAction: RecoveryAction?,
            udid: String? = nil,
            recoveryPath: String? = nil
        ) {
            self.title = title
            self.message = message
            self.technicalDetails = technicalDetails
            self.recoveryAction = recoveryAction
            self.udid = udid
            self.recoveryPath = recoveryPath
        }
    }

    enum BackupMetadataHealth: Equatable {
        case complete
        case missing
        case incomplete(path: String)
    }

    /// Active managed backup session leader for cancellation (#63 replaced
    /// Foundation.Process with a posix_spawn session leader so the whole process
    /// group can be signalled). Ownership is shared across manager instances by
    /// device UDID, allowing different devices to run concurrently without
    /// permitting two writers to operate on the same physical device (#60).
    private static var operationRegistry = BackupOperationRegistry()
    private var activeProcess: Shell.ManagedProcess?
    private var operationCoordinator = BackupDeviceCoordinator()
    private var cancelledOperationIDs: Set<UUID> = []

    private func beginCancellableOperation(udid: String) -> UUID? {
        // Reset before either rejection branch, not between them. With these
        // below the first guard, a contention refusal left the PREVIOUS
        // operation's lastBackupFailure in place, so BackupViewModel.createBackup
        // read it and re-presented a stale "Incomplete Backup Found" recovery
        // sheet - offering "Delete Incomplete Backup and Run Full Backup" in
        // response to an unrelated event, while the real reason sat unread in
        // lastError.
        lastOperationWasCancelled = false
        lastBackupFailure = nil
        guard operationCoordinator.activeOperationID == nil else {
            lastError = "Another backup or restore operation is already running."
            return nil
        }
        guard let operationID = operationCoordinator.begin(
            udid: udid,
            registry: &Self.operationRegistry
        ) else {
            lastError = "Another backup or restore operation is already running for this device."
            return nil
        }
        return operationID
    }

    private func operationWasCancelled(_ id: UUID) -> Bool {
        cancelledOperationIDs.contains(id)
    }

    private func finishOperation(_ id: UUID) {
        if operationCoordinator.finish(operationID: id, registry: &Self.operationRegistry) {
            activeProcess = nil
            isCreatingBackup = false
        }
        cancelledOperationIDs.remove(id)
    }

    private func markOperationCancelled(_ id: UUID, progress: String = "Cancelled") {
        if operationCoordinator.activeOperationID == id {
            lastOperationWasCancelled = true
            backupProgress = progress
            lastError = nil
            lastBackupFailure = nil
        }
        finishOperation(id)
    }

    /// Maximum number of trailing stderr lines to retain for diagnostics on failure.
    private static let stderrTailLineLimit = 20

    /// Device backup/restore subprocesses should eventually complete. Bound them so
    /// a wedged CLI cannot leave backup UI progress and checked continuations stuck forever.
    private static let streamingBackupTimeout: TimeInterval = 6 * 60 * 60
    private static let streamingRestoreTimeout: TimeInterval = 6 * 60 * 60

    /// Lines retained from the most recent pymobiledevice3 stderr stream.
    private var pymobiledeviceStderrTail: [String] = []

    /// Translate a pymobiledevice3 or idevicebackup2 stderr blob into a short actionable hint.
    private static func diagnostic(for stderr: String) -> (hint: String?, action: RecoveryAction?) {
        let lower = stderr.lowercased()
        if lower.contains("not paired") || lower.contains("pairingdialogresponsepending") || lower.contains("trust this computer") {
            return ("Device is not trusted. Unlock it and tap 'Trust' when prompted, then try again.", .retry)
        }
        if lower.contains("passcodesetuprequired") || lower.contains("setpasscode") {
            return ("Set a passcode on the device before running an encrypted backup.", .retry)
        }
        if lower.contains("no device found") || lower.contains("no devices connected") {
            return ("No device detected. Reconnect the cable and ensure the device is unlocked.", .retry)
        }
        if lower.contains("backupdomainoverridden") || lower.contains("mobilebackup2error") {
            return ("iOS rejected the backup request. Disable/re-enable encryption or reboot the device.", .retry)
        }
        if lower.contains("modulenotfounderror") || lower.contains("no module named") {
            return ("pymobiledevice3 is installed but missing dependencies. Reinstall with: pipx reinstall pymobiledevice3", nil)
        }
        if lower.contains("invalidservice") || lower.contains("remotexpc") || lower.contains("tunneld") {
            return ("Backup requires an up-to-date pymobiledevice3. Upgrade with: pipx upgrade pymobiledevice3", .retry)
        }
        if lower.contains("zero-length") || lower.contains("cannot parse a null") || lower.contains("mberrordomain/205") || lower.contains("error reading backup properties") {
            return ("The existing backup metadata appears incomplete or corrupt. Delete the incomplete backup or choose a fresh local backup folder, then run a full backup with the device unlocked.", .deleteIncompleteAndRunFull)
        }
        if lower.contains("is not readable") || lower.contains("permission denied") || lower.contains("operation not permitted") {
            return ("""
            macOS is blocking access to the backup directory. The easiest fix is to switch Phosphor's backup directory to a user-owned location:
            Phosphor -> Settings -> Backup Directory -> ~/Documents/Phosphor Backups.
            Only if you specifically want Phosphor to read Apple's shared MobileSync backups do you need to grant Full Disk Access (System Settings -> Privacy & Security -> Full Disk Access). Full Disk Access is not recommended - Phosphor does not need it for its own backups.
            """, .openBackupSettings)
        }
        return (nil, nil)
    }

    /// Preflight check: verify the active backup directory exists and is readable/writable
    /// by this process. ~/Library/Application Support/MobileSync/Backup is TCC-protected
    /// on macOS 10.15+ and requires Full Disk Access for sandboxed or unsigned apps.
    static func validateBackupDirectory(_ path: String, createIfMissing: Bool = true) -> (ok: Bool, reason: String?) {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        if !fm.fileExists(atPath: path, isDirectory: &isDir) {
            guard createIfMissing else {
                return (false, "Backup directory does not exist at \(path).")
            }
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
            let isMobileSync = (path == systemMobileSyncDir)
            var msg = "Phosphor cannot read or write \(path)."
            if isMobileSync {
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

    /// Cloud file-provider folders can hydrate files lazily and expose partial
    /// metadata while syncing. They are risky as the live target for iOS backups.
    static func backupDirectoryWarning(for path: String) -> String? {
        let expanded = (path as NSString).expandingTildeInPath
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let cloudRoots = [
            "\(home)/Library/CloudStorage",
            "\(home)/Library/Mobile Documents",
            "\(home)/Dropbox",
            "\(home)/Google Drive",
            "\(home)/OneDrive",
            "\(home)/SynologyDrive"
        ]
        if cloudRoots.contains(where: { expanded == $0 || expanded.hasPrefix($0 + "/") }) {
            return "Cloud-synced folders are not recommended for live iOS backups. Use a local folder, then sync or export completed backups afterward."
        }
        return nil
    }

    /// Build a composite error string combining stderr tail and diagnostic hint.
    private static func composeFailureMessage(primary: String, stderr: String) -> String {
        let failure = backupFailure(primary: primary, stderr: stderr)
        return [failure.title, failure.message, failure.technicalDetails.map { "Details:\n\($0)" }]
            .compactMap { $0 }
            .joined(separator: "\n\n")
    }

    private static func backupFailure(primary: String, stderr: String, udid: String? = nil, recoveryPath: String? = nil) -> BackupFailure {
        let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let diagnostic = diagnostic(for: trimmed)
        var lines: [String] = [primary]
        if let hint = diagnostic.hint { lines.append(hint) }
        let tail = trimmed.isEmpty ? nil : trimmed
            .components(separatedBy: "\n")
            .suffix(stderrTailLineLimit)
            .joined(separator: "\n")
        return BackupFailure(
            title: "Backup Failed",
            message: lines.joined(separator: "\n\n"),
            technicalDetails: tail,
            recoveryAction: diagnostic.action,
            udid: udid,
            recoveryPath: recoveryPath
        )
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

        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: dir, isDirectory: &isDir) else {
            backups = []
            lastError = nil
            return
        }
        guard isDir.boolValue else {
            backups = []
            lastError = "\(dir) is not a directory."
            return
        }

        // Single-backup case: the chosen dir is itself a UDID backup folder
        // (contains Info.plist + Manifest.* at its root). Common when a user
        // points the picker at an individual backup rather than its parent.
        if Self.looksLikeBackupFolder(dir),
           let single = BackupInfo.fromDirectory(dir, includeSize: false) {
            backups = [single]
            lastError = nil
            return
        }

        let contents: [String]
        do {
            contents = try fm.contentsOfDirectory(atPath: dir).sorted()
        } catch {
            backups = []
            // TCC denial on ~/Library/Application Support/MobileSync/Backup
            // surfaces as a permission error here. Tell the user how to fix it.
            let isMobileSync = (dir == Self.systemMobileSyncDir)
            var msg = "Cannot read backup directory at \(dir): \(error.localizedDescription)"
            if isMobileSync {
                msg += """


                macOS protects Apple's MobileSync backups with TCC. Grant Phosphor Full Disk Access:
                System Settings -> Privacy & Security -> Full Disk Access -> enable Phosphor, then restart the app.
                Alternatively, copy a backup folder into ~/Documents/Phosphor Backups or use Phosphor > Settings to point at a non-protected location.
                """
            }
            lastError = msg
            return
        }

        var discovered: [BackupInfo] = []
        for item in contents {
            let fullPath = (dir as NSString).appendingPathComponent(item)
            var itemIsDir: ObjCBool = false
            guard fm.fileExists(atPath: fullPath, isDirectory: &itemIsDir), itemIsDir.boolValue else { continue }

            guard Self.looksLikeBackupFolder(fullPath) else { continue }

            if let backup = BackupInfo.fromDirectory(fullPath, includeSize: false) {
                discovered.append(backup)
            }
        }

        backups = discovered.sorted { ($0.lastBackupDate ?? .distantPast) > ($1.lastBackupDate ?? .distantPast) }
        lastError = nil
    }

    /// True when a backup metadata file exists AND has real content. An interrupted
    /// backup often leaves zero-length Info.plist / Manifest.* stubs; treating those
    /// as complete makes incremental backups fail with MBErrorDomain/205 (the exact
    /// "cannot parse null plist" failure the completeness check exists to prevent).
    static func isNonEmptyFile(_ path: String) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attributes[.size] as? UInt64 else {
            return false
        }
        return size > 0
    }

    /// True when `path` looks like a single iOS backup folder (UDID dir with Info.plist + Manifest.*).
    static func looksLikeBackupFolder(_ path: String) -> Bool {
        let info = (path as NSString).appendingPathComponent("Info.plist")
        let manifestPlist = (path as NSString).appendingPathComponent("Manifest.plist")
        let manifestDb = (path as NSString).appendingPathComponent("Manifest.db")
        return isNonEmptyFile(info) &&
               (isNonEmptyFile(manifestPlist) || isNonEmptyFile(manifestDb))
    }

    static func backupPath(for udid: String, in directory: String? = nil) -> String {
        let rootDirectory = directory ?? activeBackupDir
        return (rootDirectory as NSString).appendingPathComponent(udid)
    }

    /// Check whether a device has complete backup metadata, no backup folder,
    /// or an interrupted partial folder that should be cleaned up before retry.
    static func backupMetadataHealth(for udid: String, in directory: String? = nil) -> BackupMetadataHealth {
        let deviceDirectory = backupPath(for: udid, in: directory)
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: deviceDirectory, isDirectory: &isDir) else {
            return .missing
        }
        guard isDir.boolValue else { return .incomplete(path: deviceDirectory) }
        return looksLikeBackupFolder(deviceDirectory) ? .complete : .incomplete(path: deviceDirectory)
    }

    /// Incremental backups require an existing valid backup metadata folder for
    /// the target UDID. If the folder is missing or partially-created, both
    /// backup backends fail with low-level MBErrorDomain/205 plist errors.
    static func hasExistingBackup(for udid: String, in directory: String? = nil) -> Bool {
        backupMetadataHealth(for: udid, in: directory) == .complete
    }

    static func incompleteBackupHasKnownMarkers(_ path: String) -> Bool {
        let knownMarkers = ["Info.plist", "Status.plist", "Manifest.plist", "Manifest.db", "Manifest.mbdb"]
        return knownMarkers.contains { marker in
            FileManager.default.fileExists(atPath: (path as NSString).appendingPathComponent(marker))
        }
    }

    static func deleteIncompleteBackup(for udid: String, expectedPath: String? = nil, in directory: String? = nil) throws {
        guard case .incomplete(let path) = backupMetadataHealth(for: udid, in: directory) else { return }
        if let expectedPath, (expectedPath as NSString).standardizingPath != (path as NSString).standardizingPath {
            throw NSError(domain: "Phosphor.Backup", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "The incomplete backup path changed. Refresh backups and try again."
            ])
        }

        let expectedBackupPath = backupPath(for: udid, in: directory)
        guard (path as NSString).standardizingPath == (expectedBackupPath as NSString).standardizingPath else {
            throw NSError(domain: "Phosphor.Backup", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Refusing to delete an unexpected backup path: \(path)"
            ])
        }

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            throw NSError(domain: "Phosphor.Backup", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "Refusing to delete a non-directory backup path: \(path)"
            ])
        }

        guard incompleteBackupHasKnownMarkers(path) else {
            throw NSError(domain: "Phosphor.Backup", code: 4, userInfo: [
                NSLocalizedDescriptionKey: "Refusing to delete \(path) because it does not contain recognizable iOS backup metadata. Delete it manually if you are sure it is safe."
            ])
        }

        var trashedURL: NSURL?
        try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: &trashedURL)
    }

    // MARK: - Backup Creation

    private func finalizeSuccessfulBackup(
        udid: String,
        directory: String,
        operationID: UUID,
        onProgress: @escaping (String) -> Void
    ) -> Bool {
        switch Self.backupMetadataHealth(for: udid, in: directory) {
        case .complete:
            finishOperation(operationID)
            backupProgress = "Backup complete"
            backupPercent = 1.0
            discoverBackups(at: directory)
            onProgress("Backup complete")
            return true
        case .missing:
            let path = Self.backupPath(for: udid, in: directory)
            finishOperation(operationID)
            backupProgress = "Backup metadata incomplete"
            lastBackupFailure = BackupFailure(
                title: "Backup Metadata Incomplete",
                message: "The backup command finished, but Phosphor could not find complete backup metadata. Run a fresh full backup with the device unlocked and connected over USB when possible.",
                technicalDetails: path,
                recoveryAction: .runFullBackup,
                udid: udid,
                recoveryPath: path
            )
            lastError = lastBackupFailure?.message
            onProgress(lastError ?? "Backup metadata incomplete.")
            return false
        case .incomplete(let path):
            finishOperation(operationID)
            backupProgress = "Backup metadata incomplete"
            lastBackupFailure = BackupFailure(
                title: "Backup Metadata Incomplete",
                message: "The backup command finished, but the resulting backup metadata is incomplete. Move the incomplete folder to Trash, then run a fresh full backup with the device unlocked and connected over USB when possible.",
                technicalDetails: path,
                recoveryAction: .deleteIncompleteAndRunFull,
                udid: udid,
                recoveryPath: path
            )
            lastError = lastBackupFailure?.message
            onProgress(lastError ?? "Backup metadata incomplete.")
            return false
        }
    }

    /// Create a new backup. pymobiledevice3 primary, idevicebackup2 fallback.
    func createBackup(
        udid: String,
        encrypted: Bool = false,
        preferNetwork: Bool = false,
        onProgress: @escaping (String) -> Void
    ) async -> Bool {
        // Per-device ownership first (#60): if another owner already holds this
        // UDID we must not take the comparison gate on its behalf.
        guard let operationID = beginCancellableOperation(udid: udid) else { return false }
        let backupRoot = Self.activeBackupDir
        // Then the reader/writer gate (#70). beginBackup preempts any in-flight
        // comparison rather than being refused by one, so this always succeeds.
        let coordinatorToken = BackupOperationCoordinator.shared.beginBackup()
        defer {
            if let coordinatorToken { BackupOperationCoordinator.shared.endBackup(coordinatorToken) }
        }
        isCreatingBackup = true
        backupProgress = "Starting backup..."
        backupPercent = 0
        lastError = nil
        lastBackupFailure = nil

        // Preflight: bail early with a clear message when the directory is unreadable
        // (most commonly a Full Disk Access grant missing on the default location).
        let preflight = Self.validateBackupDirectory(backupRoot)
        if !preflight.ok {
            finishOperation(operationID)
            backupProgress = "Backup failed"
            lastError = preflight.reason
            lastBackupFailure = BackupFailure(
                title: "Backup Folder Not Accessible",
                message: preflight.reason ?? "Phosphor cannot read or write the selected backup folder.",
                technicalDetails: backupRoot,
                recoveryAction: .openBackupSettings,
                udid: udid,
                recoveryPath: backupRoot
            )
            onProgress(preflight.reason ?? "Backup directory is not accessible.")
            return false
        }

        if case .incomplete(let path) = Self.backupMetadataHealth(for: udid, in: backupRoot) {
            finishOperation(operationID)
            backupProgress = "Incomplete backup found"
            lastBackupFailure = BackupFailure(
                title: "Incomplete Backup Found",
                message: "A previous backup for this device did not finish, so iOS may reject another backup in this folder. Delete the incomplete folder, then run a full backup again.",
                technicalDetails: path,
                recoveryAction: .deleteIncompleteAndRunFull,
                udid: udid,
                recoveryPath: path
            )
            lastError = lastBackupFailure?.message
            onProgress(lastError ?? "Incomplete backup found.")
            return false
        }

        // Primary: pymobiledevice3
        let pySuccess = await createBackupViaPymobiledevice(
            udid: udid,
            directory: backupRoot,
            full: true,
            preferNetwork: preferNetwork,
            operationID: operationID,
            onProgress: onProgress
        )
        if pySuccess {
            return finalizeSuccessfulBackup(udid: udid, directory: backupRoot, operationID: operationID, onProgress: onProgress)
        }
        if operationWasCancelled(operationID) {
            markOperationCancelled(operationID)
            return false
        }

        let pymobiledeviceStderr = pymobiledeviceStderrTail.joined(separator: "\n")

        // Fallback: idevicebackup2
        backupProgress = "Backing up..."
        onProgress("Backing up")

        let args = idevicebackupArguments(udid: udid, directory: backupRoot, full: true, preferNetwork: preferNetwork)
        var idevicebackupStderr = ""

        return await withCheckedContinuation { continuation in
            activeProcess = Shell.runStreaming(
                "idevicebackup2",
                arguments: args,
                timeout: Self.streamingBackupTimeout,
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
                            continuation.resume(returning: false)
                            return
                        }
                        if self.operationWasCancelled(operationID) {
                            self.markOperationCancelled(operationID)
                            continuation.resume(returning: false)
                            return
                        }
                        if exitCode == 0 {
                            let verified = self.finalizeSuccessfulBackup(udid: udid, directory: backupRoot, operationID: operationID, onProgress: onProgress)
                            continuation.resume(returning: verified)
                            return
                        } else {
                            let combinedStderr = [pymobiledeviceStderr, idevicebackupStderr]
                                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                                .joined(separator: "\n---\n")
                            self.finishOperation(operationID)
                            self.backupProgress = "Backup failed"
                            let failure = Self.backupFailure(
                                primary: "Both backup methods failed.",
                                stderr: combinedStderr,
                                udid: udid,
                                recoveryPath: Self.backupPath(for: udid, in: backupRoot)
                            )
                            self.lastBackupFailure = failure
                            self.lastError = Self.composeFailureMessage(
                                primary: "Both backup methods failed.",
                                stderr: combinedStderr
                            )
                        }
                        continuation.resume(returning: false)
                    }
                }
            )
        }
    }

    private func idevicebackupArguments(udid: String, directory: String, full: Bool, preferNetwork: Bool) -> [String] {
        var args = ["-u", udid]
        if preferNetwork { args.append("-n") }
        args.append("backup")
        if full { args.append("--full") }
        args.append(directory)
        return args
    }

    /// Backup using pymobiledevice3.
    private func createBackupViaPymobiledevice(
        udid: String,
        directory: String,
        full: Bool,
        preferNetwork: Bool,
        operationID: UUID,
        onProgress: @escaping (String) -> Void
    ) async -> Bool {
        guard PyMobileDevice.available() else {
            lastError = "pymobiledevice3 not installed. Install with: pipx install pymobiledevice3"
            return false
        }

        backupProgress = "Backing up..."
        onProgress("Backing up")
        pymobiledeviceStderrTail.removeAll()

        return await withCheckedContinuation { continuation in
            activeProcess = PyMobileDevice.backup(
                directory: directory,
                udid: udid,
                full: full,
                preferNetwork: preferNetwork,
                timeout: Self.streamingBackupTimeout,
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
                        onProgress("Backing up \(Int(pct * 100))%")
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
                    Task { @MainActor in
                        guard let self else {
                            continuation.resume(returning: false)
                            return
                        }
                        if self.operationCoordinator.activeOperationID == operationID {
                            self.activeProcess = nil
                        }
                        if self.operationWasCancelled(operationID) {
                            continuation.resume(returning: false)
                            return
                        }
                        continuation.resume(returning: exitCode == 0)
                    }
                }
            )
        }
    }

    /// Create an incremental backup (only changed files).
    func createIncrementalBackup(
        udid: String,
        preferNetwork: Bool = false,
        onProgress: @escaping (String) -> Void
    ) async -> Bool {
        // Per-device ownership first (#60): if another owner already holds this
        // UDID we must not take the comparison gate on its behalf.
        guard let operationID = beginCancellableOperation(udid: udid) else { return false }
        let backupRoot = Self.activeBackupDir
        // Then the reader/writer gate (#70). beginBackup preempts any in-flight
        // comparison rather than being refused by one, so this always succeeds.
        let coordinatorToken = BackupOperationCoordinator.shared.beginBackup()
        defer {
            if let coordinatorToken { BackupOperationCoordinator.shared.endBackup(coordinatorToken) }
        }
        isCreatingBackup = true
        backupProgress = "Starting incremental backup..."
        backupPercent = 0
        lastError = nil
        lastBackupFailure = nil

        let preflight = Self.validateBackupDirectory(backupRoot)
        if !preflight.ok {
            finishOperation(operationID)
            backupProgress = "Backup failed"
            lastError = preflight.reason
            lastBackupFailure = BackupFailure(
                title: "Backup Folder Not Accessible",
                message: preflight.reason ?? "Phosphor cannot read or write the selected backup folder.",
                technicalDetails: backupRoot,
                recoveryAction: .openBackupSettings,
                udid: udid,
                recoveryPath: backupRoot
            )
            onProgress(preflight.reason ?? "Backup directory is not accessible.")
            return false
        }

        switch Self.backupMetadataHealth(for: udid, in: backupRoot) {
        case .complete:
            break
        case .missing:
            finishOperation(operationID)
            backupProgress = "Backup needs a full backup first"
            lastBackupFailure = BackupFailure(
                title: "Full Backup Required",
                message: "No complete backup exists for this device yet. Run a full backup first; future Wi-Fi backups can be incremental.",
                technicalDetails: Self.backupPath(for: udid, in: backupRoot),
                recoveryAction: .runFullBackup,
                udid: udid,
                recoveryPath: Self.backupPath(for: udid, in: backupRoot)
            )
            lastError = lastBackupFailure?.message
            onProgress(lastError ?? "Run a full backup first.")
            return false
        case .incomplete(let path):
            finishOperation(operationID)
            backupProgress = "Incomplete backup found"
            lastBackupFailure = BackupFailure(
                title: "Incomplete Backup Found",
                message: "A previous backup for this device did not finish. Delete the incomplete folder, then run a full backup again.",
                technicalDetails: path,
                recoveryAction: .deleteIncompleteAndRunFull,
                udid: udid,
                recoveryPath: path
            )
            lastError = lastBackupFailure?.message
            onProgress(lastError ?? "Incomplete backup found.")
            return false
        }

        // Primary: pymobiledevice3 (without --full flag)
        if PyMobileDevice.available() {
            let success = await createBackupViaPymobiledevice(
                udid: udid,
                directory: backupRoot,
                full: false,
                preferNetwork: preferNetwork,
                operationID: operationID,
                onProgress: onProgress
            )
            if success {
                return finalizeSuccessfulBackup(udid: udid, directory: backupRoot, operationID: operationID, onProgress: onProgress)
            }
            if operationWasCancelled(operationID) {
                markOperationCancelled(operationID)
                return false
            }
        }

        let pymobiledeviceStderr = pymobiledeviceStderrTail.joined(separator: "\n")
        var idevicebackupStderr = ""

        // Fallback: idevicebackup2
        return await withCheckedContinuation { continuation in
            activeProcess = Shell.runStreaming(
                "idevicebackup2",
                arguments: idevicebackupArguments(udid: udid, directory: backupRoot, full: false, preferNetwork: preferNetwork),
                timeout: Self.streamingBackupTimeout,
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
                            continuation.resume(returning: false)
                            return
                        }
                        if self.operationWasCancelled(operationID) {
                            self.markOperationCancelled(operationID)
                            continuation.resume(returning: false)
                            return
                        }
                        if exitCode == 0 {
                            let verified = self.finalizeSuccessfulBackup(udid: udid, directory: backupRoot, operationID: operationID, onProgress: onProgress)
                            continuation.resume(returning: verified)
                            return
                        } else {
                            let combinedStderr = [pymobiledeviceStderr, idevicebackupStderr]
                                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                                .joined(separator: "\n---\n")
                            self.finishOperation(operationID)
                            self.backupProgress = "Backup failed"
                            let failure = Self.backupFailure(
                                primary: "Incremental backup failed via both backends.",
                                stderr: combinedStderr,
                                udid: udid,
                                recoveryPath: Self.backupPath(for: udid, in: backupRoot)
                            )
                            self.lastBackupFailure = failure
                            self.lastError = Self.composeFailureMessage(
                                primary: "Incremental backup failed via both backends.",
                                stderr: combinedStderr
                            )
                        }
                        continuation.resume(returning: false)
                    }
                }
            )
        }
    }

    // MARK: - Restore

    /// Restore a backup to a device. pymobiledevice3 primary, idevicebackup2 fallback.
    func restoreBackup(
        backup: BackupInfo,
        targetUDID: String,
        onProgress: @escaping (String) -> Void
    ) async -> Bool {
        // Both backends open `backupRoot/<source>`, so the source has to be the
        // folder name on disk. It is NOT backup.udid: that comes from Info.plist's
        // "Target Identifier", and timestamped or imported backup folders routinely
        // have a directory name that differs from it. Deriving both halves from
        // backup.path keeps `backupRoot + source == backup.path` true by construction,
        // which is what stops a restore from silently targeting another snapshot.
        let backupRoot = (backup.path as NSString).deletingLastPathComponent
        let sourceIdentifier = (backup.path as NSString).lastPathComponent
        guard !sourceIdentifier.isEmpty, !backupRoot.isEmpty else {
            lastError = "Cannot restore: \(backup.path) is not a backup folder inside a backup directory."
            return false
        }

        guard let operationID = beginCancellableOperation(udid: targetUDID) else { return false }
        // Primary: pymobiledevice3
        if PyMobileDevice.available() {
            return await withCheckedContinuation { continuation in
                activeProcess = PyMobileDevice.restore(
                    directory: backupRoot,
                    udid: targetUDID,
                    sourceUDID: sourceIdentifier,
                    timeout: Self.streamingRestoreTimeout,
                    onOutput: { output in onProgress(output) },
                    completion: { [weak self] exitCode in
                        Task { @MainActor in
                            guard let self else {
                                continuation.resume(returning: exitCode == 0)
                                return
                            }
                            if self.operationWasCancelled(operationID) {
                                self.markOperationCancelled(operationID, progress: "Restore cancelled")
                                continuation.resume(returning: false)
                                return
                            }
                            self.finishOperation(operationID)
                            continuation.resume(returning: exitCode == 0)
                        }
                    }
                )
            }
        }

        // Fallback: idevicebackup2
        return await withCheckedContinuation { continuation in
            activeProcess = Shell.runStreaming(
                "idevicebackup2",
                // Global options first, then the subcommand, then its options. The
                // --reboot matches the pymobiledevice3 path and the confirmation
                // dialog, which both tell the user the device restarts.
                arguments: ["-u", targetUDID, "-s", sourceIdentifier, "restore", "--system", "--reboot", backupRoot],
                timeout: Self.streamingRestoreTimeout,
                onOutput: { output in onProgress(output) },
                onError: { _ in },
                completion: { [weak self] exitCode in
                    Task { @MainActor in
                        guard let self else {
                            continuation.resume(returning: exitCode == 0)
                            return
                        }
                        if self.operationWasCancelled(operationID) {
                            self.markOperationCancelled(operationID, progress: "Restore cancelled")
                            continuation.resume(returning: false)
                            return
                        }
                        self.finishOperation(operationID)
                        continuation.resume(returning: exitCode == 0)
                    }
                }
            )
        }
    }

    /// Cancel an active backup/restore.
    func cancelBackup() {
        if let activeOperationID = operationCoordinator.activeOperationID {
            cancelledOperationIDs.insert(activeOperationID)
        }
        lastOperationWasCancelled = true
        lastError = nil
        lastBackupFailure = nil
        if let activeProcess {
            Shell.terminate(activeProcess)
        }
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

    /// Build the destination path for one manifest entry, relative to the folder
    /// the user chose. Returned as a relative path so the caller can resolve it
    /// through SafeExtractionPath, which is what actually enforces the boundary.
    private func extractionRelativePath(for entry: BackupManifest.FileEntry) -> String {
        var safeDomain = entry.domain
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        // A crafted/corrupt Manifest.db row could set domain to "." or ".." to walk
        // out of the destination directory. Slashes are already neutralized above, so
        // only the bare current-/parent-dir tokens remain dangerous.
        if safeDomain == "." || safeDomain == ".." || safeDomain.isEmpty {
            safeDomain = "_"
        }
        var components = [safeDomain]
        let relativeComponents = entry.relativePath
            .split(separator: "/")
            .map(String.init)
            .filter { !$0.isEmpty && $0 != "." && $0 != ".." }
        components += relativeComponents

        if relativeComponents.isEmpty || entry.relativePath.hasSuffix("/") {
            components.append(entry.fileName)
        }
        return components.joined(separator: "/")
    }

    func extractFiles(
        from backup: BackupInfo,
        entries: [BackupManifest.FileEntry],
        to destination: String
    ) throws -> Int {
        let manifest = try BackupManifest(backupPath: backup.path)
        var extracted = 0

        // Lexical sanitization alone is not enough: extractFile creates missing
        // parents with withIntermediateDirectories, which follows a symlink already
        // sitting in the chosen folder and writes straight through it. SafeExtractionPath
        // rejects symlinked components and re-checks containment against the resolved root.
        let root = URL(fileURLWithPath: destination, isDirectory: true)
        let fm = FileManager.default

        for entry in entries where entry.isFile {
            guard let destination = try? SafeExtractionPath.prepareDestination(
                root: root,
                relativePath: extractionRelativePath(for: entry),
                fileManager: fm
            ) else {
                lastError = "Refusing to extract \(entry.fileName) outside the destination folder."
                continue
            }
            do {
                try manifest.extractFile(entry, to: destination.path)
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
        await setBackupEncryption(udid: udid, enabled: true, password: password)
    }

    func disableEncryption(udid: String, password: String) async -> Bool {
        await setBackupEncryption(udid: udid, enabled: false, password: password)
    }

    /// Toggle backup encryption without leaking the password through the process
    /// argument list. idevicebackup2 reads the password from the BACKUP_PASSWORD
    /// environment variable, which - unlike an argv value - is not printed by
    /// `ps -axww`. pymobiledevice3 accepts these passwords only as positional CLI
    /// arguments, so a failed secure invocation deliberately fails closed.
    private func setBackupEncryption(udid: String, enabled: Bool, password: String) async -> Bool {
        let mode = enabled ? "on" : "off"
        let result = await Shell.runAsync(
            "idevicebackup2",
            arguments: ["-u", udid, "encryption", mode],
            extraEnvironment: ["BACKUP_PASSWORD": password]
        )
        guard result.succeeded else {
            lastError = "Could not change backup encryption without exposing the password on the command line. Ensure idevicebackup2 is installed and try again."
            return false
        }
        return true
    }

    /// Change the backup password using idevicebackup2's environment-variable
    /// interface. pymobiledevice3 only accepts both passwords in argv, so a
    /// failure here is reported rather than falling back to an unsafe command.
    func changeEncryptionPassword(udid: String, oldPassword: String, newPassword: String) async -> Bool {
        let result = await Shell.runAsync(
            "idevicebackup2",
            arguments: ["-u", udid, "changepw"],
            extraEnvironment: [
                "BACKUP_PASSWORD": oldPassword,
                "BACKUP_PASSWORD_NEW": newPassword,
            ]
        )
        guard result.succeeded else {
            lastError = "Could not change the backup password without exposing it on the command line. Ensure idevicebackup2 is installed and try again."
            return false
        }
        return true
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
