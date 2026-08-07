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
        var targetName: String?
        var lastRunDate: Date?
        var nextRunDate: Date?
        var lastResult: String?
        var incrementalOnly: Bool = true
    }

    @Published var schedule: Schedule {
        didSet { synchronizeEditedSchedule(previous: oldValue) }
    }
    @Published private(set) var schedules: [Schedule]
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
    private var scheduleChangeCancellable: AnyCancellable?
    private var isMonitoring = false
    private var isSynchronizingSchedule = false
    private var runningScheduledUDIDs: Set<String> = []
    private weak var backupViewModel: BackupViewModel?
    private let defaults = UserDefaults.standard
    private let scheduleKey = "phosphor.backup.schedule"
    private let schedulesKey = "phosphor.backup.schedules"
    private let logsKey = "phosphor.backup.schedule.logs"
    private static let scheduleDidChangeNotification = Notification.Name("phosphor.backup.schedule.did-change")

    init() {
        if let data = defaults.data(forKey: schedulesKey),
           let saved = try? JSONDecoder().decode([Schedule].self, from: data) {
            self.schedules = saved
            self.schedule = saved.first ?? Schedule()
        } else if let data = defaults.data(forKey: scheduleKey),
                  let saved = try? JSONDecoder().decode(Schedule.self, from: data) {
            self.schedules = [saved]
            self.schedule = saved
        } else {
            self.schedules = []
            self.schedule = Schedule()
        }
        loadLogs()
        scheduleChangeCancellable = NotificationCenter.default.publisher(
            for: Self.scheduleDidChangeNotification
        ).sink { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.reloadFromDefaults()
                self.configureMonitoring()
            }
        }
        saveSchedules()
    }

    func attachBackupViewModel(_ backupViewModel: BackupViewModel) {
        self.backupViewModel = backupViewModel
    }

    func selectSchedule(targetUDID: String?, targetName: String?) {
        isSynchronizingSchedule = true
        schedules = latestPersistedSchedules()
        if let existing = schedules.first(where: { $0.targetUDID == targetUDID }) {
            schedule = existing
        } else if let targetUDID,
                  let legacyIndex = schedules.firstIndex(where: { $0.targetUDID == nil }) {
            var migrated = schedules[legacyIndex]
            migrated.targetUDID = targetUDID
            migrated.targetName = targetName
            schedules[legacyIndex] = migrated
            schedule = migrated
            saveSchedules()
        } else {
            schedule = Schedule(targetUDID: targetUDID, targetName: targetName)
            if targetUDID != nil {
                schedules.append(schedule)
                saveSchedules()
            }
        }
        isSynchronizingSchedule = false
    }

    // MARK: - Timer Control

    func startMonitoring() {
        stopMonitoring()
        isMonitoring = true
        reloadFromDefaults()
        configureMonitoring()
        if schedules.contains(where: \.enabled) {
            Task { await checkAndRun() }
            updateNextRunDate()
        }
    }

    private func configureMonitoring() {
        timer?.invalidate()
        timer = nil
        guard isMonitoring else { return }
        guard schedules.contains(where: \.enabled) else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.checkAndRun()
            }
        }
    }

    func stopMonitoring() {
        isMonitoring = false
        timer?.invalidate()
        timer = nil
    }

    func reloadFromDefaults() {
        let savedSchedules: [Schedule]
        if let data = defaults.data(forKey: schedulesKey),
           let saved = try? JSONDecoder().decode([Schedule].self, from: data) {
            savedSchedules = saved
        } else if let data = defaults.data(forKey: scheduleKey),
                  let legacy = try? JSONDecoder().decode(Schedule.self, from: data) {
            savedSchedules = [legacy]
        } else {
            return
        }

        if savedSchedules != schedules {
            schedules = savedSchedules
            let selectedTarget = schedule.targetUDID
            if let refreshed = savedSchedules.first(where: { $0.targetUDID == selectedTarget }) ?? savedSchedules.first {
                isSynchronizingSchedule = true
                schedule = refreshed
                isSynchronizingSchedule = false
            }
        }
    }

    func checkAndRun() async {
        reloadFromDefaults()
        var dueSchedules: [Schedule] = []
        for stored in schedules where stored.enabled {
            var candidate = stored
            if candidate.nextRunDate == nil {
                candidate.nextRunDate = nextRunDate(for: candidate)
                storeSchedule(candidate, replacingTargetUDID: stored.targetUDID)
            }
            if let nextRun = candidate.nextRunDate,
               Date() >= nextRun,
               !runningScheduledUDIDs.contains(candidate.targetUDID ?? "legacy") {
                dueSchedules.append(candidate)
            }
        }

        await withTaskGroup(of: Void.self) { group in
            for dueSchedule in dueSchedules {
                group.addTask { @MainActor [weak self] in
                    await self?.run(schedule: dueSchedule, advanceAfterDiscoveryFailure: true)
                }
            }
        }
    }

    func runNow() async {
        await run(schedule: schedule, advanceAfterDiscoveryFailure: false)
    }

    private func run(schedule runSchedule: Schedule, advanceAfterDiscoveryFailure: Bool) async {
        let scheduleIdentity = runSchedule.targetUDID ?? "legacy"
        guard !runningScheduledUDIDs.contains(scheduleIdentity) else { return }
        runningScheduledUDIDs.insert(scheduleIdentity)
        isRunningScheduledBackup = true

        let discovery = await findTargetDevice(for: runSchedule)
        guard let target = discovery.target else {
            let failure = discovery.failure ?? "No device available for backup"
            var updated = latestSchedule(matching: runSchedule.targetUDID) ?? runSchedule
            updated.lastResult = failure
            if advanceAfterDiscoveryFailure {
                updated.lastRunDate = Date()
                updated.nextRunDate = nextRunDate(for: updated)
            }
            storeSchedule(updated, replacingTargetUDID: runSchedule.targetUDID)
            addLog(failure, success: false)
            runningScheduledUDIDs.remove(scheduleIdentity)
            isRunningScheduledBackup = !runningScheduledUDIDs.isEmpty
            return
        }
        await runScheduledBackup(schedule: runSchedule, udid: target.udid, preferNetwork: target.preferNetwork)
        runningScheduledUDIDs.remove(scheduleIdentity)
        isRunningScheduledBackup = !runningScheduledUDIDs.isEmpty
    }

    // MARK: - Backup Execution

    private func runScheduledBackup(schedule runSchedule: Schedule, udid: String, preferNetwork: Bool) async {
        scheduledBackupProgress = "Starting scheduled backup..."
        addLog("Scheduled backup started for \(runSchedule.targetName ?? "device \(udid.prefix(8))...")", success: true)

        let incremental = runSchedule.incrementalOnly && BackupManager.hasExistingBackup(for: udid)
        if runSchedule.incrementalOnly && !incremental {
            addLog("No complete backup exists yet; running required first full backup", success: true)
        }

        guard let backupViewModel else {
            let failure = "The shared backup queue is unavailable"
            var updated = latestSchedule(matching: runSchedule.targetUDID) ?? runSchedule
            updated.lastRunDate = Date()
            updated.lastResult = failure
            updated.nextRunDate = nextRunDate(for: updated)
            storeSchedule(updated, replacingTargetUDID: runSchedule.targetUDID)
            addLog(failure, success: false)
            return
        }

        await backupViewModel.createBackup(udid: udid, incremental: incremental, preferNetwork: preferNetwork)
        let activity = backupViewModel.activity(for: udid)
        let success = activity?.state == .completed
        let resultMessage = activity?.errorMessage ?? activity?.progressText ?? "Failed"

        var updated = latestSchedule(matching: runSchedule.targetUDID) ?? runSchedule
        updated.lastRunDate = Date()
        updated.lastResult = success ? "Completed" : resultMessage
        updated.nextRunDate = nextRunDate(for: updated)
        storeSchedule(updated, replacingTargetUDID: runSchedule.targetUDID)
        addLog(
            success ? "Backup completed" : "Backup failed: \(resultMessage)",
            success: success
        )
    }

    // MARK: - Device Discovery

    private struct TargetDevice {
        let udid: String
        let preferNetwork: Bool
    }

    private func findTargetDevice(for runSchedule: Schedule) async -> (target: TargetDevice?, failure: String?) {
        let pyEntries = await PyMobileDevice.listDevicesWithType()
        let eligiblePyEntries = runSchedule.wifiOnly
            ? pyEntries.filter { $0.connectionType != "USB" }
            : pyEntries

        // Check specific target first.
        if let target = runSchedule.targetUDID {
            if let entry = eligiblePyEntries.first(where: { $0.udid == target }) {
                return (TargetDevice(udid: target, preferNetwork: entry.connectionType != "USB"), nil)
            }

            if runSchedule.wifiOnly {
                let networkDevices = await PyMobileDevice.listNetworkDevices()
                if networkDevices.contains(target) { return (TargetDevice(udid: target, preferNetwork: true), nil) }
            }

            // Fallback: libimobiledevice. Use the network-only query when the schedule
            // explicitly requests Wi-Fi backups so USB devices do not accidentally match.
            let fallbackArgs = runSchedule.wifiOnly ? ["-n"] : ["-l"]
            let result = await Shell.runAsync("idevice_id", arguments: fallbackArgs)
            if result.succeeded {
                let devices = result.output.components(separatedBy: "\n").filter { !$0.isEmpty }
                if devices.contains(target) { return (TargetDevice(udid: target, preferNetwork: runSchedule.wifiOnly), nil) }
            }
            let failure = runSchedule.wifiOnly
                ? "The scheduled device is not available over Wi-Fi"
                : "The scheduled device is not connected"
            return (nil, failure)
        }

        // Legacy schedules may not have a target yet. Preserve the convenient
        // single-device behavior, but collect every applicable backend first so
        // a partial primary result cannot hide a second phone or tablet that is
        // visible only through a fallback.
        var discoveredCandidates = eligiblePyEntries.map {
            ScheduledBackupTargetResolver.Candidate(
                udid: $0.udid,
                preferNetwork: $0.connectionType != "USB"
            )
        }

        if runSchedule.wifiOnly {
            let networkDevices = await PyMobileDevice.listNetworkDevices()
            discoveredCandidates.append(contentsOf: networkDevices.map {
                ScheduledBackupTargetResolver.Candidate(udid: $0, preferNetwork: true)
            })
        }

        // Fallback: libimobiledevice.
        let fallbackArgs = runSchedule.wifiOnly ? ["-n"] : ["-l"]
        let result = await Shell.runAsync("idevice_id", arguments: fallbackArgs)
        if result.succeeded {
            let devices = result.output.components(separatedBy: "\n").filter { !$0.isEmpty }
            discoveredCandidates.append(contentsOf: devices.map {
                ScheduledBackupTargetResolver.Candidate(udid: $0, preferNetwork: runSchedule.wifiOnly)
            })
        }

        switch resolveTarget(from: discoveredCandidates, targetUDID: runSchedule.targetUDID) {
        case .target(let target):
            return (TargetDevice(udid: target.udid, preferNetwork: target.preferNetwork), nil)
        case .selectionRequired:
            let failure = runSchedule.wifiOnly
                ? "Multiple Wi-Fi devices are available. Choose a device in Backup Schedule."
                : "Multiple devices are available. Choose a device in Backup Schedule."
            return (nil, failure)
        case .noneAvailable:
            break
        }

        let failure = runSchedule.wifiOnly
            ? "The scheduled device is not available over Wi-Fi"
            : "The scheduled device is not connected"
        return (nil, failure)
    }

    private func resolveTarget(
        from candidates: [ScheduledBackupTargetResolver.Candidate],
        targetUDID: String?
    ) -> ScheduledBackupTargetResolver.Resolution {
        ScheduledBackupTargetResolver.resolve(
            candidates: candidates,
            targetUDID: targetUDID
        )
    }

    // MARK: - Scheduling Math

    func updateNextRunDate() {
        var updated = schedule
        updated.nextRunDate = nextRunDate(for: updated)
        schedule = updated
    }

    private func nextRunDate(for schedule: Schedule) -> Date? {
        guard schedule.enabled else { return nil }

        let calendar = Calendar.current
        let now = Date()
        let anchor = schedule.lastRunDate ?? now

        func scheduledTime(on date: Date) -> Date {
            var components = calendar.dateComponents([.year, .month, .day, .hour], from: date)
            components.hour = schedule.preferredHour
            components.minute = schedule.preferredMinute
            components.second = 0
            return calendar.date(from: components) ?? date
        }

        func advance(_ date: Date) -> Date {
            switch schedule.frequency {
            case .hourly:
                var components = calendar.dateComponents([.year, .month, .day, .hour], from: date)
                components.minute = schedule.preferredMinute
                components.second = 0
                let aligned = calendar.date(from: components) ?? date
                return calendar.date(byAdding: .hour, value: aligned <= date ? 1 : 0, to: aligned) ?? date.addingTimeInterval(schedule.frequency.interval)
            case .daily:
                return calendar.date(byAdding: .day, value: 1, to: date) ?? date.addingTimeInterval(schedule.frequency.interval)
            case .weekly:
                return calendar.date(byAdding: .day, value: 7, to: date) ?? date.addingTimeInterval(schedule.frequency.interval)
            case .biweekly:
                return calendar.date(byAdding: .day, value: 14, to: date) ?? date.addingTimeInterval(schedule.frequency.interval)
            case .monthly:
                return calendar.date(byAdding: .month, value: 1, to: date) ?? date.addingTimeInterval(schedule.frequency.interval)
            }
        }

        var next: Date
        if schedule.frequency == .hourly {
            next = advance(anchor)
        } else if schedule.lastRunDate != nil {
            next = scheduledTime(on: advance(anchor))
        } else {
            next = scheduledTime(on: now)
        }

        while next <= now {
            next = schedule.frequency == .hourly ? advance(next) : scheduledTime(on: advance(next))
        }

        return next
    }

    // MARK: - Persistence

    private func synchronizeEditedSchedule(previous: Schedule) {
        guard !isSynchronizingSchedule else { return }
        let latest = latestSchedule(matching: previous.targetUDID) ?? previous
        let merged = mergeEditedFields(previous: previous, edited: schedule, into: latest)
        storeSchedule(merged, replacingTargetUDID: previous.targetUDID)
    }

    /// Apply only fields changed by this editor onto the latest persisted value.
    /// This prevents a stale Settings window from reverting another window's edit.
    private func mergeEditedFields(previous: Schedule, edited: Schedule, into latest: Schedule) -> Schedule {
        var merged = latest
        if edited.enabled != previous.enabled { merged.enabled = edited.enabled }
        if edited.frequency != previous.frequency { merged.frequency = edited.frequency }
        if edited.wifiOnly != previous.wifiOnly { merged.wifiOnly = edited.wifiOnly }
        if edited.preferredHour != previous.preferredHour { merged.preferredHour = edited.preferredHour }
        if edited.preferredMinute != previous.preferredMinute { merged.preferredMinute = edited.preferredMinute }
        if edited.targetUDID != previous.targetUDID { merged.targetUDID = edited.targetUDID }
        if edited.targetName != previous.targetName { merged.targetName = edited.targetName }
        if edited.lastRunDate != previous.lastRunDate { merged.lastRunDate = edited.lastRunDate }
        if edited.nextRunDate != previous.nextRunDate { merged.nextRunDate = edited.nextRunDate }
        if edited.lastResult != previous.lastResult { merged.lastResult = edited.lastResult }
        if edited.incrementalOnly != previous.incrementalOnly { merged.incrementalOnly = edited.incrementalOnly }
        return merged
    }

    private func storeSchedule(_ updated: Schedule, replacingTargetUDID oldTargetUDID: String?) {
        var mergedSchedules = latestPersistedSchedules()
        if let index = mergedSchedules.firstIndex(where: { $0.targetUDID == oldTargetUDID }) ??
            mergedSchedules.firstIndex(where: { $0.targetUDID == updated.targetUDID }) {
            mergedSchedules[index] = updated
        } else {
            mergedSchedules.append(updated)
        }
        schedules = mergedSchedules

        if schedule.targetUDID == oldTargetUDID || schedule.targetUDID == updated.targetUDID {
            isSynchronizingSchedule = true
            schedule = updated
            isSynchronizingSchedule = false
        }
        saveSchedules()
    }

    private func latestPersistedSchedules() -> [Schedule] {
        guard let data = defaults.data(forKey: schedulesKey),
              let persisted = try? JSONDecoder().decode([Schedule].self, from: data) else {
            return schedules
        }
        return persisted
    }

    private func latestSchedule(matching targetUDID: String?) -> Schedule? {
        latestPersistedSchedules().first(where: { $0.targetUDID == targetUDID })
    }

    private func saveSchedules() {
        if let data = try? JSONEncoder().encode(schedules) {
            defaults.set(data, forKey: schedulesKey)
        }
        // Keep the previous key current for downgrade compatibility.
        if let data = try? JSONEncoder().encode(schedule) {
            defaults.set(data, forKey: scheduleKey)
        }
        NotificationCenter.default.post(name: Self.scheduleDidChangeNotification, object: nil)
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
