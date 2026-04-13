import Foundation
import SwiftUI
import Combine

/// Drives diagnostics UI: battery, storage, syslog, device actions.
/// Forwards DiagnosticsManager's published syslog changes to trigger SwiftUI updates.
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
    @Published var processes: [DiagnosticsManager.DeviceProcess] = []
    @Published var isLoadingProcesses = false
    @Published var crashReports: [DiagnosticsManager.CrashReport] = []
    @Published var isLoadingCrashes = false

    let diagnostics = DiagnosticsManager()
    private var cancellables = Set<AnyCancellable>()

    init() {
        // Forward syslogLines from DiagnosticsManager to this ViewModel
        // so SwiftUI picks up the changes
        diagnostics.$syslogLines
            .receive(on: RunLoop.main)
            .assign(to: &$syslogLines)

        diagnostics.$isStreamingSyslog
            .receive(on: RunLoop.main)
            .assign(to: &$isStreamingSyslog)
    }

    var filteredSyslog: [String] {
        guard !syslogFilter.isEmpty else { return syslogLines }
        return syslogLines.filter { $0.localizedCaseInsensitiveContains(syslogFilter) }
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
    }

    func clearSyslog() {
        diagnostics.clearSyslog()
        // Also clear local copy immediately for instant UI feedback
        syslogLines = []
    }

    func exportSyslog(to path: String) {
        do {
            try diagnostics.exportSyslog(to: path)
            alertMessage = "Syslog exported to \(path)"
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

    func loadProcesses(udid: String) async {
        isLoadingProcesses = true
        processes = await diagnostics.getProcessList(udid: udid)
        isLoadingProcesses = false
    }

    func pullCrashReports(udid: String) async {
        isLoadingCrashes = true
        let dir = NSTemporaryDirectory() + "phosphor-crashes-\(udid.prefix(8))"
        crashReports = await diagnostics.pullCrashReports(udid: udid, to: dir)
        isLoadingCrashes = false
    }
}
