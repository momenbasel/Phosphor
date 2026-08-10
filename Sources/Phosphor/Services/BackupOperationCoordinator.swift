import Foundation

extension Notification.Name {
    static let backupOperationStateDidChange = Notification.Name("Phosphor.BackupOperationStateDidChange")
}

/// Process-wide read/write gate for backup manifests. Backup creation is a
/// writer; comparison is a reader over two snapshots. They must never overlap,
/// even when creation was started by a scheduler or clone flow with its own
/// `BackupManager` instance.
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

    func beginBackup() -> UUID? {
        lock.lock()
        guard comparisonTokens.isEmpty else {
            lock.unlock()
            return nil
        }
        let token = UUID()
        backupTokens.insert(token)
        lock.unlock()
        postStateChanged()
        return token
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
