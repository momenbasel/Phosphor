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
    private var backgroundActivityScheduler: NSBackgroundActivityScheduler?
    private var scheduledCheckTask: Task<Void, Never>?
    private var scheduledRunTasks: [String: Task<Void, Never>] = [:]
    private var scheduledRunSchedules: [String: Schedule] = [:]
    private var scheduledRunIDs: [String: UUID] = [:]
    private var scheduledRunOwnership = ScheduledRunOwnership()
    private var scheduleChangeCancellable: AnyCancellable?
    private var isMonitoring = false
    private var isSynchronizingSchedule = false
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
        defer { isSynchronizingSchedule = false }
        schedules = latestPersistedSchedules()

        if targetUDID == nil {
            let previousTargetUDID = schedule.targetUDID
            schedules.removeAll { $0.targetUDID == previousTargetUDID }
            schedule = Schedule()
            saveSchedules()
            cancelInvalidScheduledWork()
            return
        }

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
            schedules.append(schedule)
            saveSchedules()
        }
        cancelInvalidScheduledWork()
    }

    // MARK: - Timer Control

    func startMonitoring() {
        stopMonitoring()
        isMonitoring = true
        reloadFromDefaults()
        configureMonitoring()
        if schedules.contains(where: \.enabled) {
            startScheduledCheck()
            updateNextRunDate()
        }
    }

    private func configureMonitoring() {
        timer?.invalidate()
        timer = nil
        backgroundActivityScheduler?.invalidate()
        backgroundActivityScheduler = nil
        scheduledCheckTask?.cancel()
        scheduledCheckTask = nil
        BackgroundExecutionController.shared.setScheduledWorkEnabled(schedules.contains(where: \.enabled))
        guard isMonitoring else {
            cancelScheduledWork()
            return
        }
        cancelInvalidScheduledWork()
        guard schedules.contains(where: \.enabled) else {
            cancelScheduledWork()
            return
        }
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.startScheduledCheck()
            }
        }

        // The foreground timer gives timely checks while the app is active. This
        // system scheduler lets macOS wake the app opportunistically and routes
        // through the same all-schedules check, preserving per-device ownership.
        let backgroundActivity = NSBackgroundActivityScheduler(
            identifier: "com.phosphor.backup-scheduler"
        )
        backgroundActivity.interval = 15 * 60
        backgroundActivity.tolerance = 5 * 60
        backgroundActivity.qualityOfService = .utility
        backgroundActivity.repeats = true
        backgroundActivity.schedule { [weak self] completion in
            Task { @MainActor [weak self] in
                await self?.checkAndRun()
                completion(.finished)
            }
        }
        backgroundActivityScheduler = backgroundActivity
    }

    func stopMonitoring() {
        isMonitoring = false
        timer?.invalidate()
        timer = nil
        backgroundActivityScheduler?.invalidate()
        backgroundActivityScheduler = nil
        cancelScheduledWork()
    }

    private func startScheduledCheck() {
        scheduledCheckTask?.cancel()
        scheduledCheckTask = Task { @MainActor [weak self] in
            await self?.checkAndRun()
        }
    }

    private func startScheduledRun(_ dueSchedule: Schedule) {
        let scheduleIdentity = dueSchedule.targetUDID ?? "legacy"
        guard scheduledRunTasks[scheduleIdentity] == nil,
              isScheduleCurrent(dueSchedule, requiresActiveMonitoring: true) else { return }

        let runID = UUID()
        guard scheduledRunOwnership.claim(identity: scheduleIdentity, runID: runID) else { return }

        scheduledRunSchedules[scheduleIdentity] = dueSchedule
        scheduledRunIDs[scheduleIdentity] = runID
        scheduledRunTasks[scheduleIdentity] = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.run(
                schedule: dueSchedule,
                requiresActiveMonitoring: true,
                runID: runID
            )
            self.finishScheduledRunTask(identity: scheduleIdentity, runID: runID)
        }
    }

    private func cancelScheduledWork() {
        scheduledCheckTask?.cancel()
        scheduledCheckTask = nil
        scheduledRunTasks.values.forEach { $0.cancel() }
        // Keep task/run ownership until each cancelled queue request reaches a
        // terminal state. Releasing it here can let a replacement schedule join
        // the stale per-device request before its cancellation handler runs.
        isRunningScheduledBackup = !scheduledRunOwnership.isEmpty
    }

    private func cancelInvalidScheduledWork() {
        let invalidScheduleIdentities = scheduledRunSchedules.compactMap { scheduleIdentity, scheduledRun in
            isScheduleCurrent(scheduledRun, requiresActiveMonitoring: true) ? nil : scheduleIdentity
        }
        for scheduleIdentity in invalidScheduleIdentities {
            scheduledRunTasks[scheduleIdentity]?.cancel()
        }
        isRunningScheduledBackup = !scheduledRunOwnership.isEmpty
    }

    private func finishScheduledRunTask(identity: String, runID: UUID) {
        guard scheduledRunIDs[identity] == runID else { return }
        scheduledRunTasks.removeValue(forKey: identity)
        scheduledRunSchedules.removeValue(forKey: identity)
        scheduledRunIDs.removeValue(forKey: identity)
    }

    private func finishScheduledBackupRun(identity: String, runID: UUID) {
        guard scheduledRunOwnership.finish(identity: identity, runID: runID) else { return }
        isRunningScheduledBackup = !scheduledRunOwnership.isEmpty
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
            cancelInvalidScheduledWork()
        }
    }

    func checkAndRun() async {
        guard isMonitoring, !Task.isCancelled else { return }
        reloadFromDefaults()
        guard isMonitoring, !Task.isCancelled else { return }
        var dueSchedules: [Schedule] = []
        for stored in schedules where stored.enabled {
            var candidate = stored
            if candidate.nextRunDate == nil {
                candidate.nextRunDate = nextRunDate(for: candidate)
                storeSchedule(candidate, replacingTargetUDID: stored.targetUDID)
            }
            if let nextRun = candidate.nextRunDate,
               Date() >= nextRun,
               !scheduledRunOwnership.isOwned(identity: candidate.targetUDID ?? "legacy") {
                dueSchedules.append(candidate)
            }
        }

        await withTaskGroup(of: Void.self) { group in
            for dueSchedule in dueSchedules {
                group.addTask { @MainActor [weak self] in
                    self?.startScheduledRun(dueSchedule)
                }
            }
        }
    }

    func runNow() async {
        let scheduleIdentity = schedule.targetUDID ?? "legacy"
        let runID = UUID()
        guard scheduledRunOwnership.claim(identity: scheduleIdentity, runID: runID) else { return }
        await run(
            schedule: schedule,
            requiresActiveMonitoring: false,
            runID: runID
        )
    }

    private func run(
        schedule runSchedule: Schedule,
        requiresActiveMonitoring: Bool,
        runID: UUID
    ) async {
        let scheduleIdentity = runSchedule.targetUDID ?? "legacy"
        defer { finishScheduledBackupRun(identity: scheduleIdentity, runID: runID) }
        guard isScheduledRunStillValid(
            runSchedule,
            requiresActiveMonitoring: requiresActiveMonitoring,
            runID: runID
        ) else { return }
        isRunningScheduledBackup = true

        let backupRoot = BackupManager.activeBackupDir
        let locationPreflight = await BackupLocationMonitor.preflightForWrite(path: backupRoot)
        if ScheduledNetworkBackupPolicy.shouldKeepScheduleDue(for: locationPreflight.status) {
            guard var updated = currentScheduleForCompletion(
                runSchedule,
                requiresActiveMonitoring: requiresActiveMonitoring,
                runID: runID
            ) else { return }
            let failure = locationPreflight.message ?? "Waiting for network backup location"
            updated.lastResult = "Waiting for network backup location: \(failure)"
            storeSchedule(updated, replacingTargetUDID: runSchedule.targetUDID)
            addLog("Waiting for network backup location: \(failure)", success: false)
            return
        }

        let discovery = await findTargetDevice(for: runSchedule)
        guard isScheduledRunStillValid(
            runSchedule,
            requiresActiveMonitoring: requiresActiveMonitoring,
            runID: runID
        ) else { return }
        guard let target = discovery.target else {
            let failure = discovery.failure ?? "No device available for backup"
            guard var updated = currentScheduleForCompletion(
                runSchedule,
                requiresActiveMonitoring: requiresActiveMonitoring,
                runID: runID
            ) else { return }
            // Keep a missed target due. The monitor will retry on its next tick
            // instead of skipping a Wi-Fi device until the next daily interval
            // after one transient discovery miss.
            updated.lastResult = "Waiting to retry: \(failure)"
            storeSchedule(updated, replacingTargetUDID: runSchedule.targetUDID)
            addLog("Waiting to retry: \(failure)", success: false)
            return
        }
        await runScheduledBackup(
            schedule: runSchedule,
            udid: target.udid,
            preferNetwork: target.preferNetwork,
            requiresActiveMonitoring: requiresActiveMonitoring,
            runID: runID
        )
    }

    private func isScheduledRunStillValid(
        _ runSchedule: Schedule,
        requiresActiveMonitoring: Bool,
        runID: UUID
    ) -> Bool {
        let scheduleIdentity = runSchedule.targetUDID ?? "legacy"
        guard !Task.isCancelled,
              scheduledRunOwnership.owns(identity: scheduleIdentity, runID: runID) else { return false }
        return isScheduleCurrent(runSchedule, requiresActiveMonitoring: requiresActiveMonitoring)
    }

    private func currentScheduleForCompletion(
        _ runSchedule: Schedule,
        requiresActiveMonitoring: Bool,
        runID: UUID
    ) -> Schedule? {
        guard isScheduledRunStillValid(
            runSchedule,
            requiresActiveMonitoring: requiresActiveMonitoring,
            runID: runID
        ), let persisted = latestSchedule(matching: runSchedule.targetUDID), persisted == runSchedule else {
            return nil
        }
        return persisted
    }

    private func isScheduleCurrent(
        _ runSchedule: Schedule,
        requiresActiveMonitoring: Bool
    ) -> Bool {
        guard !requiresActiveMonitoring || isMonitoring,
              let persisted = latestSchedule(matching: runSchedule.targetUDID),
              persisted.enabled else { return false }
        return persisted == runSchedule
    }

    // MARK: - Backup Execution

    private func runScheduledBackup(
        schedule runSchedule: Schedule,
        udid: String,
        preferNetwork: Bool,
        requiresActiveMonitoring: Bool,
        runID: UUID
    ) async {
        scheduledBackupProgress = "Starting scheduled backup..."
        addLog("Scheduled backup started for \(runSchedule.targetName ?? "device \(udid.prefix(8))...")", success: true)

        let incremental = runSchedule.incrementalOnly && BackupManager.hasExistingBackup(for: udid)
        if runSchedule.incrementalOnly && !incremental {
            addLog("No complete backup exists yet; running required first full backup", success: true)
        }

        guard let backupViewModel else {
            let failure = "The shared backup queue is unavailable"
            guard var updated = currentScheduleForCompletion(
                runSchedule,
                requiresActiveMonitoring: requiresActiveMonitoring,
                runID: runID
            ) else { return }
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

        guard var updated = currentScheduleForCompletion(
            runSchedule,
            requiresActiveMonitoring: requiresActiveMonitoring,
            runID: runID
        ) else { return }
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

        // Collect every applicable backend before resolving. This both keeps
        // legacy nil-target schedules fail-closed and lets an exact any-transport
        // target prefer a USB route found by a fallback over a network-only
        // observation from another backend.
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

        discoveredCandidates.append(contentsOf: await libimobiledeviceCandidates(wifiOnly: runSchedule.wifiOnly))

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

    private func libimobiledeviceCandidates(
        wifiOnly: Bool
    ) async -> [ScheduledBackupTargetResolver.Candidate] {
        if wifiOnly {
            let network = await Shell.runAsync("idevice_id", arguments: ["-n"], timeout: 5)
            guard network.succeeded else { return [] }
            return network.output.components(separatedBy: "\n")
                .filter { !$0.isEmpty }
                .map { ScheduledBackupTargetResolver.Candidate(udid: $0, preferNetwork: true) }
        }

        async let usbResult = Shell.runAsync("idevice_id", arguments: ["-l"], timeout: 5)
        async let networkResult = Shell.runAsync("idevice_id", arguments: ["-n"], timeout: 5)
        let usb = await usbResult
        let network = await networkResult
        var candidates: [ScheduledBackupTargetResolver.Candidate] = []
        if usb.succeeded {
            candidates += usb.output.components(separatedBy: "\n")
                .filter { !$0.isEmpty }
                .map { ScheduledBackupTargetResolver.Candidate(udid: $0, preferNetwork: false) }
        }
        if network.succeeded {
            candidates += network.output.components(separatedBy: "\n")
                .filter { !$0.isEmpty }
                .map { ScheduledBackupTargetResolver.Candidate(udid: $0, preferNetwork: true) }
        }
        return candidates
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
        cancelInvalidScheduledWork()
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
