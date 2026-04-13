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
            let photos = try manifest.cameraRollPhotos()

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

                let destPath: String
                if preserveStructure {
                    destPath = (destination as NSString).appendingPathComponent(item.relativePath)
                } else {
                    destPath = (destination as NSString).appendingPathComponent(item.filename)
                }

                do {
                    try manifest.extractFile(entry, to: destPath)
                    extracted += 1
                } catch {
                    // Skip files that can't be extracted, continue with others
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
