import Foundation
import SwiftUI

// MARK: - Date Formatting

extension Date {
    var relativeString: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: self, relativeTo: Date())
    }

    var shortString: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: self)
    }

    var iso8601String: String {
        let formatter = ISO8601DateFormatter()
        return formatter.string(from: self)
    }
}

// MARK: - File Size Formatting

extension Int {
    var formattedFileSize: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(self))
    }
}

extension Int64 {
    var formattedFileSize: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: self)
    }
}

extension UInt64 {
    var formattedFileSize: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(self))
    }
}

// MARK: - String Helpers

extension String {
    /// Parse "key: value" lines from ideviceinfo output.
    func parseKeyValuePairs(separator: String = ":") -> [String: String] {
        var result: [String: String] = [:]
        for line in components(separatedBy: "\n") {
            let parts = line.split(separator: Character(separator), maxSplits: 1)
            if parts.count == 2 {
                let key = String(parts[0]).trimmingCharacters(in: .whitespaces)
                let value = String(parts[1]).trimmingCharacters(in: .whitespaces)
                result[key] = value
            }
        }
        return result
    }

    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

// MARK: - FileManager Helpers

extension FileManager {
    func directorySize(at path: String) -> UInt64 {
        var totalSize: UInt64 = 0
        guard let enumerator = enumerator(atPath: path) else { return 0 }
        while let file = enumerator.nextObject() as? String {
            let fullPath = (path as NSString).appendingPathComponent(file)
            if let attrs = try? attributesOfItem(atPath: fullPath),
               let size = attrs[.size] as? UInt64 {
                totalSize += size
            }
        }
        return totalSize
    }

    func sortedContents(atPath path: String) -> [String] {
        (try? contentsOfDirectory(atPath: path))?.sorted() ?? []
    }
}

// MARK: - Backup Validation

extension BackupInfo {
    /// Check if this backup has a complete Manifest.db for data browsing.
    var hasManifest: Bool {
        FileManager.default.fileExists(atPath: (path as NSString).appendingPathComponent("Manifest.db"))
    }

    /// User-friendly message when backup is incomplete.
    static let incompleteBackupMessage = "Backup is incomplete (no Manifest.db). Create a full backup first. If using iOS 17+, run: pip3 install pymobiledevice3"
}

// MARK: - View Modifiers

struct CardStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding()
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

extension View {
    func cardStyle() -> some View {
        modifier(CardStyle())
    }
}

// MARK: - Color Helpers

extension Color {
    static let phosphorAccent = Color.indigo
    static let phosphorSecondary = Color.purple
    static let phosphorSuccess = Color.green
    static let phosphorWarning = Color.orange
    static let phosphorDanger = Color.red
    static let phosphorMuted = Color.secondary

    /// Shared battery level color. Green when charging, red <=20, orange <=40, green otherwise.
    static func batteryColor(level: Int, charging: Bool) -> Color {
        if charging { return .green }
        if level <= 20 { return .red }
        if level <= 40 { return .orange }
        return .green
    }

    /// Temperature color: blue < 20C, green 20-35C, red > 35C.
    static func temperatureColor(_ celsius: Double) -> Color {
        if celsius < 20 { return .blue }
        if celsius <= 35 { return .green }
        return .red
    }
}

// MARK: - Tunnel Service

enum TunnelService {
    /// Check if tunneld process is running.
    static var isRunning: Bool {
        let result = Shell.run("pgrep", arguments: ["-f", "tunneld"])
        return result.succeeded
    }

    /// Start tunneld with admin privileges via osascript. Shows password dialog.
    static func start() {
        let pyPath = PyMobileDevice.findBinaryPath() ?? "pymobiledevice3"
        let script = "do shell script \"\(pyPath) remote tunneld &\" with administrator privileges"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        try? process.run()
    }
}

// MARK: - App Version

enum AppVersion {
    static var current: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "2.1"
    }

    static var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "2"
    }
}

// MARK: - Clipboard

extension String {
    func copyToClipboard() {
        #if canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(self, forType: .string)
        #endif
    }
}
