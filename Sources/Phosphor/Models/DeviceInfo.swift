import Foundation

/// Represents a connected iOS device's information.
struct DeviceInfo: Identifiable, Hashable {
    let id: String // UDID
    var name: String
    var model: String
    var modelNumber: String
    var productType: String
    var iosVersion: String
    var buildVersion: String
    var serialNumber: String
    var wifiAddress: String
    var bluetoothAddress: String
    var phoneNumber: String?
    var imei: String?

    // Battery
    var batteryLevel: Int? // 0-100
    var batteryCharging: Bool?

    // Storage
    var totalDiskCapacity: UInt64?
    var availableDiskSpace: UInt64?
    var totalDataCapacity: UInt64?
    var totalSystemCapacity: UInt64?

    // Status
    var isPaired: Bool
    var isActivated: Bool

    // Hardware (from lockdown info)
    var chipID: String?
    var boardId: String?
    var hardwarePlatform: String?
    var hardwareModel: String?
    var cpuArchitecture: String?
    var firmwareVersion: String?
    var dieID: String?

    // Baseband / Modem
    var basebandVersion: String?
    var basebandChipID: String?
    var basebandSerialNumber: String?
    var basebandStatus: String?

    // Security
    var activationState: String?
    var isSupervised: Bool?
    var productionSOC: Bool?
    var hasPasscode: Bool?

    // Network
    var ethernetAddress: String?

    // Carrier
    var carrierName: String?
    var mobileCountryCode: String?
    var mobileNetworkCode: String?
    var iccid: String?

    // Connection
    var connectionType: ConnectionType

    enum ConnectionType: String {
        case usb = "USB"
        case wifi = "Wi-Fi"
        case unknown = "Unknown"
    }

    var usedDiskSpace: UInt64? {
        guard let total = totalDiskCapacity, let free = availableDiskSpace else { return nil }
        return total - free
    }

    var diskUsagePercent: Double? {
        guard let total = totalDiskCapacity, let used = usedDiskSpace, total > 0 else { return nil }
        return Double(used) / Double(total) * 100
    }

    var systemDiskUsage: UInt64? {
        guard let total = totalDiskCapacity, let data = totalDataCapacity else { return nil }
        return total > data ? total - data : nil
    }

    // Model name lookup covering iPhone 12 through 17, iPad Air/Pro M4, iPod touch
    var displayModelName: String {
        let mapping: [String: String] = [
            // iPhone 12 series
            "iPhone13,1": "iPhone 12 mini",
            "iPhone13,2": "iPhone 12",
            "iPhone13,3": "iPhone 12 Pro",
            "iPhone13,4": "iPhone 12 Pro Max",
            // iPhone 13 series
            "iPhone14,4": "iPhone 13 mini",
            "iPhone14,5": "iPhone 13",
            "iPhone14,2": "iPhone 13 Pro",
            "iPhone14,3": "iPhone 13 Pro Max",
            // iPhone SE 3rd gen
            "iPhone14,6": "iPhone SE (3rd gen)",
            // iPhone 14 series
            "iPhone14,7": "iPhone 14",
            "iPhone14,8": "iPhone 14 Plus",
            "iPhone15,2": "iPhone 14 Pro",
            "iPhone15,3": "iPhone 14 Pro Max",
            // iPhone 15 series
            "iPhone15,4": "iPhone 15",
            "iPhone15,5": "iPhone 15 Plus",
            "iPhone16,1": "iPhone 15 Pro",
            "iPhone16,2": "iPhone 15 Pro Max",
            // iPhone 16 series
            "iPhone17,1": "iPhone 16 Pro",
            "iPhone17,2": "iPhone 16 Pro Max",
            "iPhone17,3": "iPhone 16",
            "iPhone17,4": "iPhone 16 Plus",
            "iPhone17,5": "iPhone 16e",
            // iPhone 17 series (anticipated)
            "iPhone18,1": "iPhone 17",
            "iPhone18,2": "iPhone 17 Air",
            "iPhone18,3": "iPhone 17 Pro",
            "iPhone18,4": "iPhone 17 Pro Max",
            // iPad Pro M4
            "iPad16,3": "iPad Pro M4 11\"",
            "iPad16,4": "iPad Pro M4 11\"",
            "iPad16,5": "iPad Pro M4 13\"",
            "iPad16,6": "iPad Pro M4 13\"",
            // iPad Air M2
            "iPad14,8": "iPad Air M2 11\"",
            "iPad14,9": "iPad Air M2 11\"",
            "iPad14,10": "iPad Air M2 13\"",
            "iPad14,11": "iPad Air M2 13\"",
            // iPad mini 7th gen
            "iPad16,1": "iPad mini (7th gen)",
            "iPad16,2": "iPad mini (7th gen)",
            // iPad 10th gen
            "iPad13,18": "iPad (10th gen)",
            "iPad13,19": "iPad (10th gen)",
            // iPod touch
            "iPod9,1": "iPod touch (7th gen)",
        ]
        return mapping[productType] ?? model
    }

    var sfSymbolName: String {
        if productType.hasPrefix("iPad") { return "ipad" }
        if productType.hasPrefix("iPod") { return "ipodtouch" }
        return "iphone"
    }

    var activationColor: String {
        switch activationState {
        case "Activated": return "green"
        case "FactoryActivated": return "orange"
        case "Unactivated": return "red"
        default: return "secondary"
        }
    }

    static let placeholder = DeviceInfo(
        id: "0000-0000",
        name: "No Device",
        model: "Unknown",
        modelNumber: "",
        productType: "",
        iosVersion: "",
        buildVersion: "",
        serialNumber: "",
        wifiAddress: "",
        bluetoothAddress: "",
        isPaired: false,
        isActivated: false,
        connectionType: .unknown
    )
}
