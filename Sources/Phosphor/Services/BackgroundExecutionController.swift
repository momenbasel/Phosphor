import AppKit
import Foundation

/// Keeps Phosphor reachable while enabled schedules or a live backup require a
/// windowless process. Normal idle behavior remains: no schedules + no backup
/// means closing the last window quits the app.
@MainActor
final class BackgroundExecutionController: NSObject {
    static let shared = BackgroundExecutionController()

    private var scheduledWorkEnabled = false
    private var statusItem: NSStatusItem?
    private var operationObserver: NSObjectProtocol?

    override private init() {
        super.init()
    }

    var keepsRunningAfterLastWindowClosed: Bool {
        scheduledWorkEnabled
    }

    func configureAfterLaunch() {
        guard operationObserver == nil else { return }
        operationObserver = NotificationCenter.default.addObserver(
            forName: .backupOperationStateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshStatusItem()
                self?.terminateWhenIdleIfWindowless()
            }
        }
        refreshStatusItem()
    }

    func setScheduledWorkEnabled(_ enabled: Bool) {
        guard scheduledWorkEnabled != enabled else {
            refreshStatusItem()
            return
        }
        scheduledWorkEnabled = enabled
        refreshStatusItem()
        terminateWhenIdleIfWindowless()
    }

    func showMainWindow() {
        if let window = NSApp.windows.first(where: { $0.canBecomeMain && !$0.isMiniaturized }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            NSApp.sendAction(#selector(NSApplication.newWindowForTab(_:)), to: nil, from: nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func terminateWhenIdleIfWindowless() {
        guard !scheduledWorkEnabled,
              !ApplicationTerminationCoordinator.shared.hasActiveOperations,
              !NSApp.windows.contains(where: { $0.isVisible && !$0.isMiniaturized }) else { return }
        NSApp.terminate(nil)
    }

    private func refreshStatusItem() {
        let backupActive = ApplicationTerminationCoordinator.shared.hasActiveOperations
        let shouldShow = scheduledWorkEnabled || backupActive

        if shouldShow {
            if statusItem == nil {
                let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
                item.button?.image = NSImage(
                    systemSymbolName: "externaldrive.badge.timemachine",
                    accessibilityDescription: "Phosphor"
                )
                let menu = NSMenu()
                let openItem = menu.addItem(withTitle: "Open Phosphor", action: #selector(openPhosphor), keyEquivalent: "")
                openItem.target = self
                menu.addItem(.separator())
                let quitItem = menu.addItem(withTitle: "Quit Phosphor", action: #selector(quitPhosphor), keyEquivalent: "q")
                quitItem.target = self
                item.menu = menu
                statusItem = item
            }
            statusItem?.button?.toolTip = backupActive
                ? "Phosphor backup in progress"
                : "Phosphor is running for scheduled backups"
        } else if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
            self.statusItem = nil
        }
    }

    @objc private func openPhosphor() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.showMainWindow()
        }
    }

    @objc private func quitPhosphor() {
        NSApp.terminate(nil)
    }
}
