import Foundation

/// Device diagnostics: battery health, storage breakdown, system logs, crash reports.
@MainActor
final class DiagnosticsManager: ObservableObject {

    @Published var syslogLines: [String] = []
    @Published var isStreamingSyslog = false

    struct BatteryDiagnostics {
        let currentCapacity: Int
        let isCharging: Bool
        let isFullyCharged: Bool
        let externalConnected: Bool
        let designCapacity: Int?  // mAh design
        let currentMaxCapacity: Int? // mAh actual max (health)

        var healthPercent: Double? {
            guard let design = designCapacity, let current = currentMaxCapacity, design > 0 else { return nil }
            return Double(current) / Double(design) * 100
        }
    }

    struct StorageBreakdown {
        let totalCapacity: UInt64
        let availableSpace: UInt64
        let photoUsage: UInt64
        let appUsage: UInt64
        let mediaUsage: UInt64
        let otherUsage: UInt64

        var usedSpace: UInt64 { totalCapacity - availableSpace }
        var usedPercent: Double {
            guard totalCapacity > 0 else { return 0 }
            return Double(usedSpace) / Double(totalCapacity) * 100
        }
    }

    // MARK: - Battery

    func getBatteryDiagnostics(udid: String) async -> BatteryDiagnostics? {
        let result = await Shell.runAsync("ideviceinfo", arguments: ["-u", udid, "-q", "com.apple.mobile.battery"])
        guard result.succeeded else { return nil }

        let info = result.output.parseKeyValuePairs()

        return BatteryDiagnostics(
            currentCapacity: Int(info["BatteryCurrentCapacity"] ?? "0") ?? 0,
            isCharging: info["BatteryIsCharging"] == "true",
            isFullyCharged: info["BatteryIsFullyCharged"] == "true" || info["ExternalChargeCapable"] == "true",
            externalConnected: info["ExternalConnected"] == "true",
            designCapacity: info["DesignCapacity"].flatMap(Int.init),
            currentMaxCapacity: info["NominalChargeCapacity"].flatMap(Int.init)
        )
    }

    // MARK: - Storage

    func getStorageBreakdown(udid: String) async -> StorageBreakdown? {
        let result = await Shell.runAsync("ideviceinfo", arguments: ["-u", udid, "-q", "com.apple.disk_usage"])
        guard result.succeeded else { return nil }

        let info = result.output.parseKeyValuePairs()

        let total = UInt64(info["TotalDiskCapacity"] ?? "0") ?? 0
        let available = UInt64(info["AmountDataAvailable"] ?? "0") ?? 0
        let photos = UInt64(info["PhotoUsage"] ?? "0") ?? 0
        let apps = UInt64(info["MobileApplicationUsage"] ?? "0") ?? 0
        let media = UInt64(info["AmountDataReserved"] ?? "0") ?? 0

        let knownUsage = photos + apps + media
        let used = total > available ? total - available : 0
        let other = used > knownUsage ? used - knownUsage : 0

        return StorageBreakdown(
            totalCapacity: total,
            availableSpace: available,
            photoUsage: photos,
            appUsage: apps,
            mediaUsage: media,
            otherUsage: other
        )
    }

    // MARK: - System Info

    func getDetailedSystemInfo(udid: String) async -> [String: String] {
        let result = await Shell.runAsync("ideviceinfo", arguments: ["-u", udid])
        guard result.succeeded else { return [:] }
        return result.output.parseKeyValuePairs()
    }

    // MARK: - Syslog Streaming

    func startSyslog(udid: String) {
        guard !isStreamingSyslog else { return }
        isStreamingSyslog = true
        syslogLines = []

        Shell.runStreaming(
            "idevicesyslog",
            arguments: ["-u", udid],
            onOutput: { [weak self] line in
                guard let self else { return }
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }

                // Keep last 5000 lines to prevent memory bloat
                if self.syslogLines.count > 5000 {
                    self.syslogLines.removeFirst(500)
                }
                self.syslogLines.append(trimmed)
            },
            completion: { [weak self] _ in
                self?.isStreamingSyslog = false
            }
        )
    }

    func stopSyslog() {
        // idevicesyslog runs until killed; we rely on the process being released
        isStreamingSyslog = false
    }

    func clearSyslog() {
        syslogLines = []
    }

    func exportSyslog(to path: String) throws {
        let content = syslogLines.joined(separator: "\n")
        try content.write(toFile: path, atomically: true, encoding: .utf8)
    }

    // MARK: - Device Actions

    func restartDevice(udid: String) async -> Bool {
        let result = await Shell.runAsync("idevicediagnostics", arguments: ["restart", "-u", udid])
        return result.succeeded
    }

    func shutdownDevice(udid: String) async -> Bool {
        let result = await Shell.runAsync("idevicediagnostics", arguments: ["shutdown", "-u", udid])
        return result.succeeded
    }

    func sleepDevice(udid: String) async -> Bool {
        let result = await Shell.runAsync("idevicediagnostics", arguments: ["sleep", "-u", udid])
        return result.succeeded
    }
}
