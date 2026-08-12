import Darwin
import Foundation

/// Publishes one generated/extracted file without overwriting an existing user
/// file or exposing a partially written destination. The writer uses a hidden
/// sibling staging file; `renamex_np(..., RENAME_EXCL)` makes the finished file
/// visible atomically and retries suffixes if another process wins the name.
enum CollisionSafeFilePublisher {
    static func publish(
        preferredFilename: String,
        in directory: URL,
        writer: (URL) throws -> Void
    ) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)

        let staging = directory.appendingPathComponent(".phosphor-\(UUID().uuidString).tmp")
        var published = false
        defer {
            if !published { try? fm.removeItem(at: staging) }
        }

        try writer(staging)
        try Task.checkCancellation()

        var info = stat()
        guard lstat(staging.path, &info) == 0 else {
            throw CocoaError(.fileNoSuchFile)
        }
        guard (info.st_mode & S_IFMT) == S_IFREG else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }

        let name = filenameParts(preferredFilename)
        for index in 1...100_000 {
            let suffix = index == 1 ? "" : " (\(index))"
            let candidateName = name.ext.isEmpty
                ? "\(name.stem)\(suffix)"
                : "\(name.stem)\(suffix).\(name.ext)"
            let candidate = directory.appendingPathComponent(candidateName)
            let result = staging.path.withCString { source in
                candidate.path.withCString { destination in
                    renamex_np(source, destination, UInt32(RENAME_EXCL))
                }
            }
            if result == 0 {
                published = true
                return candidate
            }
            let code = errno
            if code == EEXIST { continue }
            if code == ENOTSUP || code == EINVAL {
                // renamex_np is APFS/HFS+ only. exFAT, MS-DOS and SMB return
                // ENOTSUP, which is the normal case for extracting music to a
                // USB stick or a NAS share - the whole point of the feature.
                // Reserve the name with an exclusive create (which those
                // filesystems do support) and rename over our own reservation,
                // the same fallback FlatPhotoExportReservation uses.
                let reserved = candidate.path.withCString { path in
                    Darwin.open(path, O_CREAT | O_EXCL | O_WRONLY, 0o644)
                }
                if reserved < 0 {
                    if errno == EEXIST { continue }
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                close(reserved)
                do {
                    try fm.removeItem(at: candidate)
                    try fm.moveItem(at: staging, to: candidate)
                } catch {
                    try? fm.removeItem(at: candidate)
                    throw error
                }
                published = true
                return candidate
            }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        throw POSIXError(.EEXIST)
    }

    private static func filenameParts(_ preferredFilename: String) -> (stem: String, ext: String) {
        let requested = URL(fileURLWithPath: preferredFilename).lastPathComponent
        let filename = requested.isEmpty || requested == "." || requested == ".." ? "Track" : requested
        let filenameURL = URL(fileURLWithPath: filename)
        return (filenameURL.deletingPathExtension().lastPathComponent, filenameURL.pathExtension)
    }
}
