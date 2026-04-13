import Foundation
import SwiftUI

/// Drives diagnostics UI: battery, storage, syslog, device actions.
@MainActor
final class DiagnosticsViewModel: ObservableObject {

    @Published var battery: DiagnosticsManager.BatteryDiagnostics?
    @Published var storage: DiagnosticsManager.StorageBreakdown?
    @Published var syslogLines: [String] = []
    @Published var isStreamingSyslog = false
    @Published var syslogFilter = ""
    @Published var isLoading = false
    @Published var showAlert = false
    @Published var alertMessage = ""

    let diagnostics = DiagnosticsManager()

    var filteredSyslog: [String] {
        guard !syslogFilter.isEmpty else { return diagnostics.syslogLines }
        return diagnostics.syslogLines.filter { $0.localizedCaseInsensitiveContains(syslogFilter) }
    }

    func loadAll(udid: String) async {
        isLoading = true
        async let b = diagnostics.getBatteryDiagnostics(udid: udid)
        async let s = diagnostics.getStorageBreakdown(udid: udid)
        battery = await b
        storage = await s
        isLoading = false
    }

    func toggleSyslog(udid: String) {
        if diagnostics.isStreamingSyslog {
            diagnostics.stopSyslog()
        } else {
            diagnostics.startSyslog(udid: udid)
        }
        isStreamingSyslog = diagnostics.isStreamingSyslog
    }

    func clearSyslog() {
        diagnostics.clearSyslog()
    }

    func exportSyslog(to path: String) {
        do {
            try diagnostics.exportSyslog(to: path)
            alertMessage = "Syslog exported"
            showAlert = true
        } catch {
            alertMessage = "Export failed: \(error.localizedDescription)"
            showAlert = true
        }
    }

    func restart(udid: String) async {
        let ok = await diagnostics.restartDevice(udid: udid)
        alertMessage = ok ? "Restart command sent" : "Restart failed"
        showAlert = true
    }

    func shutdown(udid: String) async {
        let ok = await diagnostics.shutdownDevice(udid: udid)
        alertMessage = ok ? "Shutdown command sent" : "Shutdown failed"
        showAlert = true
    }

    func sleep(udid: String) async {
        let ok = await diagnostics.sleepDevice(udid: udid)
        alertMessage = ok ? "Sleep command sent" : "Sleep failed"
        showAlert = true
    }
}
