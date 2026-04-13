import Foundation
import Combine

/// Manages iOS device detection and information retrieval via libimobiledevice CLI tools.
@MainActor
final class DeviceManager: ObservableObject {

    @Published var connectedDevices: [DeviceInfo] = []
    @Published var selectedDevice: DeviceInfo?
    @Published var isScanning = false
    @Published var lastError: String?
    @Published var dependencyStatus: [String: Bool] = [:]

    private var pollTimer: Timer?

    init() {
        checkDependencies()
    }

    // MARK: - Dependency Check

    func checkDependencies() {
        Task {
            dependencyStatus = await withCheckedContinuation { continuation in
                DispatchQueue.global().async {
                    continuation.resume(returning: Shell.checkDependencies())
                }
            }
        }
    }

    var hasRequiredTools: Bool {
        dependencyStatus["idevice_id"] == true && dependencyStatus["ideviceinfo"] == true
    }

    var missingTools: [String] {
        dependencyStatus.filter { !$0.value }.map(\.key).sorted()
    }

    // MARK: - Device Detection

    func scanForDevices() async {
        isScanning = true
        lastError = nil

        let result = await Shell.runAsync("idevice_id", arguments: ["-l"])

        guard result.succeeded else {
            if result.stderr.contains("command not found") || result.exitCode == 127 {
                lastError = "libimobiledevice not installed. Run: brew install libimobiledevice"
            } else {
                lastError = result.stderr.nilIfEmpty ?? "No devices found"
            }
            connectedDevices = []
            isScanning = false
            return
        }

        let udids = result.output.components(separatedBy: "\n").filter { !$0.isEmpty }

        if udids.isEmpty {
            connectedDevices = []
            selectedDevice = nil
            isScanning = false
            return
        }

        var devices: [DeviceInfo] = []
        for udid in udids {
            if let device = await fetchDeviceInfo(udid: udid) {
                devices.append(device)
            }
        }

        connectedDevices = devices
        if selectedDevice == nil || !devices.contains(where: { $0.id == selectedDevice?.id }) {
            selectedDevice = devices.first
        }
        isScanning = false
    }

    /// Fetch detailed info for a specific device.
    func fetchDeviceInfo(udid: String) async -> DeviceInfo? {
        let result = await Shell.runAsync("ideviceinfo", arguments: ["-u", udid])
        guard result.succeeded else { return nil }

        let info = result.output.parseKeyValuePairs()

        // Fetch battery info separately (requires different domain)
        let batteryResult = await Shell.runAsync("ideviceinfo", arguments: ["-u", udid, "-q", "com.apple.mobile.battery"])
        let batteryInfo = batteryResult.output.parseKeyValuePairs()

        // Fetch disk usage
        let diskResult = await Shell.runAsync("ideviceinfo", arguments: ["-u", udid, "-q", "com.apple.disk_usage"])
        let diskInfo = diskResult.output.parseKeyValuePairs()

        let batteryLevel = batteryInfo["BatteryCurrentCapacity"].flatMap(Int.init)
        let batteryCharging = batteryInfo["BatteryIsCharging"].map { $0 == "true" }

        let totalDisk = diskInfo["TotalDiskCapacity"].flatMap(UInt64.init)
        let freeDisk = diskInfo["AmountDataAvailable"].flatMap(UInt64.init)

        // Check pair status
        let pairResult = await Shell.runAsync("idevicepair", arguments: ["-u", udid, "validate"])

        return DeviceInfo(
            id: udid,
            name: info["DeviceName"] ?? "Unknown Device",
            model: info["ProductType"] ?? "Unknown",
            modelNumber: info["ModelNumber"] ?? "",
            productType: info["ProductType"] ?? "",
            iosVersion: info["ProductVersion"] ?? "",
            buildVersion: info["BuildVersion"] ?? "",
            serialNumber: info["SerialNumber"] ?? "",
            wifiAddress: info["WiFiAddress"] ?? "",
            bluetoothAddress: info["BluetoothAddress"] ?? "",
            phoneNumber: info["PhoneNumber"],
            imei: info["InternationalMobileEquipmentIdentity"],
            batteryLevel: batteryLevel,
            batteryCharging: batteryCharging,
            totalDiskCapacity: totalDisk,
            availableDiskSpace: freeDisk,
            isPaired: pairResult.succeeded,
            isActivated: info["ActivationState"] == "Activated"
        )
    }

    /// Pair with a device.
    func pairDevice(udid: String) async -> Bool {
        let result = await Shell.runAsync("idevicepair", arguments: ["-u", udid, "pair"])
        if !result.succeeded {
            lastError = result.stderr.nilIfEmpty ?? result.output
        }
        return result.succeeded
    }

    /// Unpair a device.
    func unpairDevice(udid: String) async -> Bool {
        let result = await Shell.runAsync("idevicepair", arguments: ["-u", udid, "unpair"])
        return result.succeeded
    }

    /// Get device name.
    func getDeviceName(udid: String) async -> String? {
        let result = await Shell.runAsync("idevicename", arguments: ["-u", udid])
        return result.succeeded ? result.output : nil
    }

    /// Set device name.
    func setDeviceName(udid: String, name: String) async -> Bool {
        let result = await Shell.runAsync("idevicename", arguments: ["-u", udid, name])
        return result.succeeded
    }

    /// Take a screenshot of the device.
    func takeScreenshot(udid: String, saveTo path: String) async -> Bool {
        let result = await Shell.runAsync("idevicescreenshot", arguments: ["-u", udid, path])
        return result.succeeded
    }

    // MARK: - Polling

    func startPolling(interval: TimeInterval = 3.0) {
        stopPolling()
        pollTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                await self.scanForDevices()
            }
        }
        Task { await scanForDevices() }
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }
}
