import Foundation

/// Normalizes usbmux connection metadata without inventing transport provenance.
enum UsbmuxConnectionType {
    static func normalize(_ rawValue: String?, default defaultConnectionType: String) -> String {
        guard let rawValue else { return defaultConnectionType }

        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized == "1" || normalized.contains("usb") {
            return "USB"
        }
        if normalized == "2" || normalized.contains("network") || normalized.contains("wifi") || normalized.contains("wi-fi") {
            return "Network"
        }
        return defaultConnectionType
    }
}
