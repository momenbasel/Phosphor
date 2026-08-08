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
}
