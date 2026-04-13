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

    // Status
    var isPaired: Bool
    var isActivated: Bool

    var usedDiskSpace: UInt64? {
        guard let total = totalDiskCapacity, let free = availableDiskSpace else { return nil }
        return total - free
    }

    var diskUsagePercent: Double? {
        guard let total = totalDiskCapacity, let used = usedDiskSpace, total > 0 else { return nil }
        return Double(used) / Double(total) * 100
    }

    var displayModelName: String {
        let mapping: [String: String] = [
            "iPhone16,1": "iPhone 15 Pro",
            "iPhone16,2": "iPhone 15 Pro Max",
            "iPhone15,4": "iPhone 15",
            "iPhone15,5": "iPhone 15 Plus",
            "iPhone15,2": "iPhone 14 Pro",
            "iPhone15,3": "iPhone 14 Pro Max",
            "iPhone14,7": "iPhone 14",
            "iPhone14,8": "iPhone 14 Plus",
            "iPhone14,2": "iPhone 13 Pro",
            "iPhone14,3": "iPhone 13 Pro Max",
            "iPhone14,5": "iPhone 13",
            "iPhone14,4": "iPhone 13 mini",
            "iPhone17,1": "iPhone 16 Pro",
            "iPhone17,2": "iPhone 16 Pro Max",
            "iPhone17,3": "iPhone 16",
            "iPhone17,4": "iPhone 16 Plus",
            "iPhone17,5": "iPhone 16e",
            "iPad16,3": "iPad Pro M4 11\"",
            "iPad16,4": "iPad Pro M4 11\"",
            "iPad16,5": "iPad Pro M4 13\"",
            "iPad16,6": "iPad Pro M4 13\"",
        ]
        return mapping[productType] ?? model
    }

    var sfSymbolName: String {
        if productType.hasPrefix("iPad") { return "ipad" }
        if productType.hasPrefix("iPod") { return "ipodtouch" }
        return "iphone"
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
        isActivated: false
    )
}
