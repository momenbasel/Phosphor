import Foundation

extension Notification.Name {
    static let backupOperationStateDidChange = Notification.Name("Phosphor.BackupOperationStateDidChange")
}

// Two independent things have to be coordinated here, and PRs #54, #58, #60 and
// #70 each shipped a file by this name that solved only one of them.
//
//   1. Which *device* may be written right now. Backups are started by several
//      owners with their own BackupManager instances (manual, scheduled, clone),
//      so an instance-local flag cannot stop two subprocesses pointing at the
//      same backup folder. That is BackupOperationRegistry below: ownership is
//      per-UDID, and different devices may run at once up to a small cap.
//
//   2. Whether a *reader* may run. Comparison walks two archived snapshots and
//      must not overlap a writer. That is BackupOperationCoordinator below.
//
// #58's variant enforced a single global backup lease, which would have made the
// multi-device feature in #60 pointless; #60's registry subsumes it, and #54 is
// #60's registry minus the cap. Keeping the two concerns as separate types is
// what lets both land.

/// Process-wide ownership for destructive backup/restore operations. Different
/// devices may run concurrently, but one physical device can have only one owner.
struct BackupOperationRegistry {
    private let maxConcurrentOperations = 2
    private var operationByDevice: [String: UUID] = [:]

    mutating func acquire(udid: String, operationID: UUID) -> Bool {
        guard operationByDevice[udid] == nil else { return false }
        guard operationByDevice.count < maxConcurrentOperations else { return false }
        operationByDevice[udid] = operationID
        return true
    }

    mutating func release(udid: String, operationID: UUID) -> Bool {
        guard operationByDevice[udid] == operationID else { return false }
        operationByDevice.removeValue(forKey: udid)
        return true
    }
}

/// Per-BackupManager identity paired with the shared per-device registry.
struct BackupDeviceCoordinator {
    private(set) var activeOperationID: UUID?
    private var activeUDID: String?

    mutating func begin(
        udid: String,
        operationID: UUID = UUID(),
        registry: inout BackupOperationRegistry
    ) -> UUID? {
        guard activeOperationID == nil else { return nil }
        guard registry.acquire(udid: udid, operationID: operationID) else { return nil }

        activeOperationID = operationID
        activeUDID = udid
        return operationID
    }

    @discardableResult
    mutating func finish(
        operationID: UUID,
        registry: inout BackupOperationRegistry
    ) -> Bool {
        guard activeOperationID == operationID, let activeUDID else { return false }
        guard registry.release(udid: activeUDID, operationID: operationID) else { return false }

        self.activeOperationID = nil
        self.activeUDID = nil
        return true
    }
}

/// Process-wide reader/writer gate between backup creation and snapshot
/// comparison.
final class BackupOperationCoordinator: @unchecked Sendable {
    static let shared = BackupOperationCoordinator()

    private let lock = NSLock()
    private var backupTokens: Set<UUID> = []
    private var comparisonTokens: Set<UUID> = []

    private init() {}

    var hasActiveBackup: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !backupTokens.isEmpty
    }

    /// Writers always win. A comparison is a read-only pass over two archived
    /// snapshots and is restartable, so refusing a backup because one is open
    /// traded a real backup for a diff: the scheduled run failed instantly,
    /// BackupScheduler still advanced lastRunDate, and a weekly schedule went a
    /// full extra week with no backup. Starting a backup now invalidates any
    /// in-flight comparison, which notices between rows and stops.
    func beginBackup() -> UUID? {
        lock.lock()
        comparisonTokens.removeAll()
        let token = UUID()
        backupTokens.insert(token)
        lock.unlock()
        postStateChanged()
        return token
    }

    /// False once a writer has invalidated this comparison.
    func comparisonIsValid(_ token: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return comparisonTokens.contains(token)
    }

    func endBackup(_ token: UUID) {
        lock.lock()
        let changed = backupTokens.remove(token) != nil
        lock.unlock()
        if changed { postStateChanged() }
    }

    func beginComparison() -> UUID? {
        lock.lock()
        defer { lock.unlock() }
        guard backupTokens.isEmpty else { return nil }
        let token = UUID()
        comparisonTokens.insert(token)
        return token
    }

    func endComparison(_ token: UUID) {
        lock.lock()
        comparisonTokens.remove(token)
        lock.unlock()
    }

    private func postStateChanged() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .backupOperationStateDidChange, object: nil)
        }
    }
}
