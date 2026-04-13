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
}
