import Foundation
import Combine

/// Manages iOS device detection and information retrieval.
/// Primary backend: pymobiledevice3. Fallback: libimobiledevice CLI tools.
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
        dependencyStatus["pymobiledevice3"] == true ||
        (dependencyStatus["idevice_id"] == true && dependencyStatus["ideviceinfo"] == true)
    }

    var missingTools: [String] {
        dependencyStatus.filter { !$0.value }.map(\.key).sorted()
    }

    // MARK: - Device Detection

    func scanForDevices() async {
        isScanning = true
        lastError = nil

        // Primary: pymobiledevice3 (with connection type)
        var entries = await PyMobileDevice.listDevicesWithType()

        // Fallback: libimobiledevice (assume USB)
        if entries.isEmpty {
            let result = await Shell.runAsync("idevice_id", arguments: ["-l"])
            if result.succeeded {
                entries = result.output.components(separatedBy: "\n")
                    .filter { !$0.isEmpty }
                    .map { PyMobileDevice.DeviceEntry(udid: $0, connectionType: "USB") }
            }
        }

        if entries.isEmpty {
            connectedDevices = []
            selectedDevice = nil
            isScanning = false
            return
        }

        var devices: [DeviceInfo] = []
        for entry in entries {
            let connType: DeviceInfo.ConnectionType = entry.connectionType == "USB" ? .usb : .wifi
            if var device = await fetchDeviceInfo(udid: entry.udid) {
                device.connectionType = connType
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
        // Primary: pymobiledevice3
        let info = await PyMobileDevice.deviceInfo(udid: udid)
        if !info.isEmpty {
            let batteryInfo = await PyMobileDevice.batteryInfo(udid: udid)
            let isPaired = await PyMobileDevice.validatePair(udid: udid)

            let batteryLevel = batteryInfo["CurrentCapacity"].flatMap(Int.init)
                ?? batteryInfo["BatteryCurrentCapacity"].flatMap(Int.init)
            let chargingVal = (batteryInfo["IsCharging"] ?? batteryInfo["BatteryIsCharging"] ?? "").lowercased()
            let batteryCharging = chargingVal == "true" || chargingVal == "1"

            let isTruthy: (String?) -> Bool = { val in
                guard let v = val?.lowercased() else { return false }
                return v == "true" || v == "1" || v == "yes"
            }

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
                totalDiskCapacity: info["TotalDiskCapacity"].flatMap(UInt64.init),
                availableDiskSpace: info["AmountDataAvailable"].flatMap(UInt64.init),
                totalDataCapacity: info["TotalDataCapacity"].flatMap(UInt64.init),
                totalSystemCapacity: info["TotalSystemCapacity"].flatMap(UInt64.init),
                isPaired: isPaired,
                isActivated: info["ActivationState"] == "Activated",
                chipID: info["ChipID"],
                boardId: info["BoardId"] ?? info["HardwareBoard"],
                hardwarePlatform: info["HardwarePlatform"],
                hardwareModel: info["HardwareModel"],
                cpuArchitecture: info["CPUArchitecture"],
                firmwareVersion: info["FirmwareVersion"],
                dieID: info["DieID"] ?? info["UniqueChipID"],
                basebandVersion: info["BasebandVersion"],
                basebandChipID: info["BasebandChipId"],
                basebandSerialNumber: info["BasebandSerialNumber"],
                basebandStatus: info["BasebandStatus"],
                activationState: info["ActivationState"],
                isSupervised: isTruthy(info["IsSupervised"]),
                productionSOC: isTruthy(info["ProductionSOC"]),
                hasPasscode: isTruthy(info["PasswordProtected"]),
                ethernetAddress: info["EthernetAddress"],
                carrierName: info["CarrierBundleInfoArray"] ?? info["PhoneNumber"].flatMap({ _ in info["SIMCarrierNetwork"] }),
                mobileCountryCode: info["MobileSubscriberCountryCode"],
                mobileNetworkCode: info["MobileSubscriberNetworkCode"],
                iccid: info["IntegratedCircuitCardIdentity"],
                connectionType: .usb
            )
        }

        // Fallback: libimobiledevice
        let result = await Shell.runAsync("ideviceinfo", arguments: ["-u", udid])
        guard result.succeeded else { return nil }

        let liInfo = result.output.parseKeyValuePairs()
        let batteryResult = await Shell.runAsync("ideviceinfo", arguments: ["-u", udid, "-q", "com.apple.mobile.battery"])
        let batteryInfo = batteryResult.output.parseKeyValuePairs()
        let diskResult = await Shell.runAsync("ideviceinfo", arguments: ["-u", udid, "-q", "com.apple.disk_usage"])
        let diskInfo = diskResult.output.parseKeyValuePairs()
        let pairResult = await Shell.runAsync("idevicepair", arguments: ["-u", udid, "validate"])

        return DeviceInfo(
            id: udid,
            name: liInfo["DeviceName"] ?? "Unknown Device",
            model: liInfo["ProductType"] ?? "Unknown",
            modelNumber: liInfo["ModelNumber"] ?? "",
            productType: liInfo["ProductType"] ?? "",
            iosVersion: liInfo["ProductVersion"] ?? "",
            buildVersion: liInfo["BuildVersion"] ?? "",
            serialNumber: liInfo["SerialNumber"] ?? "",
            wifiAddress: liInfo["WiFiAddress"] ?? "",
            bluetoothAddress: liInfo["BluetoothAddress"] ?? "",
            phoneNumber: liInfo["PhoneNumber"],
            imei: liInfo["InternationalMobileEquipmentIdentity"],
            batteryLevel: batteryInfo["BatteryCurrentCapacity"].flatMap(Int.init),
            batteryCharging: batteryInfo["BatteryIsCharging"].map { $0 == "true" },
            totalDiskCapacity: diskInfo["TotalDiskCapacity"].flatMap(UInt64.init),
            availableDiskSpace: diskInfo["AmountDataAvailable"].flatMap(UInt64.init),
            totalDataCapacity: diskInfo["TotalDataCapacity"].flatMap(UInt64.init),
            totalSystemCapacity: diskInfo["TotalSystemCapacity"].flatMap(UInt64.init),
            isPaired: pairResult.succeeded,
            isActivated: liInfo["ActivationState"] == "Activated",
            basebandVersion: liInfo["BasebandVersion"],
            activationState: liInfo["ActivationState"],
            connectionType: .usb
        )
    }

    /// Pair with a device.
    func pairDevice(udid: String) async -> Bool {
        // Primary: pymobiledevice3
        if await PyMobileDevice.pair(udid: udid) { return true }
        // Fallback
        let result = await Shell.runAsync("idevicepair", arguments: ["-u", udid, "pair"])
        if !result.succeeded { lastError = result.stderr.nilIfEmpty ?? result.output }
        return result.succeeded
    }

    /// Unpair a device.
    func unpairDevice(udid: String) async -> Bool {
        if await PyMobileDevice.unpair(udid: udid) { return true }
        return (await Shell.runAsync("idevicepair", arguments: ["-u", udid, "unpair"])).succeeded
    }

    /// Get device name.
    func getDeviceName(udid: String) async -> String? {
        if let name = await PyMobileDevice.deviceName(udid: udid) { return name }
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
        // Primary: pymobiledevice3
        if await PyMobileDevice.screenshot(udid: udid, saveTo: path) { return true }
        // Fallback
        return (await Shell.runAsync("idevicescreenshot", arguments: ["-u", udid, path])).succeeded
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
