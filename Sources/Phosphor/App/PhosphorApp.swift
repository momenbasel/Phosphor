import AppKit
import SwiftUI

final class PhosphorAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Avoid resurrecting a broken 0-window restoration state. SwiftUI owns
        // normal window creation; this only nudges AppKit when launch/reopen
        // completes with no visible app window.
        UserDefaults.standard.set(true, forKey: "ApplePersistenceIgnoreState")
        UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")
        BackgroundExecutionController.shared.configureAfterLaunch()
        ensureWindowSoon()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // A Dock click must also activate/front an existing window that is merely
        // behind another app, not only recreate a missing window.
        BackgroundExecutionController.shared.showMainWindow()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !BackgroundExecutionController.shared.keepsRunningAfterLastWindowClosed
            && !ApplicationTerminationCoordinator.shared.hasActiveOperations
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        ApplicationTerminationCoordinator.shared.applicationShouldTerminate()
    }

    private func ensureWindowSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            let hasVisibleWindow = NSApp.windows.contains { $0.isVisible && !$0.isMiniaturized }
            guard !hasVisibleWindow else { return }
            NSApp.sendAction(#selector(NSApplication.newWindowForTab(_:)), to: nil, from: nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

@main
struct PhosphorApp: App {

    @NSApplicationDelegateAdaptor(PhosphorAppDelegate.self) private var appDelegate
    @StateObject private var deviceVM = DeviceViewModel()
    @StateObject private var backupVM = BackupViewModel()
    @StateObject private var unifiedSearchVM = UnifiedSearchViewModel()
    @StateObject private var messageVM = MessageViewModel()
    @StateObject private var whatsAppVM = WhatsAppViewModel()
    @StateObject private var scheduler = BackupScheduler()
    @StateObject private var backupLocationMonitor = BackupLocationMonitor()
    @StateObject private var updateController = UpdateViewModel()
    @AppStorage("phosphor.hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @State private var selectedSection: SidebarSection? = .devices

    init() {
        // Pre-1.0.4 users defaulted to Apple's MobileSync directory implicitly.
        // Pin that choice explicitly so they don't lose sight of existing backups
        // when the default flips to ~/Documents/Phosphor Backups.
        BackupManager.migrateLegacyBackupDirectory()
    }

    var body: some Scene {
        WindowGroup {
            ContentView(selectedSection: $selectedSection)
                .environmentObject(deviceVM)
                .environmentObject(backupVM)
                .environmentObject(unifiedSearchVM)
                .environmentObject(updateController)
                .environmentObject(messageVM)
                .environmentObject(whatsAppVM)
                .environmentObject(backupLocationMonitor)
                .frame(minWidth: 960, minHeight: 640)
                .onAppear {
                    // Register scheduled/background ownership before the delayed
                    // foreground discovery work. Closing the first window during
                    // that delay must not terminate an app with enabled schedules.
                    scheduler.attachBackupViewModel(backupVM)
                    scheduler.startMonitoring()
                    backupLocationMonitor.start()
                    Task {
                        // Let SwiftUI paint the first window before starting
                        // device polling and backup discovery work.
                        try? await Task.sleep(for: .milliseconds(750))
                        deviceVM.deviceManager.startPolling(interval: 4.0)
                        backupVM.loadBackups()
                    }
                }
                .onReceive(backupLocationMonitor.$status.removeDuplicates()) { status in
                    backupVM.loadBackups()
                    Task {
                        await deviceVM.refreshReadiness()
                        if status == .available {
                            await scheduler.checkAndRun()
                        }
                    }
                }
                .sheet(isPresented: showOnboarding) {
                    OnboardingView(isPresented: showOnboarding)
                }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: true))
        .defaultSize(width: 1100, height: 720)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    Task { await updateController.checkForUpdates() }
                }
                .disabled(updateController.isChecking)
            }

            CommandMenu("Quick Actions") {
                Button("Backup Now") {
                    startBackupNow()
                }
                .disabled(deviceVM.selectedDevice == nil || backupVM.isCreating)

                Button("Open Backup Folder") {
                    openBackupFolder()
                }

                Divider()

                Button("Refresh Devices") {
                    Task { await deviceVM.refresh() }
                }

                Button("Refresh Backups") {
                    backupVM.loadBackups()
                }

                Divider()

                Button("Show Backups") {
                    selectedSection = .backups
                }

                Button("Show Messages") {
                    selectedSection = .messages
                }

                Button("Show Photos") {
                    selectedSection = .photos
                }

                Button("Show Files") {
                    selectedSection = .files
                }
            }
            CommandMenu("Device") {
                Button("Refresh Devices") {
                    Task { await deviceVM.refresh() }
                }
                .keyboardShortcut("r", modifiers: .command)

                Button("Pair Device") {
                    Task { await deviceVM.pair() }
                }
                .disabled(deviceVM.selectedDevice == nil)

                Divider()

                Button("Take Screenshot") {
                    Task { let _ = await deviceVM.takeScreenshot() }
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(deviceVM.selectedDevice == nil)
            }

            CommandMenu("Backup") {
                Button("Backup Now") {
                    startBackupNow()
                }
                .keyboardShortcut("b", modifiers: .command)
                // Scoped to the selected device, not the global isCreating flag:
                // #60 allows a second device to back up while the first is
                // running, so a global gate here would disable Cmd-B for a
                // device that is perfectly free.
                .disabled(
                    deviceVM.selectedDevice == nil ||
                    deviceVM.selectedDevice.map { backupVM.isBackupActive(for: $0.id) } == true
                )

                Button("Open Backup Folder") {
                    openBackupFolder()
                }

                Button("Refresh Backups") {
                    backupVM.loadBackups()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView()
                .environmentObject(deviceVM)
                .environmentObject(backupVM)
                .environmentObject(backupLocationMonitor)
                .environmentObject(updateController)
        }
    }

    private var showOnboarding: Binding<Bool> {
        Binding(
            get: { !hasCompletedOnboarding },
            set: { if !$0 { hasCompletedOnboarding = true } }
        )
    }

    private func startBackupNow() {
        guard let device = deviceVM.selectedDevice, !backupVM.isCreating else { return }
        if device.connectionType == .wifi && !BackupManager.hasExistingBackup(for: device.id) {
            guard confirmFirstFullWiFiBackup(for: device) else { return }
        }
        selectedSection = .backups
        Task {
            await backupVM.createBackup(
                udid: device.id,
                incremental: false,
                preferNetwork: device.connectionType == .wifi
            )
        }
    }

    private func openBackupFolder() {
        NSWorkspace.shared.open(URL(fileURLWithPath: BackupManager.activeBackupDir, isDirectory: true))
    }

    private func confirmFirstFullWiFiBackup(for device: DeviceInfo) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Create First Full Wi-Fi Backup?"
        alert.informativeText = "\(device.name) does not have complete backup metadata yet. The first backup must be full and can take a long time over Wi-Fi. USB is recommended. Continue with Wi-Fi?"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Create Full Wi-Fi Backup")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
