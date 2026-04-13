import Foundation

/// Device diagnostics: battery health, storage, system logs, crash reports, process list.
/// Primary: pymobiledevice3. Fallback: libimobiledevice.
@MainActor
final class DiagnosticsManager: ObservableObject {

    @Published var syslogLines: [String] = []
    @Published var isStreamingSyslog = false

    /// Active syslog process for proper termination.
    private var syslogProcess: Process?

    struct BatteryDiagnostics {
        let currentCapacity: Int
        let isCharging: Bool
        let isFullyCharged: Bool
        let externalConnected: Bool
        let designCapacity: Int?
        let currentMaxCapacity: Int?
        let cycleCount: Int?
        let temperature: Double?

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

    struct CrashReport: Identifiable {
        let id: String
        let name: String
        let path: String
        let date: Date?
        let processName: String
    }

    struct DeviceProcess: Identifiable {
        let id: Int // PID
        let name: String
        let pid: Int
        let realAppName: String?
    }

    // MARK: - Battery

    func getBatteryDiagnostics(udid: String) async -> BatteryDiagnostics? {
        // Primary: pymobiledevice3
        let pyBattery = await PyMobileDevice.batteryInfo(udid: udid)
        if !pyBattery.isEmpty {
            // pymobiledevice3 JSON booleans: Python True/False -> NSNumber 1/0 -> "1"/"0",
            // or via our bool handler -> "true"/"false"
            let isTruthy: (String?) -> Bool = { val in
                guard let v = val?.lowercased() else { return false }
                return v == "true" || v == "1" || v == "yes"
            }
            return BatteryDiagnostics(
                currentCapacity: Int(pyBattery["CurrentCapacity"] ?? "0") ?? 0,
                isCharging: isTruthy(pyBattery["IsCharging"]),
                isFullyCharged: isTruthy(pyBattery["IsFullyCharged"] ?? pyBattery["FullyCharged"]),
                externalConnected: isTruthy(pyBattery["ExternalConnected"]),
                designCapacity: pyBattery["DesignCapacity"].flatMap(Int.init),
                currentMaxCapacity: pyBattery["NominalChargeCapacity"].flatMap(Int.init) ?? pyBattery["MaxCapacity"].flatMap(Int.init),
                cycleCount: pyBattery["CycleCount"].flatMap(Int.init),
                temperature: pyBattery["Temperature"].flatMap(Double.init).map { $0 / 100.0 }
            )
        }

        // Fallback: libimobiledevice
        let result = await Shell.runAsync("ideviceinfo", arguments: ["-u", udid, "-q", "com.apple.mobile.battery"])
        guard result.succeeded else { return nil }

        let info = result.output.parseKeyValuePairs()
        return BatteryDiagnostics(
            currentCapacity: Int(info["BatteryCurrentCapacity"] ?? "0") ?? 0,
            isCharging: info["BatteryIsCharging"] == "true",
            isFullyCharged: info["BatteryIsFullyCharged"] == "true",
            externalConnected: info["ExternalConnected"] == "true",
            designCapacity: info["DesignCapacity"].flatMap(Int.init),
            currentMaxCapacity: info["NominalChargeCapacity"].flatMap(Int.init),
            cycleCount: nil,
            temperature: nil
        )
    }

    // MARK: - Storage

    func getStorageBreakdown(udid: String) async -> StorageBreakdown? {
        // Try pymobiledevice3 lockdown info first for disk info
        let info = await PyMobileDevice.deviceInfo(udid: udid)
        if let totalStr = info["TotalDiskCapacity"], let total = UInt64(totalStr) {
            let available = UInt64(info["AmountDataAvailable"] ?? "0") ?? 0
            let photos = UInt64(info["PhotoUsage"] ?? "0") ?? 0
            let apps = UInt64(info["MobileApplicationUsage"] ?? "0") ?? 0
            let media = UInt64(info["AmountDataReserved"] ?? "0") ?? 0
            let knownUsage = photos + apps + media
            let used = total > available ? total - available : 0
            let other = used > knownUsage ? used - knownUsage : 0

            return StorageBreakdown(
                totalCapacity: total, availableSpace: available,
                photoUsage: photos, appUsage: apps, mediaUsage: media, otherUsage: other
            )
        }

        // Fallback
        let result = await Shell.runAsync("ideviceinfo", arguments: ["-u", udid, "-q", "com.apple.disk_usage"])
        guard result.succeeded else { return nil }

        let diskInfo = result.output.parseKeyValuePairs()
        let total = UInt64(diskInfo["TotalDiskCapacity"] ?? "0") ?? 0
        let available = UInt64(diskInfo["AmountDataAvailable"] ?? "0") ?? 0
        let photos = UInt64(diskInfo["PhotoUsage"] ?? "0") ?? 0
        let apps = UInt64(diskInfo["MobileApplicationUsage"] ?? "0") ?? 0
        let media = UInt64(diskInfo["AmountDataReserved"] ?? "0") ?? 0
        let knownUsage = photos + apps + media
        let used = total > available ? total - available : 0
        let other = used > knownUsage ? used - knownUsage : 0

        return StorageBreakdown(
            totalCapacity: total, availableSpace: available,
            photoUsage: photos, appUsage: apps, mediaUsage: media, otherUsage: other
        )
    }

