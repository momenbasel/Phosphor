import Foundation
import Darwin

/// Atomically reserves and publishes a flattened photo export destination.
///
/// A flattened export cannot use a check-then-copy sequence: another export can
/// claim the same filename after `fileExists` returns false. Reservation creates
/// an empty final-path placeholder with `O_EXCL`, then the caller writes a unique
/// sibling staging file and atomically renames it over that placeholder.
final class FlatPhotoExportReservation {
    let targetURL: URL
    let stagingURL: URL

    private let fileManager: FileManager
    private var published = false

    private init(targetURL: URL, stagingURL: URL, fileManager: FileManager) {
        self.targetURL = targetURL
        self.stagingURL = stagingURL
        self.fileManager = fileManager
    }

    deinit {
        discard()
    }

    static func reserve(
        filename: String,
        stableID: String,
        root: URL,
        fileManager: FileManager = .default
    ) throws -> FlatPhotoExportReservation {
        let displayName = (filename as NSString).lastPathComponent
        guard !displayName.isEmpty, displayName != ".", displayName != ".." else {
            throw CocoaError(.fileNoSuchFile)
        }

        let stem = (displayName as NSString).deletingPathExtension
        let ext = (displayName as NSString).pathExtension
        let suffix = sanitizedSuffix(stableID)
        var sequence = 0

        while true {
            let name: String
            if sequence == 0 {
                name = displayName
            } else {
                let ordinal = sequence == 1 ? "" : "-\(sequence)"
                name = ext.isEmpty
                    ? "\(stem)-\(suffix)\(ordinal)"
                    : "\(stem)-\(suffix)\(ordinal).\(ext)"
            }
            let target = root.appendingPathComponent(name, isDirectory: false)
            guard try reserveEmptyFile(at: target) else {
                sequence += 1
                continue
            }

            do {
                let staging = root.appendingPathComponent(
                    ".\(name).phosphor-partial-\(UUID().uuidString)",
                    isDirectory: false
                )
                if try reserveEmptyFile(at: staging) {
                    return FlatPhotoExportReservation(
                        targetURL: target,
                        stagingURL: staging,
                        fileManager: fileManager
                    )
                }
                // UUID collisions are extraordinarily unlikely, but do not leave
                // a placeholder behind if one occurs before retrying.
                try? fileManager.removeItem(at: target)
            } catch {
                try? fileManager.removeItem(at: target)
                throw error
            }
        }
    }

    /// Atomically replace the placeholder only after the staged copy finished.
    func publish() throws {
        guard !published else { return }
        guard Darwin.rename(stagingURL.path, targetURL.path) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        published = true
    }

    /// Remove an unfinished staging copy and this reservation's placeholder.
    func discard() {
        try? fileManager.removeItem(at: stagingURL)
        if !published {
            try? fileManager.removeItem(at: targetURL)
        }
    }

    private static func sanitizedSuffix(_ stableID: String) -> String {
        let suffix = stableID.unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
        return suffix.isEmpty ? "backup-file" : suffix
    }

    private static func reserveEmptyFile(at url: URL) throws -> Bool {
        let descriptor = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
        if descriptor >= 0 {
            _ = Darwin.close(descriptor)
            return true
        }
        if errno == EEXIST { return false }
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
}
