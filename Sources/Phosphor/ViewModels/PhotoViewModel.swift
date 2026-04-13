import Foundation
import SwiftUI

/// Drives photo/video browsing and extraction UI.
@MainActor
final class PhotoViewModel: ObservableObject {

    @Published var items: [MediaItem] = []
    @Published var isLoading = false
    @Published var selectedFilter: MediaItem.MediaType?
    @Published var extractionProgress: Double = 0
    @Published var showAlert = false
    @Published var alertMessage = ""

    let photoExtractor = PhotoExtractor()
    private var backupPath: String?

    var filteredItems: [MediaItem] {
        photoExtractor.filtered(by: selectedFilter)
    }

    var stats: (photos: Int, videos: Int, totalSize: Int) {
        photoExtractor.stats
    }

    func loadPhotos(from backupPath: String) async {
        self.backupPath = backupPath
        isLoading = true
        await photoExtractor.loadMedia(from: backupPath)
        items = photoExtractor.mediaItems
        isLoading = false
    }

    func extractSelected(_ items: [MediaItem], to destination: String) async -> Int {
        guard let path = backupPath else { return 0 }
        let count = await photoExtractor.extractMedia(items: items, from: path, to: destination)
        alertMessage = "Extracted \(count) files"
        showAlert = true
        return count
    }

    func extractAll(to destination: String) async -> Int {
        await extractSelected(items, to: destination)
    }
}