    // MARK: - System Info

    func getDetailedSystemInfo(udid: String) async -> [String: String] {
        let info = await PyMobileDevice.deviceInfo(udid: udid)
        if !info.isEmpty { return info }

        let result = await Shell.runAsync("ideviceinfo", arguments: ["-u", udid])
        guard result.succeeded else { return [:] }
        return result.output.parseKeyValuePairs()
    }

    // MARK: - Syslog Streaming

    func startSyslog(udid: String) {
        guard !isStreamingSyslog else { return }
        isStreamingSyslog = true
        syslogLines = []

        // Primary: pymobiledevice3 syslog
        syslogProcess = PyMobileDevice.startSyslog(
            udid: udid,
            onOutput: { [weak self] line in
                guard let self else { return }
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }

                if self.syslogLines.count > 5000 {
                    self.syslogLines.removeFirst(500)
                }
                self.syslogLines.append(trimmed)
            },
            completion: { [weak self] _ in
                self?.isStreamingSyslog = false
                self?.syslogProcess = nil
            }
        )

        // Fallback if pymobiledevice3 failed
        if syslogProcess == nil {
            Shell.runStreaming(
                "idevicesyslog",
                arguments: ["-u", udid],
                onOutput: { [weak self] line in
                    guard let self else { return }
                    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
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
    }

    func stopSyslog() {
        syslogProcess?.terminate()
        syslogProcess = nil
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
        if await PyMobileDevice.restart(udid: udid) { return true }
        return (await Shell.runAsync("idevicediagnostics", arguments: ["restart", "-u", udid])).succeeded
    }

    func shutdownDevice(udid: String) async -> Bool {
        if await PyMobileDevice.shutdown(udid: udid) { return true }
        return (await Shell.runAsync("idevicediagnostics", arguments: ["shutdown", "-u", udid])).succeeded
    }

    func sleepDevice(udid: String) async -> Bool {
        if await PyMobileDevice.sleep(udid: udid) { return true }
        return (await Shell.runAsync("idevicediagnostics", arguments: ["sleep", "-u", udid])).succeeded
    }

    // MARK: - Crash Reports

    func pullCrashReports(udid: String, to directory: String) async -> [CrashReport] {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: directory, withIntermediateDirectories: true)

        let success = await PyMobileDevice.pullCrashReports(to: directory, udid: udid)
        guard success else { return [] }

        // Scan downloaded crash files
        guard let files = try? fm.contentsOfDirectory(atPath: directory) else { return [] }
        return files.compactMap { file in
            let path = (directory as NSString).appendingPathComponent(file)
            let attrs = try? fm.attributesOfItem(atPath: path)
            let date = attrs?[.modificationDate] as? Date
            let processName = file.components(separatedBy: "-").first ?? file
            return CrashReport(id: file, name: file, path: path, date: date, processName: processName)
        }.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }

    // MARK: - Process List

    func getProcessList(udid: String) async -> [DeviceProcess] {
        let procs = await PyMobileDevice.processList(udid: udid)
        return procs.enumerated().map { (index, proc) in
            let pid = proc["pid"] as? Int ?? index
            let name = proc["name"] as? String ?? proc["processName"] as? String ?? "Unknown"
            let realName = proc["realAppName"] as? String ?? proc["bundleIdentifier"] as? String
            return DeviceProcess(id: pid, name: name, pid: pid, realAppName: realName)
        }
    }
}
