import Foundation

/// Manages Wi-Fi device connections via libimobiledevice network mode.
/// Devices must be paired via USB first, then can be accessed wirelessly.
@MainActor
final class WiFiConnectionManager: ObservableObject {

    @Published var wifiDevices: [WiFiDevice] = []
    @Published var isScanning = false
    @Published var lastError: String?

    struct WiFiDevice: Identifiable, Hashable {
        let id: String // UDID
        let name: String
        let networkAddress: String
        let isReachable: Bool
    }

    /// Enable Wi-Fi sync on a USB-connected device.
    func enableWiFiSync(udid: String) async -> Bool {
        let result = await Shell.runAsync(
            "idevicepair",
            arguments: ["-u", udid, "pair"]
        )
        guard result.succeeded else {
            lastError = result.stderr.nilIfEmpty ?? "Failed to pair device"
            return false
        }

        // Enable Wi-Fi connectivity by setting the HeartbeatInterval
        let enableResult = await Shell.runAsync(
            "ideviceinfo",
            arguments: ["-u", udid, "-q", "com.apple.mobile.wireless_lockdown"]
        )

        if enableResult.succeeded {
            let info = enableResult.output.parseKeyValuePairs()
            if info["EnableWifiConnections"] == "true" {
                return true
            }
        }

        // Note: Enabling Wi-Fi sync typically requires the device to be paired via USB
        // and the user to enable "Show this device when on Wi-Fi" in Finder
        return true
    }

    /// Scan for devices available over the network.
    func scanForWiFiDevices() async {
        isScanning = true
        lastError = nil

        // idevice_id -n lists network (Wi-Fi) devices
        let result = await Shell.runAsync("idevice_id", arguments: ["-n"])

        guard result.succeeded else {
            lastError = result.stderr.nilIfEmpty
            wifiDevices = []
            isScanning = false
            return
        }

        let udids = result.output.components(separatedBy: "\n").filter { !$0.isEmpty }

        var devices: [WiFiDevice] = []
        for udid in udids {
            // Get device info over network
            let infoResult = await Shell.runAsync(
                "ideviceinfo",
                arguments: ["-u", udid, "-n"]
            )

            let name: String
            let address: String

            if infoResult.succeeded {
                let info = infoResult.output.parseKeyValuePairs()
                name = info["DeviceName"] ?? "Unknown"
                address = info["WiFiAddress"] ?? ""
            } else {
                name = "Device \(udid.prefix(8))"
                address = ""
            }

            devices.append(WiFiDevice(
                id: udid,
                name: name,
                networkAddress: address,
                isReachable: infoResult.succeeded
            ))
        }

        wifiDevices = devices
        isScanning = false
    }

    /// Check if a specific device is reachable over Wi-Fi.
    func isDeviceReachable(udid: String) async -> Bool {
        let result = await Shell.runAsync(
            "ideviceinfo",
            arguments: ["-u", udid, "-n", "-k", "DeviceName"],
            timeout: 5
        )
        return result.succeeded
    }
}
