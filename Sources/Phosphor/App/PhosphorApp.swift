import SwiftUI

@main
struct PhosphorApp: App {

    @StateObject private var deviceVM = DeviceViewModel()
    @StateObject private var backupVM = BackupViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(deviceVM)
                .environmentObject(backupVM)
                .frame(minWidth: 960, minHeight: 640)
                .onAppear {
                    deviceVM.deviceManager.startPolling(interval: 4.0)
                    backupVM.loadBackups()
                }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: true))
        .defaultSize(width: 1100, height: 720)
        .commands {
            CommandGroup(replacing: .newItem) {}

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
                Button("New Backup") {
                    guard let udid = deviceVM.selectedDevice?.id else { return }
                    Task { await backupVM.createBackup(udid: udid) }
                }
                .keyboardShortcut("b", modifiers: .command)
                .disabled(deviceVM.selectedDevice == nil)

                Button("Refresh Backups") {
                    backupVM.loadBackups()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView()
        }
    }
}
