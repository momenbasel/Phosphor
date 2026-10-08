import Foundation
import SwiftUI
import Combine

/// Orchestrates device-related UI state. Bridges DeviceManager with SwiftUI views.
@MainActor
final class DeviceViewModel: ObservableObject {

    @Published var devices: [DeviceInfo] = []
    @Published var nearbyWirelessDevices: [PyMobileDevice.BonjourDevice] = []
    @Published var selectedDevice: DeviceInfo?
    @Published var isRefreshing = false
    @Published var isEnablingWiFiSync = false
    @Published var showPairAlert = false
    @Published var alertMessage = ""
    @Published var systemInfo: [String: String] = [:]
    @Published var readinessReport: ReadinessReport?
    @Published var isCheckingReadiness = false

    let deviceManager = DeviceManager()
    private var cancellables: Set<AnyCancellable> = []

    init() {
        deviceManager.$connectedDevices
            .sink { [weak self] devices in
                self?.devices = devices
            }
            .store(in: &cancellables)

        deviceManager.$nearbyWirelessDevices
            .sink { [weak self] devices in
                self?.nearbyWirelessDevices = devices
            }
            .store(in: &cancellables)

        deviceManager.$selectedDevice
            .sink { [weak self] device in
                self?.selectedDevice = device
            }
            .store(in: &cancellables)

        // A backup folder on a NAS or external disk comes and goes with its
        // mount; re-evaluate readiness on mount events instead of waiting for
        // a manual refresh (#52).
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            NSWorkspace.shared.notificationCenter.publisher(for: name)
                .sink { [weak self] _ in
                    Task { await self?.refreshReadiness() }
                }
                .store(in: &cancellables)
        }
    }

    var hasDevices: Bool { !devices.isEmpty }

    func refresh() async {
        isRefreshing = true
        await deviceManager.scanForDevices(forceRefresh: true)
        devices = deviceManager.connectedDevices
        nearbyWirelessDevices = deviceManager.nearbyWirelessDevices
        selectedDevice = deviceManager.selectedDevice
        isRefreshing = false
        await refreshReadiness()
    }

    func refreshReadiness() async {
        isCheckingReadiness = true
        readinessReport = await ReadinessService.evaluate(
            devices: devices,
            nearbyWirelessDevices: nearbyWirelessDevices,
            backupDirectory: BackupManager.activeBackupDir
        )
        isCheckingReadiness = false
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

    func enableWiFiSync() async {
        guard let device = selectedDevice else { return }
        guard device.connectionType == .usb else {
            alertMessage = "Connect this device over USB, unlock it, tap Trust, then enable Wi-Fi."
            showPairAlert = true
            return
        }

        isEnablingWiFiSync = true
        let ok = await deviceManager.enableWiFiConnections(udid: device.id)
        isEnablingWiFiSync = false

        alertMessage = ok
            ? "Wi-Fi connection enabled. Unplug the cable, keep the device unlocked and on the same Wi-Fi, then scan again."
            : (deviceManager.lastError ?? "Failed to enable Wi-Fi connection")
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
