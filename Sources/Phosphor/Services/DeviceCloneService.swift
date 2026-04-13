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
        case failed = "Clone failed"
    }

    @Published var phase: ClonePhase = .idle
    @Published var progress: String = ""
    @Published var overallProgress: Double = 0
    @Published var isRunning = false
    @Published var lastError: String?

    private let backupManager = BackupManager()

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
        encrypted: Bool = false
    ) async -> Bool {
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

        let backupSuccess = await backupManager.createBackup(udid: sourceUDID, encrypted: encrypted) { [weak self] text in
            self?.progress = text
            if let pct = PyMobileDevice.parseProgress(from: text) {
                self?.overallProgress = pct / 2.0
            }
        }

        guard backupSuccess else {
            lastError = backupManager.lastError ?? "Backup of source device failed"
            phase = .failed
            isRunning = false
            return false
        }

        overallProgress = 0.5
        progress = "Backup complete. Preparing restore..."

        // Find backup
        backupManager.discoverBackups()
        guard let latestBackup = backupManager.backups.first(where: { $0.udid == sourceUDID }) else {
            lastError = "Could not find the backup that was just created"
            phase = .failed
            isRunning = false
            return false
        }

        // Phase 2: Restore to destination
        phase = .restoring
        progress = "Restoring to destination device..."

        let restoreSuccess = await backupManager.restoreBackup(
            backupPath: latestBackup.path,
            udid: destinationUDID
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

    func reset() {
        phase = .idle
        progress = ""
        overallProgress = 0
        isRunning = false
        lastError = nil
    }
}
