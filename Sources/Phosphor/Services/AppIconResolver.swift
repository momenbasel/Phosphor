import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// Resolves home-screen app icons for a backup.
///
/// App icons are not stored per-app in an iOS backup, so icons are resolved
/// in priority order:
/// 1. `PlaceholderIcon` PNG data inside the backup's `Manifest.plist` (present
///    on Finder/iTunes-made backups).
/// 2. Disk cache under ~/Library/Caches/Phosphor/AppIcons/.
/// 3. Real system-app icons from an installed iOS Simulator runtime
///    (AppIcon*.png inside /Library/Developer/CoreSimulator/Volumes/...).
/// 4. iTunes Lookup API artwork (batched, best-effort, offline-safe).
/// 5. A monogram tile (first letter of the display name on a hashed color) —
///    always available, so the home screen never shows a blank icon.
actor AppIconResolver {

    static let shared = AppIconResolver()

    private let cacheDirectory: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = caches.appendingPathComponent("Phosphor/AppIcons", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private var memoryCache: [String: NSImage] = [:]
    private var pendingTasks: [String: Task<NSImage?, Never>] = [:]

    // MARK: - Public API

    /// Icon for one bundle id, consulting all tiers. `placeholderData` should
    /// be the `PlaceholderIcon` bytes from Manifest.plist when available.
    func icon(bundleID: String, displayName: String?, placeholderData: Data?) async -> NSImage? {
        if let cached = memoryCache[bundleID] { return cached }

        if let task = pendingTasks[bundleID] { return await task.value }

        let task = Task<NSImage?, Never> { [cacheDirectory] in
            // Tier 1: backup-provided placeholder icon.
            if let data = placeholderData, let image = NSImage(data: data) {
                return image
            }
            // Tier 2: disk cache.
            let file = cacheDirectory.appendingPathComponent("\(bundleID).png")
            if let data = try? Data(contentsOf: file), let image = NSImage(data: data) {
                return image
            }
            // Tier 3: real icon from an installed iOS Simulator runtime
            // (covers Apple system apps missing from the App Store).
            if let image = SimulatorRuntimeIcons.icon(bundleID: bundleID) {
                if let png = Self.pngData(from: image) {
                    try? png.write(to: file, options: .atomic)
                }
                return image
            }
            // Tier 4: iTunes Lookup artwork (also yields the App Store name).
            if let fetched = await Self.fetchArtwork(bundleID: bundleID) {
                if let png = Self.pngData(from: fetched.image) {
                    try? png.write(to: file, options: .atomic)
                }
                return fetched.image
            }
            // Tier 5: monogram fallback.
            return Self.monogram(name: displayName ?? bundleID)
        }

        pendingTasks[bundleID] = task
        let image = await task.value
        pendingTasks[bundleID] = nil
        if let image { memoryCache[bundleID] = image }
        return image
    }

    /// App Store display name for a bundle id: persistent cache first, then
    /// one lookup. Returns nil for system/never-published apps.
    func appStoreName(bundleID: String) async -> String? {
        if let cached = nameCache[bundleID] { return cached.isEmpty ? nil : cached }
        let fetched = await Self.fetchArtwork(bundleID: bundleID)
        // Negative results are cached as "" so offline/system apps do not
        // re-query on every load.
        nameCache[bundleID] = fetched?.name ?? ""
        persistNameCache()
        if let image = fetched?.image {
            memoryCache[bundleID] = image
            let file = cacheDirectory.appendingPathComponent("\(bundleID).png")
            if let png = Self.pngData(from: image) { try? png.write(to: file, options: .atomic) }
        }
        return fetched?.name
    }

    // MARK: - Name cache

    private lazy var nameCache: [String: String] = {
        let file = cacheDirectory.appendingPathComponent("names.plist")
        guard let data = try? Data(contentsOf: file),
              let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String]
        else { return [:] }
        return dict
    }()

    private func persistNameCache() {
        let file = cacheDirectory.appendingPathComponent("names.plist")
        if let data = try? PropertyListSerialization.data(fromPropertyList: nameCache, format: .binary, options: 0) {
            try? data.write(to: file, options: .atomic)
        }
    }

    /// Preload icons for a batch of bundle ids (called when a backup opens).
    func preload(bundleIDs: [String], placeholderDataByBundleID: [String: Data], namesByBundleID: [String: String]) async {
        await withTaskGroup(of: Void.self) { group in
            for id in bundleIDs {
                group.addTask { [weak self] in
                    _ = await self?.icon(
                        bundleID: id,
                        displayName: namesByBundleID[id],
                        placeholderData: placeholderDataByBundleID[id]
                    )
                }
            }
        }
    }

    // MARK: - Tiers

    /// Fetch app artwork + trackName via iTunes Lookup. Returns nil on any
    /// failure so callers fall through to the monogram tier.
    private static func fetchArtwork(bundleID: String) async -> (image: NSImage, name: String?)? {
        guard let encoded = bundleID.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(.init(charactersIn: ".-"))),
              let url = URL(string: "https://itunes.apple.com/lookup?bundleId=\(encoded)") else { return nil }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]],
              let first = results.first,
              let artworkURLString = first["artworkUrl512"] as? String,
              let artworkURL = URL(string: artworkURLString),
              let (artData, _) = try? await URLSession.shared.data(from: artworkURL),
              let image = NSImage(data: artData) else {
            return nil
        }
        return (image, first["trackName"] as? String)
    }

    /// Draw a deterministic monogram tile: first letter on a color hashed
    /// from the name, rounded like an iOS icon.
    private static func monogram(name: String, size: CGFloat = 120) -> NSImage {
        let letter = String(name.trimmingCharacters(in: .whitespaces).prefix(1).uppercased())
        let hue = CGFloat(abs(name.hashValue) % 360) / 360.0
        let bg = NSColor(hue: hue, saturation: 0.55, brightness: 0.85, alpha: 1)
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        let path = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: size, height: size),
                                xRadius: size * 0.225, yRadius: size * 0.225)
        bg.setFill()
        path.fill()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size * 0.5, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let str = NSAttributedString(string: letter, attributes: attributes)
        let strSize = str.size()
        str.draw(at: NSPoint(x: (size - strSize.width) / 2, y: (size - strSize.height) / 2))
        image.unlockFocus()
        return image
    }

    private static func pngData(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}
