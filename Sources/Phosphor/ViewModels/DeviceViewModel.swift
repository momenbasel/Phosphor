import Foundation
import SwiftUI

/// Orchestrates device-related UI state. Bridges DeviceManager with SwiftUI views.
@MainActor
final class DeviceViewModel: ObservableObject {

    @Published var devices: [DeviceInfo] = []
    @Published var selectedDevice: DeviceInfo?
    @Published var isRefreshing = false
    @Published var showPairAlert = false
    @Published var alertMessage = ""
    @Published var systemInfo: [String: String] = [:]

    let deviceManager = DeviceManager()

    var hasDevices: Bool { !devices.isEmpty }

    func refresh() async {
        isRefreshing = true
        await deviceManager.scanForDevices()
        devices = deviceManager.connectedDevices
        selectedDevice = deviceManager.selectedDevice
        isRefreshing = false
    }

    func selectDevice(_ device: DeviceInfo) {
        selectedDevice = device
        deviceManager.selectedDevice = device
    }

    func pair() async {
        guard let udid = selectedDevice?.id else { return }
        let ok = await deviceManager.pairDevice(udid: udid)
        alertMessage = ok ? "Device paired successfully" : (deviceManager.lastError ?? "Pairing failed")
        showPairAlert = true
        if ok { await refresh() }
    }

    func loadSystemInfo() async {
        guard let udid = selectedDevice?.id else { return }
        let diagnostics = DiagnosticsManager()
        systemInfo = await diagnostics.getDetailedSystemInfo(udid: udid)
    }

    func takeScreenshot() async -> String? {
        guard let udid = selectedDevice?.id else { return nil }
        let path = NSTemporaryDirectory() + "phosphor-screenshot-\(Int(Date().timeIntervalSince1970)).png"
        let ok = await deviceManager.takeScreenshot(udid: udid, saveTo: path)
        return ok ? path : nil
    }
}
