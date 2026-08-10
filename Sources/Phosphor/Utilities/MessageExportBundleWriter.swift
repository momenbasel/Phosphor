import Darwin
import Foundation

/// Builds a complete multi-conversation export out of sight, then reveals it
/// with one final move so cancellation or writer failure cannot leave a partial
/// `Messages Export` folder behind.
enum MessageExportBundleWriter {
    struct Result {
        let count: Int
        let directory: URL
    }

    static func write(
        in parentDirectory: URL,
        directoryName: String = "Messages Export",
        populate: (URL) throws -> Int
    ) throws -> Result {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: parentDirectory, withIntermediateDirectories: true)

        return try withPublicationLock(in: parentDirectory) {
            let finalDirectory = availableDirectory(
                named: directoryName,
                in: parentDirectory,
                fileManager: fileManager
            )
            let stagingDirectory = parentDirectory.appendingPathComponent(
                ".\(finalDirectory.lastPathComponent).staging-\(UUID().uuidString)",
                isDirectory: true
            )
            try fileManager.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
            do {
                let count = try populate(stagingDirectory)
                // A successful same-parent move is the publication commit point:
                // the staging pathname no longer exists and must not be inspected
                // or removed after this succeeds.
                try fileManager.moveItem(at: stagingDirectory, to: finalDirectory)
                return Result(count: count, directory: finalDirectory)
            } catch {
                let exportError = error
                do {
                    try removeCurrentStagingDirectoryIfPresent(
                        stagingDirectory,
                        fileManager: fileManager
                    )
                } catch let cleanupFailure {
                    throw stagingCleanupError(
                        path: stagingDirectory.path,
                        exportError: exportError,
                        cleanupFailure: cleanupFailure
                    )
                }
                throw exportError
            }
        }
    }

    private static func removeCurrentStagingDirectoryIfPresent(
        _ stagingDirectory: URL,
        fileManager: FileManager
    ) throws {
        guard fileManager.fileExists(atPath: stagingDirectory.path) else { return }
        try fileManager.removeItem(at: stagingDirectory)
        guard !fileManager.fileExists(atPath: stagingDirectory.path) else {
            throw NSError(
                domain: "Phosphor.MessageExportBundleWriter",
                code: 2,
                userInfo: [
                    NSLocalizedDescriptionKey: "Phosphor could not verify removal of its active message-export staging folder.",
                    NSFilePathErrorKey: stagingDirectory.path
                ]
            )
        }
    }

    private static func availableDirectory(
        named directoryName: String,
        in parentDirectory: URL,
        fileManager: FileManager
    ) -> URL {
        var name = directoryName
        var suffix = 2
        while fileManager.fileExists(atPath: parentDirectory.appendingPathComponent(name).path) {
            name = "\(directoryName) \(suffix)"
            suffix += 1
        }
        return parentDirectory.appendingPathComponent(name, isDirectory: true)
    }

    /// Keep the name-selection and final move together across Phosphor
    /// processes. A persistent lock avoids the check-then-move race where two
    /// same-parent exports both choose the same collision-free folder name.
    private static func withPublicationLock<T>(
        in parentDirectory: URL,
        operation: () throws -> T
    ) throws -> T {
        let lockURL = parentDirectory.appendingPathComponent(
            ".phosphor-message-export-bundle.lock"
        )
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw posixError() }
        defer { close(descriptor) }

        guard flock(descriptor, LOCK_EX) == 0 else { throw posixError() }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try operation()
    }

    private static func stagingCleanupError(
        path: String,
        exportError: Error,
        cleanupFailure: Error
    ) -> NSError {
        NSError(
            domain: "Phosphor.MessageExportBundleWriter",
            code: 1,
            userInfo: [
                NSLocalizedDescriptionKey: "Message export failed and Phosphor could not remove its staging folder. The completed exports were not changed.",
                NSFilePathErrorKey: path,
                NSUnderlyingErrorKey: cleanupFailure,
                "PhosphorExportError": exportError.localizedDescription
            ]
        )
    }

    private static func posixError() -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
}
