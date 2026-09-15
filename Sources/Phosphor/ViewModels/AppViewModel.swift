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
    @Published private(set) var isUninstalling = false

    let appManager = AppManager()
    private var activeInstalledDeviceID: String?
    private var installedAppsLoadID: UUID?

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

    func prepareForInstalledDevice(_ udid: String?, isDeviceTabActive: Bool) {
        guard activeInstalledDeviceID != udid else { return }
        activeInstalledDeviceID = udid
        installedAppsLoadID = nil
        installedApps = []
        if isDeviceTabActive && udid == nil {
            isLoading = false
        }
    }

    func loadInstalledApps(udid: String) async {
        activeInstalledDeviceID = udid
        let loadID = UUID()
        installedAppsLoadID = loadID
        isLoading = true
        await appManager.listInstalledApps(udid: udid)
        guard activeInstalledDeviceID == udid, installedAppsLoadID == loadID else { return }
        installedApps = appManager.installedApps
        isLoading = false
    }

    /// Reading a backup's app list stats every file in every app domain, which is
    /// seconds of work on a large backup. Keep it off the main actor so the list
    /// can show a spinner instead of freezing.
    func loadBackupApps(backupPath: String) async {
        isLoading = true
        defer { isLoading = false }
        await appManager.loadBackupApps(backupPath: backupPath)
        backupApps = appManager.backupApps
        // A manifest that will not open (locked, missing, corrupt) is not the same
        // as a backup with no apps in it. Say which.
        if backupApps.isEmpty, let error = appManager.lastError {
            alertMessage = error
            showAlert = true
        }
    }

    func installIPA(path: String, udid: String) async {
        let ok = await appManager.installIPA(path: path, udid: udid)
        alertMessage = ok ? "App installed" : (appManager.lastError ?? "Installation failed")
        showAlert = true
        if ok { await loadInstalledApps(udid: udid) }
    }

    func uninstall(bundleId: String, udid: String) async {
        guard !isUninstalling else { return }
        guard activeInstalledDeviceID == udid,
              let app = installedApps.first(where: { $0.id == bundleId }),
              app.appType == .user else {
            alertMessage = "Only user-installed apps can be removed"
            showAlert = true
            return
        }

        isUninstalling = true
        defer { isUninstalling = false }
        let ok = await appManager.uninstallApp(bundleId: bundleId, udid: udid)
        guard activeInstalledDeviceID == udid else { return }
        alertMessage = ok ? "App removed" : (appManager.lastError ?? "Removal failed")
        showAlert = true
        if ok { installedApps.removeAll { $0.id == bundleId } }
    }

    /// Removes the requested user apps one at a time so failures can be reported
    /// honestly and left selected for a retry. Successful rows are removed in
    /// place, preserving the List's current scroll position.
    func uninstall(bundleIds: [String], udid: String) async -> Set<String> {
        guard !isUninstalling else { return [] }
        guard activeInstalledDeviceID == udid else { return [] }
        let removableIDs = bundleIds.filter { bundleId in
            installedApps.first(where: { $0.id == bundleId })?.appType == .user
        }
        guard !removableIDs.isEmpty else { return [] }
        isUninstalling = true
        defer { isUninstalling = false }
        var successfulIDs = Set<String>()
        var failedCount = 0

        for bundleId in removableIDs {
            guard activeInstalledDeviceID == udid else { break }
            if await appManager.uninstallApp(bundleId: bundleId, udid: udid) {
                successfulIDs.insert(bundleId)
            } else {
                failedCount += 1
            }
        }

        guard activeInstalledDeviceID == udid else { return successfulIDs }
        installedApps.removeAll { successfulIDs.contains($0.id) }
        let removedCount = successfulIDs.count
        if failedCount == 0 {
            alertMessage = "Removed \(removedCount) \(removedCount == 1 ? "app" : "apps")"
        } else {
            alertMessage = "Removed \(removedCount) \(removedCount == 1 ? "app" : "apps"). Failed to remove \(failedCount) \(failedCount == 1 ? "app" : "apps"); keep them selected and try again."
        }
        showAlert = true
        return successfulIDs
    }

    func extractAppData(bundleId: String, backupPath: String, to dest: String) async {
        let count = await appManager.extractAppData(bundleId: bundleId, from: backupPath, to: dest)
        // A partly-skipped extraction has both a count and a reason; report both
        // rather than letting the skip notice disappear behind a success message.
        if count > 0 {
            let summary = "Extracted \(count) \(count == 1 ? "file" : "files") to \(dest)."
            alertMessage = [summary, appManager.lastError].compactMap { $0 }.joined(separator: "\n")
        } else {
            alertMessage = appManager.lastError ?? "No files extracted"
        }
        showAlert = true
    }
}
