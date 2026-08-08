import Foundation
import Combine

/// Manages iOS device detection and information retrieval.
/// Lightweight discovery: libimobiledevice. Detailed info and compatibility fallback: pymobiledevice3.
@MainActor
final class DeviceManager: ObservableObject {

    @Published var connectedDevices: [DeviceInfo] = []
    @Published var nearbyWirelessDevices: [PyMobileDevice.BonjourDevice] = []
    @Published var selectedDevice: DeviceInfo?
    @Published var isScanning = false
    @Published var lastError: String?
    @Published var dependencyStatus: [String: Bool] = [:]

    private var pollTimer: Timer?
    private var deviceInfoCache: [String: (device: DeviceInfo, fetchedAt: Date)] = [:]
    private var batteryInfoCache: [String: (info: [String: String], fetchedAt: Date)] = [:]
    private var pairStatusCache: [String: (isPaired: Bool, fetchedAt: Date)] = [:]
    private var bonjourDeviceCache: (devices: [PyMobileDevice.BonjourDevice], fetchedAt: Date)?
    private var compatibilityOnlyDeviceCache = AuthoritativeSnapshotCache<PyMobileDevice.DeviceEntry>()
    private var networkDeviceGraceCache = NetworkDeviceGraceCache<DeviceInfo>(maxMissedScans: 1)
    private var compatibilityDiscoveryRetry = DiscoveryRetryBackoff(initialDelay: 5, maximumDelay: 30)
    private let compatibilityDiscoveryInterval: TimeInterval = 30
    private let deviceInfoRefreshInterval: TimeInterval = 30
    private let batteryInfoRefreshInterval: TimeInterval = 60
    private let pairStatusRefreshInterval: TimeInterval = 120
    private let bonjourDeviceRefreshInterval: TimeInterval = 30


    // MARK: - Dependency Check

