import AppKit
import Foundation

/// AppKit termination bridge for every BackupManager owner in the process.
/// Quit is deferred until each managed backup/restore process group has been
/// cancelled and reaped; new operations are refused once draining begins.
@MainActor
final class ApplicationTerminationCoordinator {
    static let shared = ApplicationTerminationCoordinator()

    private final class WeakManager {
        weak var value: BackupManager?
        init(_ value: BackupManager) { self.value = value }
    }

    private var managers: [ObjectIdentifier: WeakManager] = [:]
    private var isDraining = false

    private init() {}

    var hasActiveOperations: Bool {
        removeReleasedManagers()
        return !managers.isEmpty
    }

    func register(_ manager: BackupManager) -> Bool {
        removeReleasedManagers()
        guard !isDraining else { return false }
        managers[ObjectIdentifier(manager)] = WeakManager(manager)
        NotificationCenter.default.post(name: .backupOperationStateDidChange, object: nil)
        return true
    }

    func unregister(_ manager: BackupManager) {
        if managers.removeValue(forKey: ObjectIdentifier(manager)) != nil {
            NotificationCenter.default.post(name: .backupOperationStateDidChange, object: nil)
        }
    }

    func applicationShouldTerminate() -> NSApplication.TerminateReply {
        removeReleasedManagers()
        guard !managers.isEmpty else { return .terminateNow }
        guard !isDraining else { return .terminateLater }

        isDraining = true
        let activeManagers = managers.values.compactMap(\.value)
        Task { @MainActor [weak self] in
            await withTaskGroup(of: Void.self) { group in
                for manager in activeManagers {
                    group.addTask {
                        await manager.cancelForApplicationTermination()
                    }
                }
                await group.waitForAll()
            }
            self?.removeReleasedManagers()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    private func removeReleasedManagers() {
        managers = managers.filter { $0.value.value != nil }
    }
}
