import Foundation

/// Device-to-device transfer (clone).
/// Creates a full backup of the source device, then restores it to the destination device.
/// Both devices must be connected via USB simultaneously.
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
    @Published var overallProgress: Double = 0 // 0.0 - 1.0
    @Published var isRunning = false
    @Published var lastError: String?

    private let backupManager = BackupManager()

    /// Get all currently connected devices.
    func getConnectedDevices() async -> [(udid: String, name: String)] {
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
    /// Phase 1: Full backup of source
    /// Phase 2: Restore backup to destination
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

        // Phase 1: Backup source device
        phase = .backingUp
        overallProgress = 0.05
        progress = "Starting backup of source device..."

        let backupSuccess = await backupManager.createBackup(udid: sourceUDID, encrypted: encrypted) { [weak self] text in
            self?.progress = text
            // Estimate backup progress as 0-50%
            if text.contains("%") {
                if let pct = self?.extractPercentage(from: text) {
                    self?.overallProgress = Double(pct) / 200.0 // 0-50%
                }
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

        // Find the backup we just created
        backupManager.discoverBackups()
        guard let latestBackup = backupManager.backups.first(where: { $0.udid == sourceUDID }) else {
            lastError = "Could not find the backup that was just created"
            phase = .failed
            isRunning = false
            return false
        }

        // Phase 2: Restore to destination device
        phase = .restoring
        progress = "Restoring to destination device..."

        let restoreSuccess = await backupManager.restoreBackup(
            backupPath: latestBackup.path,
            udid: destinationUDID
        ) { [weak self] text in
            self?.progress = text
            if text.contains("%") {
                if let pct = self?.extractPercentage(from: text) {
                    self?.overallProgress = 0.5 + Double(pct) / 200.0 // 50-100%
                }
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

    private func extractPercentage(from text: String) -> Int? {
        // Match patterns like "42%" or "Progress: 42%"
        let pattern = #"(\d+)%"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return Int(text[range])
    }
}
