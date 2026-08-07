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
        let fileManager = FileManager.default
        let parentURL = finalTranscriptURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: parentURL, withIntermediateDirectories: true)

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

        // This is post-commit housekeeping. A crash or deletion failure here can
        // only leave unreferenced directories behind; it cannot invalidate the
        // just-committed transcript's generation.
        if transcriptCommitted, let generation {
            MessageAttachmentExporter.cleanupObsoleteGenerations(for: generation)
        }
    }
}
