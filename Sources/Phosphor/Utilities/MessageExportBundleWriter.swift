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
            var stagingExists = true
            defer {
                if stagingExists {
                    try? fileManager.removeItem(at: stagingDirectory)
                }
            }

            try fileManager.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
            let count = try populate(stagingDirectory)
            try fileManager.moveItem(at: stagingDirectory, to: finalDirectory)
            stagingExists = false
            return Result(count: count, directory: finalDirectory)
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

    private static func posixError() -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
}
