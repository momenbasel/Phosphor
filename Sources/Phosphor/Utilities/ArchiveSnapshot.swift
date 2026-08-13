import Darwin
import Foundation

enum ArchiveSnapshot {
    enum SnapshotError: Error {
        case openSource(Int32)
        case sourceIsNotRegularFile
        case createDirectory(Int32)
        case createDestination(Int32)
        case readSource(Int32)
        case writeDestination(Int32)
    }

    /// Copy a user-selected archive through an already-open regular-file descriptor.
    /// `O_NOFOLLOW` rejects source symlinks, and later path replacement cannot change
    /// the private bytes used for validation and extraction.
    static func copyRegularFile(at path: String) throws -> URL {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory
            .appendingPathComponent("phosphor-archive-\(UUID().uuidString)", isDirectory: true)
        guard mkdir(directory.path, S_IRWXU) == 0 else {
            throw SnapshotError.createDirectory(errno)
        }
        var keepDirectory = false
        defer {
            if !keepDirectory { try? fm.removeItem(at: directory) }
        }

        let sourceFD = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard sourceFD >= 0 else { throw SnapshotError.openSource(errno) }
        defer { close(sourceFD) }

        var sourceInfo = stat()
        guard fstat(sourceFD, &sourceInfo) == 0,
              sourceInfo.st_mode & S_IFMT == S_IFREG else {
            throw SnapshotError.sourceIsNotRegularFile
        }

        let destination = directory.appendingPathComponent("archive.phosphor")
        let destinationFD = open(
            destination.path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard destinationFD >= 0 else { throw SnapshotError.createDestination(errno) }
        defer { close(destinationFD) }

        var buffer = [UInt8](repeating: 0, count: 1024 * 1024)
        while true {
            let bytesRead = buffer.withUnsafeMutableBytes { rawBuffer in
                read(sourceFD, rawBuffer.baseAddress, rawBuffer.count)
            }
            if bytesRead == 0 { break }
            if bytesRead < 0 {
                if errno == EINTR { continue }
                throw SnapshotError.readSource(errno)
            }

            var offset = 0
            while offset < bytesRead {
                let bytesWritten = buffer.withUnsafeBytes { rawBuffer in
                    write(
                        destinationFD,
                        rawBuffer.baseAddress?.advanced(by: offset),
                        bytesRead - offset
                    )
                }
                if bytesWritten < 0 {
                    if errno == EINTR { continue }
                    throw SnapshotError.writeDestination(errno)
                }
                guard bytesWritten > 0 else { throw SnapshotError.writeDestination(EIO) }
                offset += bytesWritten
            }
        }

        keepDirectory = true
        return destination
    }
}
