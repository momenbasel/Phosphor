import AppKit
import Foundation


/// AppKit termination bridge for every BackupManager owner in the process.
/// Quit is deferred until each managed backup/restore process group has been
/// cancelled and reaped; new operations are refused once draining begins.
@MainActor
final class ApplicationTerminationCoordinator {
    static let shared = ApplicationTerminationCoordinator()

    private final class WeakManager {
        weak var value: Phosphor.BackupManager?
        init(_ value: Phosphor.BackupManager) { self.value = value }
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

        // Ask the user before interrupting an active backup/restore.
        guard confirmTerminationWithActiveBackup(count: managers.count) else {
            return .terminateCancel
        }

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

    private func confirmTerminationWithActiveBackup(count: Int) -> Bool {
        // Bring Phosphor to the front so the alert is immediately visible even if Quit was triggered from the Dock or status bar.
        BackgroundExecutionController.shared.showMainWindow()

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = count > 1 ? "Backups in Progress — Quit Phosphor?" : "Backup in Progress — Quit Phosphor?"
        alert.informativeText = """
        \(count > 1 ? "\(count) backup operations are" : "A backup operation is") currently running.

        If you quit now, Phosphor will safely pause the backup and save all transferred files on disk so you can resume later.
        """
        alert.addButton(withTitle: "Keep Running")
        alert.addButton(withTitle: "Pause Backup & Quit")
        return alert.runModal() == .alertSecondButtonReturn
    }

    private func removeReleasedManagers() {
        managers = managers.filter { $0.value.value != nil }
    }
}
