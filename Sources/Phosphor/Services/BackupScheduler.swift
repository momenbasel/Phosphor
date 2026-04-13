import Foundation
import Combine

/// Automated backup scheduler with Wi-Fi device detection.
/// Primary: pymobiledevice3. Fallback: libimobiledevice.
@MainActor
final class BackupScheduler: ObservableObject {

    enum Frequency: String, CaseIterable, Codable {
        case hourly = "Every Hour"
        case daily = "Daily"
        case weekly = "Weekly"
        case biweekly = "Every 2 Weeks"
        case monthly = "Monthly"

        var interval: TimeInterval {
            switch self {
            case .hourly:   return 3600
            case .daily:    return 86400
            case .weekly:   return 604800
            case .biweekly: return 1209600
            case .monthly:  return 2592000
            }
        }
    }

    struct Schedule: Codable, Equatable {
        var enabled: Bool = false
        var frequency: Frequency = .daily
        var wifiOnly: Bool = true
        var preferredHour: Int = 2
        var preferredMinute: Int = 0
        var targetUDID: String?
        var lastRunDate: Date?
        var nextRunDate: Date?
        var lastResult: String?
        var incrementalOnly: Bool = true
    }

    @Published var schedule: Schedule {
        didSet { saveSchedule() }
    }
    @Published var isRunningScheduledBackup = false
    @Published var scheduledBackupProgress = ""
    @Published var recentLogs: [LogEntry] = []

    struct LogEntry: Identifiable {
        let id = UUID()
        let date: Date
        let message: String
        let success: Bool
    }

    private var timer: Timer?
    private let defaults = UserDefaults.standard
    private let scheduleKey = "phosphor.backup.schedule"
    private let logsKey = "phosphor.backup.schedule.logs"

    init() {
        if let data = defaults.data(forKey: scheduleKey),
           let saved = try? JSONDecoder().decode(Schedule.self, from: data) {
            self.schedule = saved
        } else {
            self.schedule = Schedule()
        }
        loadLogs()
    }

    // MARK: - Timer Control

