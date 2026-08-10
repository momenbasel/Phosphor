import Foundation

/// Copies original message attachments into collision-safe directories.
///
/// Single-transcript exports publish a fresh immutable generation before their
/// transcript is replaced. The transcript embeds that generation's relative
/// name, so an interrupted process can only leave an unreferenced orphan; it
/// cannot make a completed transcript point at moved or replaced sidecars.
enum MessageAttachmentExporter {
    struct Item {
        let key: String
        let displayName: String
        let sourcePath: String
    }

    /// A sidecar generation that has been made visible but is not necessarily
    /// referenced by a committed transcript yet.
    struct Generation {
        let directoryURL: URL?
        let paths: [String: String]
        fileprivate let exportURL: URL
    }

    /// Copy originals into a unique, immutable generation beside an export.
    /// The caller must either commit the transcript containing `paths` or call
    /// `discard(_:)`; successful transcript publication calls
    /// `cleanupObsoleteGenerations(for:)` afterwards.
    static func prepareGeneration(
        _ items: [Item],
        beside exportPath: String,
        cancellationCheck: (() throws -> Void)? = nil
    ) throws -> Generation {
        let fileManager = FileManager.default
        let exportURL = URL(fileURLWithPath: exportPath)
        guard !items.isEmpty else {
            return Generation(directoryURL: nil, paths: [:], exportURL: exportURL)
        }

        let parentURL = exportURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: parentURL, withIntermediateDirectories: true)
        let generationName = "\(sidecarBaseName(for: exportURL))-\(UUID().uuidString)"
        let generationURL = parentURL.appendingPathComponent(generationName, isDirectory: true)
        let stagingURL = parentURL.appendingPathComponent(
            ".\(generationName).staging-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? fileManager.removeItem(at: stagingURL) }

        try fileManager.createDirectory(at: stagingURL, withIntermediateDirectories: true)
        var exportedPaths: [String: String] = [:]
        for item in items {
            try cancellationCheck?()
            guard exportedPaths[item.key] == nil else { continue }

            let baseName = safeFilename(item.displayName)
            let uniqueName = availableFilename(baseName, in: stagingURL, fileManager: fileManager)
            let destinationURL = stagingURL.appendingPathComponent(uniqueName)
            try fileManager.copyItem(at: URL(fileURLWithPath: item.sourcePath), to: destinationURL)
            exportedPaths[item.key] = "\(generationName)/\(uniqueName)"
        }
        try cancellationCheck?()
        try fileManager.moveItem(at: stagingURL, to: generationURL)
        return Generation(directoryURL: generationURL, paths: exportedPaths, exportURL: exportURL)
    }

    /// Remove a sidecar generation that was published but never referenced by a
    /// committed transcript. Errors are deliberately best-effort during the
    /// caller's failure path; an unreferenced generation is safe to recover.
    static func discard(_ generation: Generation) {
        guard let directoryURL = generation.directoryURL else { return }
        try? FileManager.default.removeItem(at: directoryURL)
    }

    /// Reclaim sidecars from completed exports only after the transcript commit.
    /// Cleanup intentionally tolerates crashes and deletion failures: stale
    /// generations are harmless because every transcript names its own one.
    static func cleanupObsoleteGenerations(for generation: Generation) {
        let fileManager = FileManager.default
        let exportURL = generation.exportURL
        let parentURL = exportURL.deletingLastPathComponent()
        let currentURL = generation.directoryURL
        let baseName = sidecarBaseName(for: exportURL)
        let generationPrefix = "\(baseName)-"
        let legacyNames = legacySidecarNames(for: exportURL)

        guard let entries = try? fileManager.contentsOfDirectory(
            at: parentURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for entry in entries {
            let name = entry.lastPathComponent
            // Only ever delete a directory this exporter created. Generations
            // are named "<base>-<UUID>", so require the suffix to actually parse
            // as a UUID rather than accepting any name that merely starts with
            // "<base>-". Bare prefix-matching recursively removed the user's own
            // folders: exporting Trip.html into a directory that already held a
            // folder named "Trip-notes" destroyed it, unprompted.
            //
            // The legacy names stay eligible. Unlike the open-ended prefix they
            // are exact matches on the sidecar name Phosphor itself generated
            // for this very export path in an older version, so cleaning them is
            // what lets an upgrade tidy up after itself.
            let isGeneration = name.hasPrefix(generationPrefix)
                && UUID(uuidString: String(name.dropFirst(generationPrefix.count))) != nil
            guard isGeneration || legacyNames.contains(name) else { continue }
            guard entry.standardizedFileURL.path != currentURL?.standardizedFileURL.path else { continue }
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: entry.path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            try? fileManager.removeItem(at: entry)
        }
    }

    /// Export to a caller-selected unpublished folder. Multi-format bundles use
    /// this while their enclosing bundle root is still private staging state.
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
        defer { try? fileManager.removeItem(at: stagingURL) }

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

    private static func sidecarBaseName(for exportURL: URL) -> String {
        let baseName = exportURL.deletingPathExtension().lastPathComponent
        let formatSuffix = exportURL.pathExtension.lowercased()
        return formatSuffix.isEmpty
            ? "\(baseName)_attachments"
            : "\(baseName)-\(formatSuffix)_attachments"
    }

    private static func legacySidecarNames(for exportURL: URL) -> Set<String> {
        let baseName = exportURL.deletingPathExtension().lastPathComponent
        let formatSuffix = exportURL.pathExtension.lowercased()
        var names = [sidecarBaseName(for: exportURL)]
        if formatSuffix == "html" {
            names.append("\(baseName)_attachments")
        }
        return Set(names)
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