    func checkDependencies() {
        Task {
            dependencyStatus = await ReadinessService.dependencyStatus()
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

    func scanForDevices(forceRefresh: Bool = false) async {
        if isScanning {
            guard forceRefresh else { return }
            while isScanning {
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        isScanning = true
        if forceRefresh || compatibilityDiscoveryRetry.consecutiveFailures == 0 {
            lastError = nil
        }
        defer { isScanning = false }

        // Routine polling uses libimobiledevice discovery because it is a tiny
        // native probe. Starting pymobiledevice3 twice every few seconds costs
        // substantially more CPU. Explicit refreshes and systems without both
        // idevice_id transports retain the full pymobiledevice3 compatibility path.
        let lightweightScan = await listLibimobiledeviceEntries()
        let scanStartedAt = Date()
        let compatibilityScanIsDue = compatibilityDiscoveryRetry.isDue(at: scanStartedAt)
        let discoveredEntries: [PyMobileDevice.DeviceEntry]
        var compatibilityProbeFailed = false
        var retainedCompatibilityDeviceIDs: Set<String> = []
        if forceRefresh || compatibilityScanIsDue {
            let pyDiscovery = await PyMobileDevice.discoverDevicesWithType()
            let discoveryCompletedAt = Date()
            // A default fallback without ConnectionType is useful as a hint but
            // cannot safely change a known Wi-Fi device into USB. Only explicit
            // transport observations may enter the rendered/cache snapshot.
            let pyEntries = pyDiscovery.entries.filter {
                $0.connectionType == "USB" || $0.connectionType == "Network"
            }
            compatibilityProbeFailed = !pyDiscovery.isAuthoritative
            if pyDiscovery.isAuthoritative {
                lastError = nil
                compatibilityDiscoveryRetry.recordSuccess(
                    at: discoveryCompletedAt,
                    regularInterval: compatibilityDiscoveryInterval
                )
            } else {
                compatibilityDiscoveryRetry.recordFailure(at: discoveryCompletedAt)
                lastError = pyDiscovery.failureDescription
            }

            if lightweightScan.isAvailable {
                let lightweightIDs = Set(lightweightScan.entries.map(\.udid))
                let currentCompatibilityEntries = pyEntries.filter { !lightweightIDs.contains($0.udid) }
                let cachedCompatibilityIDs = Set(compatibilityOnlyDeviceCache.values.map(\.udid))
                let compatibilityEntries = compatibilityOnlyDeviceCache.merge(
                    current: currentCompatibilityEntries.map { (id: $0.udid, value: $0) },
                    authoritative: pyDiscovery.isAuthoritative,
                    now: discoveryCompletedAt
                )
                if compatibilityProbeFailed {
                    let directlyObservedIDs = lightweightIDs.union(pyEntries.map(\.udid))
                    retainedCompatibilityDeviceIDs = Set(compatibilityEntries.map(\.udid))
                        .intersection(cachedCompatibilityIDs)
                        .subtracting(directlyObservedIDs)
                }
                discoveredEntries = mergeDeviceEntries(lightweightScan.entries + compatibilityEntries)
            } else {
                // The probe failed, so its UDID set is empty and cannot subtract
                // duplicates. pyEntries is already the whole picture for this poll;
                // caching it as compatibility-only would republish every USB device
                // as a phantom row for the next 30s once the probe recovers.
                if pyDiscovery.isAuthoritative {
                    compatibilityOnlyDeviceCache.reset()
                    discoveredEntries = mergeDeviceEntries(pyEntries)
                } else {
                    let cachedCompatibilityIDs = Set(compatibilityOnlyDeviceCache.values.map(\.udid))
                    let retainedEntries = compatibilityOnlyDeviceCache.merge(
                        current: [],
                        authoritative: false,
                        now: discoveryCompletedAt
                    )
                    retainedCompatibilityDeviceIDs = Set(retainedEntries.map(\.udid))
                        .intersection(cachedCompatibilityIDs)
                        .subtracting(pyEntries.map(\.udid))
                    discoveredEntries = mergeDeviceEntries(pyEntries + retainedEntries)
                }
            }
        } else {
            // Skipping an expensive probe during its normal interval/backoff is
            // not another failed discovery. Do not consume the cache's failure
            // budget on every lightweight UI poll.
            let retainedEntries = compatibilityOnlyDeviceCache.values
            if compatibilityDiscoveryRetry.consecutiveFailures > 0 {
                retainedCompatibilityDeviceIDs = Set(retainedEntries.map(\.udid))
                    .subtracting(lightweightScan.entries.map(\.udid))
            }
            discoveredEntries = mergeDeviceEntries(lightweightScan.entries + retainedEntries)
        }

        let visibleUDIDs = Set(discoveredEntries.map(\.udid))
        deviceInfoCache = deviceInfoCache.filter { visibleUDIDs.contains($0.key) }
        batteryInfoCache = batteryInfoCache.filter { visibleUDIDs.contains($0.key) }
        pairStatusCache = pairStatusCache.filter { visibleUDIDs.contains($0.key) }

        var currentDevices: [DeviceInfo] = []
        for entry in discoveredEntries {
            let connType: DeviceInfo.ConnectionType = entry.connectionType == "USB" ? .usb : .wifi
            if retainedCompatibilityDeviceIDs.contains(entry.udid),
               var cached = deviceInfoCache[entry.udid]?.device {
                cached.connectionType = connType
                currentDevices.append(cached)
                continue
            }
            if !forceRefresh,
               let cached = cachedDevice(udid: entry.udid, connectionType: connType) {
                currentDevices.append(cached)
                continue
            }
            if var device = await fetchDeviceInfo(
                udid: entry.udid,
                connectionType: connType,
                discoveryInfo: entry.discoveryInfo,
                forceRefresh: forceRefresh
            ) {
                device.connectionType = connType
                deviceInfoCache[entry.udid] = (device, Date())
                currentDevices.append(device)
            }
        }

        // A Wi-Fi device can vanish from usbmux or fail a metadata query for one
        // poll while iOS changes power or network state. Retain the last rendered
        // network snapshot through one routine miss so the selected row does not
        // flicker every four seconds. USB devices still disappear immediately. An
        // explicit refresh bypasses grace after an authoritative scan, but a probe
        // failure cannot be misreported as an authoritative disconnect.
        if forceRefresh && !compatibilityProbeFailed { networkDeviceGraceCache.reset() }
        let currentUSBDeviceIDs = Set(
            discoveredEntries.filter { $0.connectionType == "USB" }.map(\.udid)
        )
        networkDeviceGraceCache.remove(ids: currentUSBDeviceIDs)
        let currentNetworkDevices = currentDevices
            .filter { $0.connectionType == .wifi }
            .map { (id: $0.id, value: $0) }
        let stableNetworkDevices = networkDeviceGraceCache.merge(current: currentNetworkDevices)
        let devices = currentDevices.filter { $0.connectionType == .usb } + stableNetworkDevices

        if devices.isEmpty {
            nearbyWirelessDevices = await cachedBonjourDevices(forceRefresh: forceRefresh)
            connectedDevices = []
            selectedDevice = nil
            deviceInfoCache.removeAll()
            batteryInfoCache.removeAll()
            pairStatusCache.removeAll()
            return
        }

        nearbyWirelessDevices = []
        connectedDevices = devices
        if let selectedID = selectedDevice?.id,
           let refreshedSelection = devices.first(where: { $0.id == selectedID }) {
            selectedDevice = refreshedSelection
        } else {
            selectedDevice = devices.first
        }
    }

    private func cachedBonjourDevices(forceRefresh: Bool = false) async -> [PyMobileDevice.BonjourDevice] {
        if !forceRefresh,
           let cached = bonjourDeviceCache,
           Date().timeIntervalSince(cached.fetchedAt) < bonjourDeviceRefreshInterval {
            return cached.devices
        }
        let devices = await PyMobileDevice.listBonjourMobileDevices()
        bonjourDeviceCache = (devices, Date())
        return devices
    }

    private struct LibimobiledeviceScan {
        let isAvailable: Bool
        let entries: [PyMobileDevice.DeviceEntry]
    }

    private func listLibimobiledeviceEntries() async -> LibimobiledeviceScan {
        async let usbResult = Shell.runAsync("idevice_id", arguments: ["-l"], timeout: 5)
        async let networkResult = Shell.runAsync("idevice_id", arguments: ["-n"], timeout: 5)

        var entries: [PyMobileDevice.DeviceEntry] = []
        let usb = await usbResult
        if usb.succeeded {
            entries += parseLibimobiledeviceUDIDs(usb.output, connectionType: "USB")
        }

        let network = await networkResult
        if network.succeeded {
            entries += parseLibimobiledeviceUDIDs(network.output, connectionType: "Network")
        }

        // Availability keys on the USB probe alone. Some libimobiledevice builds
        // ship an idevice_id that rejects -n, and requiring both to exit 0 would
        // make every poll fall through to pymobiledevice3 forever, which is the
        // cost this path exists to avoid. Network-only devices are still picked up
        // by the periodic compatibility scan.
        return LibimobiledeviceScan(
            isAvailable: usb.succeeded,
            entries: mergeDeviceEntries(entries)
        )
    }

    private func parseLibimobiledeviceUDIDs(_ output: String, connectionType: String) -> [PyMobileDevice.DeviceEntry] {
        output.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { PyMobileDevice.DeviceEntry(udid: $0, connectionType: connectionType) }
    }

    private func mergeDeviceEntries(_ entries: [PyMobileDevice.DeviceEntry]) -> [PyMobileDevice.DeviceEntry] {
        var byUdid: [String: PyMobileDevice.DeviceEntry] = [:]
        var orderedUdids: [String] = []

        for entry in entries {
            if byUdid[entry.udid] == nil { orderedUdids.append(entry.udid) }
            if byUdid[entry.udid]?.connectionType != "USB" || entry.connectionType == "USB" {
                byUdid[entry.udid] = entry
            }
        }

        return orderedUdids.compactMap { byUdid[$0] }
    }

    private func cachedDevice(udid: String, connectionType: DeviceInfo.ConnectionType) -> DeviceInfo? {
        guard let cached = deviceInfoCache[udid],
              Date().timeIntervalSince(cached.fetchedAt) < deviceInfoRefreshInterval else {
            return nil
        }
        var device = cached.device
        device.connectionType = connectionType
        return device
    }

    /// Fetch detailed info for a specific device.
    func fetchDeviceInfo(
        udid: String,
        connectionType: DeviceInfo.ConnectionType = .usb,
        discoveryInfo: [String: String] = [:],
        forceRefresh: Bool = false
    ) async -> DeviceInfo? {
        if !discoveryInfo.isEmpty {
            return deviceInfo(fromDiscoveryInfo: discoveryInfo, udid: udid, connectionType: connectionType)
        }

        // Primary: pymobiledevice3
        let info = await PyMobileDevice.deviceInfo(udid: udid)
        if !info.isEmpty {
            let batteryInfo = await cachedBatteryInfo(udid: udid, forceRefresh: forceRefresh)
            let isPaired = await cachedPymobiledevicePairStatus(udid: udid, forceRefresh: forceRefresh)

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
                connectionType: connectionType
            )
        }

        // Fallback: libimobiledevice
        let networkArgs = connectionType == .wifi ? ["-n"] : []
        let result = await Shell.runAsync("ideviceinfo", arguments: ["-u", udid] + networkArgs)
        guard result.succeeded else { return nil }

        let liInfo = result.output.parseKeyValuePairs()
        let batteryResult = await Shell.runAsync("ideviceinfo", arguments: ["-u", udid] + networkArgs + ["-q", "com.apple.mobile.battery"])
        let batteryInfo = batteryResult.output.parseKeyValuePairs()
        let diskResult = await Shell.runAsync("ideviceinfo", arguments: ["-u", udid] + networkArgs + ["-q", "com.apple.disk_usage"])
        let diskInfo = diskResult.output.parseKeyValuePairs()
        let isPaired = await cachedLibimobiledevicePairStatus(udid: udid, forceRefresh: forceRefresh)

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
            isPaired: isPaired,
            isActivated: liInfo["ActivationState"] == "Activated",
            basebandVersion: liInfo["BasebandVersion"],
            activationState: liInfo["ActivationState"],
            connectionType: connectionType
        )
    }

    private func deviceInfo(
        fromDiscoveryInfo info: [String: String],
        udid: String,
        connectionType: DeviceInfo.ConnectionType
    ) -> DeviceInfo {
        DeviceInfo(
            id: udid,
            name: info["DeviceName"] ?? "Wireless iPhone/iPad",
            model: info["ProductType"] ?? info["DeviceClass"] ?? "Unknown",
            modelNumber: info["ModelNumber"] ?? "",
            productType: info["ProductType"] ?? "",
            iosVersion: info["ProductVersion"] ?? "",
            buildVersion: info["BuildVersion"] ?? "",
            serialNumber: info["SerialNumber"] ?? "",
            wifiAddress: info["WiFiAddress"] ?? info["ip"] ?? info["Identifier"] ?? "",
            bluetoothAddress: info["BluetoothAddress"] ?? "",
            isPaired: true,
            isActivated: info["ActivationState"].map { $0 == "Activated" } ?? true,
            activationState: info["ActivationState"],
            connectionType: connectionType
        )
    }

    private func cachedBatteryInfo(udid: String, forceRefresh: Bool = false) async -> [String: String] {
        if !forceRefresh,
           let cached = batteryInfoCache[udid],
           Date().timeIntervalSince(cached.fetchedAt) < batteryInfoRefreshInterval {
            return cached.info
        }
        let info = await PyMobileDevice.batteryInfo(udid: udid)
        batteryInfoCache[udid] = (info, Date())
        return info
    }

    private func cachedPymobiledevicePairStatus(udid: String, forceRefresh: Bool = false) async -> Bool {
        if !forceRefresh,
           let cached = pairStatusCache[udid],
           Date().timeIntervalSince(cached.fetchedAt) < pairStatusRefreshInterval {
            return cached.isPaired
        }
        let isPaired = await PyMobileDevice.validatePair(udid: udid)
        pairStatusCache[udid] = (isPaired, Date())
        return isPaired
    }

    private func cachedLibimobiledevicePairStatus(udid: String, forceRefresh: Bool = false) async -> Bool {
        if !forceRefresh,
           let cached = pairStatusCache[udid],
           Date().timeIntervalSince(cached.fetchedAt) < pairStatusRefreshInterval {
            return cached.isPaired
        }
        let result = await Shell.runAsync("idevicepair", arguments: ["-u", udid, "validate"])
        pairStatusCache[udid] = (result.succeeded, Date())
        return result.succeeded
    }

    /// Pair with a device.
    func pairDevice(udid: String) async -> Bool {
        pairStatusCache.removeValue(forKey: udid)
        // Primary: pymobiledevice3
        if await PyMobileDevice.pair(udid: udid) {
            pairStatusCache[udid] = (true, Date())
            deviceInfoCache.removeValue(forKey: udid)
            return true
        }
        // Fallback
        let result = await Shell.runAsync("idevicepair", arguments: ["-u", udid, "pair"])
        if result.succeeded {
            pairStatusCache[udid] = (true, Date())
            deviceInfoCache.removeValue(forKey: udid)
        } else {
            lastError = result.stderr.nilIfEmpty ?? result.output
        }
        return result.succeeded
    }

    /// Enable Finder-style Wi-Fi connections for a trusted USB-connected device.
    func enableWiFiConnections(udid: String) async -> Bool {
        lastError = nil

        let firstAttempt = await PyMobileDevice.setWiFiConnections(udid: udid, enabled: true)
        if firstAttempt.succeeded {
            invalidateConnectionCaches(for: udid)
            return true
        }

        // If the device is plugged in but not fully paired yet, pairing can surface
        // the trust flow. Retry the actual Wi-Fi setting afterwards; pairing alone
        // is not enough to match Finder's Wi-Fi checkbox.
        if await PyMobileDevice.pair(udid: udid) {
            let retry = await PyMobileDevice.setWiFiConnections(udid: udid, enabled: true)
            if retry.succeeded {
                pairStatusCache[udid] = (true, Date())
                invalidateConnectionCaches(for: udid)
                return true
            }
            lastError = retry.stderr.nilIfEmpty ?? retry.output.nilIfEmpty ?? "Failed to enable Wi-Fi connections."
            return false
        }

        lastError = firstAttempt.stderr.nilIfEmpty
            ?? firstAttempt.output.nilIfEmpty
            ?? "Connect the device over USB, unlock it, tap Trust, then try enabling Wi-Fi again."
        return false
    }

    private func invalidateConnectionCaches(for udid: String) {
        deviceInfoCache.removeValue(forKey: udid)
        bonjourDeviceCache = nil
    }

    /// Unpair a device.
    func unpairDevice(udid: String) async -> Bool {
        pairStatusCache.removeValue(forKey: udid)
        var success = await PyMobileDevice.unpair(udid: udid)
        if !success {
            success = (await Shell.runAsync("idevicepair", arguments: ["-u", udid, "unpair"])).succeeded
        }
        if success {
            pairStatusCache[udid] = (false, Date())
            deviceInfoCache.removeValue(forKey: udid)
        }
        return success
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
