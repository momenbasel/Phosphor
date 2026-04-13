import Foundation

/// Creates and imports .phosphor backup archives.
/// A .phosphor file is a tar.gz compressed archive of an iOS backup directory,
/// similar to how iMazing uses .imazing files for portable backup storage.
enum BackupArchiver {

    static let fileExtension = "phosphor"
    static let mimeType = "application/x-phosphor-backup"

    struct ArchiveInfo {
        let deviceName: String
        let modelName: String
        let iosVersion: String
        let backupDate: Date?
        let isEncrypted: Bool
        let originalSize: UInt64
        let archiveSize: UInt64
    }

    // MARK: - Archive (Export)

    /// Create a .phosphor archive from a backup directory.
    /// Returns the path to the created archive, or nil on failure.
    static func createArchive(
        from backup: BackupInfo,
        to destinationDir: String,
        onProgress: @escaping (String) -> Void
    ) async -> String? {
        let fm = FileManager.default

        // Sanitize name for filename
        let safeName = backup.deviceName
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "/", with: "-")

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd_HHmmss"
        let dateStr = dateFormatter.string(from: backup.lastBackupDate ?? Date())

        let archiveName = "\(safeName)_\(dateStr).\(fileExtension)"
        let archivePath = (destinationDir as NSString).appendingPathComponent(archiveName)

        // Remove existing file
        try? fm.removeItem(atPath: archivePath)

        onProgress("Compressing backup...")

        // Use tar to create archive - fast and preserves all metadata
        let backupDir = (backup.path as NSString).lastPathComponent
        let parentDir = (backup.path as NSString).deletingLastPathComponent

        let result = await Shell.runAsync(
            "tar",
            arguments: ["-czf", archivePath, "-C", parentDir, backupDir],
            timeout: 600 // 10 min for large backups
        )

        if result.succeeded {
            onProgress("Archive created: \(archiveName)")
            return archivePath
        } else {
            onProgress("Archive failed: \(result.stderr)")
            return nil
        }
    }

    // MARK: - Import

    /// Import a .phosphor archive to the default backup location.
    /// Returns the path to the extracted backup directory, or nil on failure.
    static func importArchive(
        from archivePath: String,
        to backupDir: String? = nil,
        onProgress: @escaping (String) -> Void
    ) async -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let defaultDir = "\(home)/Library/Application Support/MobileSync/Backup"
        let destination = backupDir ?? defaultDir
        let fm = FileManager.default

        // Ensure destination exists
        try? fm.createDirectory(atPath: destination, withIntermediateDirectories: true)

        // Snapshot existing directories BEFORE extraction to detect new ones
        let existingDirs = Set(fm.sortedContents(atPath: destination))

        onProgress("Extracting backup archive...")

        let result = await Shell.runAsync(
            "tar",
            arguments: ["-xzf", archivePath, "-C", destination],
            timeout: 600
        )

        if result.succeeded {
            onProgress("Import complete")

            // Find newly extracted directory by diffing against snapshot
            let currentDirs = Set(fm.sortedContents(atPath: destination))
            let newDirs = currentDirs.subtracting(existingDirs)

            // Check each new directory for Info.plist (valid backup)
            for item in newDirs {
                let itemPath = (destination as NSString).appendingPathComponent(item)
                let infoPlist = (itemPath as NSString).appendingPathComponent("Info.plist")
                if fm.fileExists(atPath: infoPlist) {
                    return itemPath
                }
            }

            // Fallback: scan all for valid backup
            for item in currentDirs {
                let itemPath = (destination as NSString).appendingPathComponent(item)
                let infoPlist = (itemPath as NSString).appendingPathComponent("Info.plist")
                if fm.fileExists(atPath: infoPlist) && !existingDirs.contains(item) {
                    return itemPath
                }
            }
            return nil
        } else {
            onProgress("Import failed: \(result.stderr)")
            return nil
        }
    }

    // MARK: - Inspect

    /// Get info from a .phosphor archive without fully extracting it.
    static func inspectArchive(at path: String) async -> ArchiveInfo? {
        let fm = FileManager.default

        // Get archive size
        let archiveSize = (try? fm.attributesOfItem(atPath: path)[.size] as? UInt64) ?? 0

        // List contents to find Info.plist
        let listResult = await Shell.runAsync("tar", arguments: ["-tzf", path])
        guard listResult.succeeded else { return nil }

        let files = listResult.output.components(separatedBy: "\n")
        guard let infoPlistEntry = files.first(where: { $0.hasSuffix("Info.plist") && !$0.contains("/") || $0.components(separatedBy: "/").count == 2 && $0.hasSuffix("Info.plist") }) else {
            return nil
        }

        // Extract Info.plist to temp
        let tmpDir = NSTemporaryDirectory() + "phosphor-inspect-\(UUID().uuidString.prefix(8))"
        try? fm.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: tmpDir) }

        let extractResult = await Shell.runAsync(
            "tar",
            arguments: ["-xzf", path, "-C", tmpDir, infoPlistEntry]
        )
        guard extractResult.succeeded else { return nil }

        // Parse Info.plist
        let extractedPath = (tmpDir as NSString).appendingPathComponent(infoPlistEntry)
        let parentDir = (extractedPath as NSString).deletingLastPathComponent

        guard let info = PlistParser.parseBackupInfo(parentDir) else { return nil }

        // Estimate original size from tar listing
        let sizeResult = await Shell.runAsync("tar", arguments: ["-tvzf", path])
        var originalSize: UInt64 = 0
        if sizeResult.succeeded {
            for line in sizeResult.output.components(separatedBy: "\n") {
                let parts = line.split(separator: " ").map(String.init)
                // tar -v output has size at index 2 or 4 depending on format
                for part in parts {
                    if let size = UInt64(part), size > 100 {
                        originalSize += size
                        break
                    }
                }
            }
        }

        return ArchiveInfo(
            deviceName: info.deviceName,
            modelName: info.modelName,
            iosVersion: info.productVersion,
            backupDate: info.lastBackupDate,
            isEncrypted: info.isEncrypted,
            originalSize: originalSize,
            archiveSize: archiveSize
        )
    }

    // MARK: - Validation

    /// Check if a file is a valid .phosphor archive.
    static func isValidArchive(at path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        guard ext == fileExtension else { return false }
        return FileManager.default.fileExists(atPath: path)
    }
}