    func startMonitoring() {
        stopMonitoring()
        guard schedule.enabled else { return }

        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.checkAndRun()
            }
        }
        Task { await checkAndRun() }
        updateNextRunDate()
    }

    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
    }

    func reloadFromDefaults() {
        if let data = defaults.data(forKey: scheduleKey),
           let saved = try? JSONDecoder().decode(Schedule.self, from: data) {
            if saved != schedule { schedule = saved }
        }
    }

    func checkAndRun() async {
        reloadFromDefaults()
        guard schedule.enabled, !isRunningScheduledBackup else { return }
        guard let nextRun = schedule.nextRunDate, Date() >= nextRun else { return }

        isRunningScheduledBackup = true

        let udid = await findTargetDevice()
        guard let udid else {
            addLog("No device found for scheduled backup", success: false)
            isRunningScheduledBackup = false
            return
        }

        await runScheduledBackup(udid: udid)
    }

    func runNow() async {
        guard !isRunningScheduledBackup else { return }
        let udid = await findTargetDevice()
        guard let udid else {
            addLog("No device available for backup", success: false)
            return
        }
        await runScheduledBackup(udid: udid)
    }

    // MARK: - Backup Execution

    private func runScheduledBackup(udid: String) async {
        isRunningScheduledBackup = true
        scheduledBackupProgress = "Starting scheduled backup..."
        addLog("Scheduled backup started for device \(udid.prefix(8))...", success: true)

        let manager = BackupManager()
        let success: Bool

        if schedule.incrementalOnly {
            success = await manager.createIncrementalBackup(udid: udid) { [weak self] text in
                self?.scheduledBackupProgress = text
            }
        } else {
            success = await manager.createBackup(udid: udid) { [weak self] text in
                self?.scheduledBackupProgress = text
            }
        }

        isRunningScheduledBackup = false
        schedule.lastRunDate = Date()
        schedule.lastResult = success ? "Completed" : (manager.lastError ?? "Failed")
        updateNextRunDate()
        addLog(
            success ? "Backup completed" : "Backup failed: \(manager.lastError ?? "unknown error")",
            success: success
        )
    }

    // MARK: - Device Discovery

    private func findTargetDevice() async -> String? {
        // Check specific target first
        if let target = schedule.targetUDID {
            // pymobiledevice3 device listing
            let allDevices = await PyMobileDevice.listDevices()
            if allDevices.contains(target) { return target }

            // WiFi check
            if schedule.wifiOnly {
                let networkDevices = await PyMobileDevice.listNetworkDevices()
                if networkDevices.contains(target) { return target }
            }

            // Fallback: libimobiledevice
            let usbResult = await Shell.runAsync("idevice_id", arguments: ["-l"])
            if usbResult.succeeded {
                let devices = usbResult.output.components(separatedBy: "\n").filter { !$0.isEmpty }
                if devices.contains(target) { return target }
            }
            return nil
        }

        // No specific target - find any device
        // pymobiledevice3 USB
        let pyDevices = await PyMobileDevice.listDevices()
        if let first = pyDevices.first { return first }

        // Fallback USB
        let usbResult = await Shell.runAsync("idevice_id", arguments: ["-l"])
        if usbResult.succeeded {
            let devices = usbResult.output.components(separatedBy: "\n").filter { !$0.isEmpty }
            if let first = devices.first { return first }
        }

        // WiFi
        if schedule.wifiOnly {
            let networkDevices = await PyMobileDevice.listNetworkDevices()
            if let first = networkDevices.first { return first }

            let wifiResult = await Shell.runAsync("idevice_id", arguments: ["-n"])
            if wifiResult.succeeded {
                let devices = wifiResult.output.components(separatedBy: "\n").filter { !$0.isEmpty }
                if let first = devices.first { return first }
            }
        }

        return nil
    }

    // MARK: - Scheduling Math

    func updateNextRunDate() {
        guard schedule.enabled else {
            schedule.nextRunDate = nil
            return
        }

        let calendar = Calendar.current
        var next: Date

        if let lastRun = schedule.lastRunDate {
            next = lastRun.addingTimeInterval(schedule.frequency.interval)
        } else {
            var components = calendar.dateComponents([.year, .month, .day], from: Date())
            components.hour = schedule.preferredHour
            components.minute = schedule.preferredMinute
            next = calendar.date(from: components) ?? Date()
            if next <= Date() {
                next = calendar.date(byAdding: .day, value: 1, to: next) ?? next
            }
        }

        schedule.nextRunDate = next
    }

    // MARK: - Persistence

    private func saveSchedule() {
        if let data = try? JSONEncoder().encode(schedule) {
            defaults.set(data, forKey: scheduleKey)
        }
    }

    private func addLog(_ message: String, success: Bool) {
        let entry = LogEntry(date: Date(), message: message, success: success)
        recentLogs.insert(entry, at: 0)
        if recentLogs.count > 50 { recentLogs = Array(recentLogs.prefix(50)) }
        saveLogs()
    }

    private func saveLogs() {
        let simplified = recentLogs.map { ["date": $0.date.iso8601String, "msg": $0.message, "ok": $0.success ? "1" : "0"] }
        defaults.set(simplified, forKey: logsKey)
    }

    private func loadLogs() {
        guard let array = defaults.array(forKey: logsKey) as? [[String: String]] else { return }
        let formatter = ISO8601DateFormatter()
        recentLogs = array.compactMap { dict in
            guard let dateStr = dict["date"], let msg = dict["msg"], let ok = dict["ok"],
                  let date = formatter.date(from: dateStr) else { return nil }
            return LogEntry(date: date, message: msg, success: ok == "1")
        }
    }

    func clearLogs() {
        recentLogs = []
        defaults.removeObject(forKey: logsKey)
    }
}
