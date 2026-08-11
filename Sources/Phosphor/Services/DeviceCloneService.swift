import Foundation

/// Device-to-device transfer (clone).
/// Primary: pymobiledevice3. Fallback: libimobiledevice.
@MainActor
final class DeviceCloneService: ObservableObject {

    enum ClonePhase: String {
        case idle = "Ready"
        case backingUp = "Creating backup of source device..."
        case preparing = "Preparing restore..."
        case restoring = "Restoring to destination device..."
        case complete = "Clone complete"
        case cancelled = "Clone cancelled"
        case failed = "Clone failed"
    }

    @Published var phase: ClonePhase = .idle
    @Published var progress: String = ""
    @Published var overallProgress: Double = 0
    @Published var isRunning = false
    @Published var lastError: String?

    private struct BackupFingerprint: Equatable {
        let lastBackupDate: Date?
        let directoryModifiedAt: Date?
        let statusModifiedAt: Date?
        let manifestModifiedAt: Date?
    }

    private let backupManager = BackupManager()
    private var cancellationGate = CloneCancellationGate()

    /// Get all currently connected devices.
    func getConnectedDevices() async -> [(udid: String, name: String)] {
        // Primary: pymobiledevice3
        let pyUdids = await PyMobileDevice.listDevices()
        if !pyUdids.isEmpty {
            var devices: [(udid: String, name: String)] = []
            for udid in pyUdids {
                let name = await PyMobileDevice.deviceName(udid: udid) ?? "Device \(udid.prefix(8))"
                devices.append((udid: udid, name: name))
            }
            return devices
        }

        // Fallback: libimobiledevice
        let result = await Shell.runAsync("idevice_id", arguments: ["-l"])
        guard result.succeeded else { return [] }

        let udids = result.output.components(separatedBy: "\n").filter { !$0.isEmpty }
        var devices: [(udid: String, name: String)] = []

        for udid in udids {
            let nameResult = await Shell.runAsync("idevicename", arguments: ["-u", udid])
            let name = nameResult.succeeded ? nameResult.output : "Device \(udid.prefix(8))"
            devices.append((udid: udid, name: name))
        }

        return devices
    }

    /// Clone source device to destination device.
    func clone(
        sourceUDID: String,
        destinationUDID: String,
        backupViewModel: BackupViewModel,
        encrypted: Bool = false
    ) async -> Bool {
        cancellationGate.reset()
        defer { cancellationGate.reset() }

        guard sourceUDID != destinationUDID else {
            lastError = "Source and destination must be different devices"
            phase = .failed
            return false
        }

        isRunning = true
        lastError = nil

        // Phase 1: Backup source
        phase = .backingUp
        overallProgress = 0.05
        progress = "Starting backup of source device..."

        backupManager.discoverBackups()
        let previousFingerprints = Dictionary(uniqueKeysWithValues:
            backupManager.backups
                .filter { $0.udid == sourceUDID }
                .map { ($0.path, backupFingerprint(for: $0)) }
        )

        await backupViewModel.createBackup(udid: sourceUDID, encrypted: encrypted)
        let sourceActivity = backupViewModel.activity(for: sourceUDID)
        let backupSuccess = sourceActivity?.state == .completed

        guard backupSuccess else {
            lastError = sourceActivity?.errorMessage ?? "Backup of source device failed"
            phase = .failed
            isRunning = false
            return false
        }

        // BackupViewModel may finish its source subprocess before this clone
        // continuation resumes. A clone-local request remains authoritative here:
        // never begin the destructive destination restore after cancellation.
        guard !cancellationGate.isCancellationRequested else {
            lastError = nil
            phase = .cancelled
            isRunning = false
            return false
        }

        overallProgress = 0.5
        progress = "Backup complete. Preparing restore..."

        // Find backup
        backupManager.discoverBackups()
        let sourceBackups = backupManager.backups.filter { $0.udid == sourceUDID }
        let freshSourceBackups = sourceBackups.filter {
            previousFingerprints[$0.path] != backupFingerprint(for: $0)
        }
        guard let latestBackup = freshSourceBackups.max(by: {
            backupFreshnessDate(for: $0) < backupFreshnessDate(for: $1)
        }) else {
            lastError = "Could not find the backup that was just created"
            phase = .failed
            isRunning = false
            return false
        }

        // Phase 2: Restore to destination
        phase = .restoring
        progress = "Restoring to destination device..."

        let restoreSuccess = await backupManager.restoreBackup(
            backup: latestBackup,
            targetUDID: destinationUDID
        ) { [weak self] text in
            self?.progress = text
            if let pct = PyMobileDevice.parseProgress(from: text) {
                self?.overallProgress = 0.5 + pct / 2.0
            }
        }

        if restoreSuccess {
            phase = .complete
            overallProgress = 1.0
            progress = "Clone complete. Destination device will restart."
        } else {
            lastError = "Restore to destination device failed"
            phase = .failed
        }

        isRunning = false
        return restoreSuccess
    }

    /// Request cancellation of clone continuation. The source backup may already
    /// have completed when this arrives, so `clone` checks this again before restore.
    func cancelClone() {
        guard isRunning else { return }
        cancellationGate.requestCancellation()
    }

    private func backupFingerprint(for backup: BackupInfo) -> BackupFingerprint {
        let path = backup.path as NSString
        return BackupFingerprint(
            lastBackupDate: backup.lastBackupDate,
            directoryModifiedAt: modificationDate(at: backup.path),
            statusModifiedAt: modificationDate(at: path.appendingPathComponent("Status.plist")),
            manifestModifiedAt: modificationDate(at: path.appendingPathComponent("Manifest.db"))
        )
    }

    private func backupFreshnessDate(for backup: BackupInfo) -> Date {
        let fingerprint = backupFingerprint(for: backup)
        return [
            fingerprint.lastBackupDate,
            fingerprint.directoryModifiedAt,
            fingerprint.statusModifiedAt,
            fingerprint.manifestModifiedAt
        ].compactMap { $0 }.max() ?? .distantPast
    }

    private func modificationDate(at path: String) -> Date? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        return attributes?[.modificationDate] as? Date
    }

    func reset() {
        phase = .idle
        progress = ""
        overallProgress = 0
        isRunning = false
        lastError = nil
    }
}
