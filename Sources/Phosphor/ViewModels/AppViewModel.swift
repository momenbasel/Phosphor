import Foundation
import SwiftUI

/// Drives app management UI for both connected devices and backup browsing.
@MainActor
final class AppViewModel: ObservableObject {

    @Published var installedApps: [InstalledApp] = []
    @Published var backupApps: [AppBundle] = []
    @Published var isLoading = false
    @Published var searchQuery = ""
    @Published var showAlert = false
    @Published var alertMessage = ""

    let appManager = AppManager()

    var filteredInstalled: [InstalledApp] {
        guard !searchQuery.isEmpty else { return installedApps }
        return installedApps.filter {
            $0.name.localizedCaseInsensitiveContains(searchQuery) ||
            $0.id.localizedCaseInsensitiveContains(searchQuery)
        }
    }

    var filteredBackup: [AppBundle] {
        guard !searchQuery.isEmpty else { return backupApps }
        return backupApps.filter {
            $0.name.localizedCaseInsensitiveContains(searchQuery) ||
            $0.id.localizedCaseInsensitiveContains(searchQuery)
        }
    }

    func loadInstalledApps(udid: String) async {
        isLoading = true
        await appManager.listInstalledApps(udid: udid)
        installedApps = appManager.installedApps
        isLoading = false
    }

    func loadBackupApps(backupPath: String) {
        isLoading = true
        appManager.loadBackupApps(backupPath: backupPath)
        backupApps = appManager.backupApps
        isLoading = false
    }

    func installIPA(path: String, udid: String) async {
        let ok = await appManager.installIPA(path: path, udid: udid)
        alertMessage = ok ? "App installed" : (appManager.lastError ?? "Installation failed")
        showAlert = true
        if ok { await loadInstalledApps(udid: udid) }
    }

    func uninstall(bundleId: String, udid: String) async {
        let ok = await appManager.uninstallApp(bundleId: bundleId, udid: udid)
        alertMessage = ok ? "App removed" : (appManager.lastError ?? "Removal failed")
        showAlert = true
        if ok { await loadInstalledApps(udid: udid) }
    }

    func extractAppData(bundleId: String, backupPath: String, to dest: String) async {
        let count = await appManager.extractAppData(bundleId: bundleId, from: backupPath, to: dest)
        alertMessage = count > 0 ? "Extracted \(count) files" : "No files extracted"
        showAlert = true
    }
}
