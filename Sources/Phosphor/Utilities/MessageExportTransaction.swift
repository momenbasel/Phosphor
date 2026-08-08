import Darwin
import Foundation

/// Publishes a staged transcript without ever moving a completed attachment
/// sidecar out of the path named by that transcript. A fresh attachment
/// generation is made visible first, its relative name is embedded in the
/// staged transcript, and only then is the transcript atomically replaced.
enum MessageExportTransaction {
    static func write(
        to finalTranscriptURL: URL,
        attachmentMap: [String: String] = [:],
        prepareAttachments: (() throws -> MessageAttachmentExporter.Generation)? = nil,
        populate: (URL, [String: String]) throws -> Void
    ) throws {
        // The parent must exist before the cross-process lock file can be opened.
        // This is idempotent when another exporter is starting concurrently.
        try FileManager.default.createDirectory(
            at: finalTranscriptURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try withDestinationLock(for: finalTranscriptURL) {
            let fileManager = FileManager.default
            let parentURL = finalTranscriptURL.deletingLastPathComponent()

            let stagedTranscriptURL = parentURL.appendingPathComponent(
                ".\(finalTranscriptURL.lastPathComponent).staging-\(UUID().uuidString)"
            )
            var generation: MessageAttachmentExporter.Generation?
            var transcriptCommitted = false

            do {
                generation = try prepareAttachments?()
                try populate(stagedTranscriptURL, generation?.paths ?? attachmentMap)

                if fileManager.fileExists(atPath: finalTranscriptURL.path) {
                    _ = try fileManager.replaceItemAt(finalTranscriptURL, withItemAt: stagedTranscriptURL)
                } else {
                    try fileManager.moveItem(at: stagedTranscriptURL, to: finalTranscriptURL)
                }
                transcriptCommitted = true
            } catch {
                try? fileManager.removeItem(at: stagedTranscriptURL)
                if let generation {
                    MessageAttachmentExporter.discard(generation)
                }
                throw error
            }

            // Cleanup remains inside the destination lock: a concurrent export
            // must never remove the sidecar referenced by the transcript that
            // was published after this one.
            if transcriptCommitted, let generation {
                MessageAttachmentExporter.cleanupObsoleteGenerations(for: generation)
            }
        }
    }

    /// Serialize complete transcript-plus-sidecar publication per destination,
    /// including across separate Phosphor processes. The lock file deliberately
    /// persists: deleting a lock file after unlock can split waiters between old
    /// and new inodes, defeating mutual exclusion.
    private static func withDestinationLock<T>(
        for finalTranscriptURL: URL,
        operation: () throws -> T
    ) throws -> T {
        let lockURL = finalTranscriptURL.deletingLastPathComponent()
            .appendingPathComponent(".\(finalTranscriptURL.lastPathComponent).phosphor-export.lock")
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
