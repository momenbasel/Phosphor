import Foundation

/// Copies original message attachments into a collision-safe sibling folder.
/// Work is staged before replacing a previous completed sidecar so cancellation
/// never leaves users with a partially refreshed attachment export.
enum MessageAttachmentExporter {
    struct Item {
        let key: String
        let displayName: String
        let sourcePath: String
    }

    static func export(
        _ items: [Item],
        beside exportPath: String,
        cancellationCheck: (() throws -> Void)? = nil
    ) throws -> [String: String] {
        let fileManager = FileManager.default
        let exportURL = URL(fileURLWithPath: exportPath)
        let parentURL = exportURL.deletingLastPathComponent()
        let baseName = exportURL.deletingPathExtension().lastPathComponent
        let formatSuffix = exportURL.pathExtension.lowercased()
        let sidecarName = formatSuffix.isEmpty
            ? "\(baseName)_attachments"
            : "\(baseName)-\(formatSuffix)_attachments"
        let sidecarURL = parentURL.appendingPathComponent(sidecarName, isDirectory: true)
        let exportedPaths = try export(items, to: sidecarURL, cancellationCheck: cancellationCheck)

        // Older Phosphor HTML exports used `<base>_attachments`. Remove that
        // stale sidecar only after the new format-isolated export succeeds.
        if formatSuffix == "html" {
            let legacySidecarURL = parentURL.appendingPathComponent("\(baseName)_attachments", isDirectory: true)
            if legacySidecarURL != sidecarURL {
                try? fileManager.removeItem(at: legacySidecarURL)
            }
        }

        return exportedPaths
    }

    /// Export to a caller-selected folder. Multi-format bundles use this to
    /// share one `Attachments` directory across every transcript in a chat.
    static func export(
        _ items: [Item],
        to directoryURL: URL,
        cancellationCheck: (() throws -> Void)? = nil
    ) throws -> [String: String] {
        let fileManager = FileManager.default
        let parentURL = directoryURL.deletingLastPathComponent()
        let directoryName = directoryURL.lastPathComponent
        let stagingURL = parentURL.appendingPathComponent(
            ".\(directoryName).staging-\(UUID().uuidString)",
            isDirectory: true
        )
        defer {
            try? fileManager.removeItem(at: stagingURL)
        }

        var exportedPaths: [String: String] = [:]
        if !items.isEmpty {
            try fileManager.createDirectory(at: stagingURL, withIntermediateDirectories: true)
        }

        for item in items {
            try cancellationCheck?()
            guard exportedPaths[item.key] == nil else { continue }

            let baseName = safeFilename(item.displayName)
            let uniqueName = availableFilename(baseName, in: stagingURL, fileManager: fileManager)
            let destinationURL = stagingURL.appendingPathComponent(uniqueName)
            try fileManager.copyItem(at: URL(fileURLWithPath: item.sourcePath), to: destinationURL)
            exportedPaths[item.key] = "\(directoryName)/\(uniqueName)"
        }
        try cancellationCheck?()

        if items.isEmpty {
            if fileManager.fileExists(atPath: directoryURL.path) {
                try fileManager.removeItem(at: directoryURL)
            }
        } else if fileManager.fileExists(atPath: directoryURL.path) {
            _ = try fileManager.replaceItemAt(directoryURL, withItemAt: stagingURL)
        } else {
            try fileManager.moveItem(at: stagingURL, to: directoryURL)
        }

        return exportedPaths
    }

    /// Encode each filename segment for use in HTML src/href attributes while
    /// retaining the sidecar directory separator.
    static func relativeURL(for relativePath: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#%")
        return relativePath
            .split(separator: "/", omittingEmptySubsequences: false)
            .map { segment in
                String(segment).addingPercentEncoding(withAllowedCharacters: allowed) ?? String(segment)
            }
            .joined(separator: "/")
    }

    private static func safeFilename(_ displayName: String) -> String {
        let candidate = (displayName as NSString).lastPathComponent
        if candidate.isEmpty || candidate == "." || candidate == ".." {
            return "Attachment"
        }
        return candidate
    }

    private static func availableFilename(
        _ filename: String,
        in directory: URL,
        fileManager: FileManager
    ) -> String {
        var candidate = filename
        var suffix = 2
        while fileManager.fileExists(atPath: directory.appendingPathComponent(candidate).path) {
            let name = filename as NSString
            let ext = name.pathExtension
            let stem = name.deletingPathExtension
            candidate = ext.isEmpty ? "\(stem)-\(suffix)" : "\(stem)-\(suffix).\(ext)"
            suffix += 1
        }
        return candidate
    }
}
