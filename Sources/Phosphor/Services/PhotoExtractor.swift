import Foundation

/// Extracts photos and videos from iOS backup Camera Roll domain.
@MainActor
final class PhotoExtractor: ObservableObject {

    @Published var mediaItems: [MediaItem] = []
    @Published var isLoading = false
    @Published var extractionProgress: Double = 0
    @Published var lastError: String?

    /// Load all media items from a backup's Camera Roll.
    func loadMedia(from backupPath: String) async {
        isLoading = true
        lastError = nil

        do {
            let manifest = try BackupManifest(backupPath: backupPath)
            let photos = manifest.resolvingSizes(for: try manifest.cameraRollPhotos())

            mediaItems = photos.map { entry in
                MediaItem(
                    id: entry.id,
                    filename: entry.fileName,
                    relativePath: entry.relativePath,
                    size: entry.size,
                    domain: entry.domain,
                    mediaType: MediaItem.mediaType(for: entry.fileName)
                )
            }
        } catch {
            lastError = error.localizedDescription
            mediaItems = []
        }

        isLoading = false
    }

    /// Extract selected media items to a destination folder.
    func extractMedia(
        items: [MediaItem],
        from backupPath: String,
        to destination: String,
        preserveStructure: Bool = false
    ) async -> Int {
        extractionProgress = 0
        let fm = FileManager.default

        do {
            try fm.createDirectory(atPath: destination, withIntermediateDirectories: true)
            let manifest = try BackupManifest(backupPath: backupPath)

            var extracted = 0
            for (index, item) in items.enumerated() {
                let entry = BackupManifest.FileEntry(
                    id: item.id,
                    domain: item.domain,
                    relativePath: item.relativePath,
                    flags: 1,
                    size: item.size
                )

                // relativePath and filename are manifest-controlled, so both branches
                // resolve through the shared boundary check instead of being joined
                // onto the destination directly. Flattened exports additionally keep
                // distinct backup files distinct when their display names collide.
                let destinationRoot = URL(fileURLWithPath: destination, isDirectory: true)
                var flatReservation: FlatPhotoExportReservation?
                var destPath: URL?
                do {
                    if preserveStructure {
                        flatReservation = nil
                        destPath = try SafeExtractionPath.prepareDestination(
                            root: destinationRoot,
                            relativePath: item.relativePath,
                            fileManager: fm
                        )
                    } else {
                        // Validate the manifest-controlled display name before the
                        // reservation helper turns it into a flat sibling path.
                        _ = try SafeExtractionPath.prepareDestination(
                            root: destinationRoot,
                            relativePath: item.filename,
                            fileManager: fm
                        )
                        let reservation = try FlatPhotoExportReservation.reserve(
                            filename: item.filename,
                            stableID: item.id,
                            root: destinationRoot,
                            fileManager: fm
                        )
                        flatReservation = reservation
                        destPath = reservation.stagingURL
                    }
                } catch {
                    flatReservation = nil
                    destPath = nil
                }

                if let destPath {
                    do {
                        // A failed extraction removes only our private stage and
                        // placeholder; it can never overwrite another export.
                        defer { flatReservation?.discard() }
                        try manifest.extractFile(entry, to: destPath.path)
                        try flatReservation?.publish()
                        extracted += 1
                    } catch {
                        // Skip files that can't be extracted, continue with others
                    }
                }

                extractionProgress = Double(index + 1) / Double(items.count)
            }

            return extracted
        } catch {
            lastError = error.localizedDescription
            return 0
        }
    }

    /// Get summary stats for loaded media.
    var stats: (photos: Int, videos: Int, totalSize: Int) {
        let photos = mediaItems.filter { $0.mediaType == .photo || $0.mediaType == .screenshot }.count
        let videos = mediaItems.filter { $0.mediaType == .video }.count
        let size = mediaItems.reduce(0) { $0 + $1.size }
        return (photos, videos, size)
    }

    /// Filter media by type.
    func filtered(by type: MediaItem.MediaType?) -> [MediaItem] {
        guard let type else { return mediaItems }
        return mediaItems.filter { $0.mediaType == type }
    }
}
