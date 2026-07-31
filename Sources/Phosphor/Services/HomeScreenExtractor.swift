import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// Extracts the home screen layout from an iOS backup.
///
/// Source: HomeDomain/Library/SpringBoard/IconState.plist. Schema verified
/// against a real iOS 17/18 backup (see HomeScreenLayout doc):
/// - Apps are plain bundle-id strings.
/// - Web clips are plain 32-hex-character strings; their names live in
///   HomeDomain/Library/WebClips/<id>.webclip/Info.plist ("Title").
/// - Folders are dicts with listType == "folder", displayName, iconLists.
/// - Widgets are dicts with elementType == "widget", gridSize
///   (small/medium/large), containerBundleIdentifier (owning app),
///   bundleIdentifier (extension), widgetIdentifier (kind).
/// - Root also has: ignored (App Library-only apps), today (Today view
///   widgets), listMetadata (per-page fixedLocations pinning items to slots).
/// Unknown shapes degrade to `.unknown` and never crash.
final class HomeScreenExtractor {

    enum ExtractorError: Error, LocalizedError {
        case notFound
        case unreadable(underlying: String)

        var errorDescription: String? {
            switch self {
            case .notFound:
                return "No home screen layout (IconState.plist) was found in this backup."
            case .unreadable(let underlying):
                return "Could not read IconState.plist: \(underlying)"
            }
        }
    }

    private let manifest: BackupManifest

    init(manifest: BackupManifest) {
        self.manifest = manifest
    }

    /// Known relative paths for the layout plist, most likely first.
    private static let candidatePaths = [
        "Library/SpringBoard/IconState.plist",
        "Library/Preferences/com.apple.springboard.IconState.plist",
    ]

    func extract() throws -> HomeScreenLayout {
        var layout = HomeScreenLayout()

        // Find the IconState.plist entry in the manifest.
        let matches = (try? manifest.files(matching: "%IconState.plist")) ?? []
        let entry = matches.first(where: { $0.relativePath == Self.candidatePaths[0] })
            ?? matches.first(where: { $0.relativePath == Self.candidatePaths[1] })
            ?? matches.first(where: { $0.relativePath.contains("SpringBoard") })
            ?? matches.first

        guard let entry else {
            throw ExtractorError.notFound
        }
        layout.sourceFound = true

        let data = try manifest.fileData(for: entry)
        let plist: Any
        do {
            plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        } catch {
            throw ExtractorError.unreadable(underlying: error.localizedDescription)
        }
        guard let root = plist as? [String: Any] else {
            throw ExtractorError.unreadable(underlying: "root is not a dictionary")
        }

        layout.dock = parseList(root["buttonBar"]).map(parseItem)

        // Pages, with listMetadata fixed-slot pins matched by page UUID.
        let pageUUIDs = root["listUniqueIdentifiers"] as? [String] ?? []
        let listMetadata = root["listMetadata"] as? [String: [String: Any]] ?? [:]
        let iconLists = parseList(root["iconLists"])
        layout.pages = iconLists.enumerated().map { index, pageValue in
            var page = HomeScreenLayout.Page(id: index)
            page.uuid = index < pageUUIDs.count ? pageUUIDs[index] : nil
            page.items = parseList(pageValue).map(parseItem)
            if let uuid = page.uuid, let meta = listMetadata[uuid] {
                page.fixedSlots = (meta["fixedLocations"] as? [String: Int]) ?? [:]
                page.gridColumns = (meta["fixedLocationsGridColumns"] as? Int) ?? 4
                page.gridRows = (meta["fixedLocationsGridRows"] as? Int) ?? 6
            }
            return page
        }

        layout.todayWidgets = parseList(root["today"]).compactMap { value in
            guard let dict = value as? [String: Any] else { return nil }
            return widgetInfo(from: dict)
        }
        layout.ignoredApps = root["ignored"] as? [String] ?? []

        layout.wallpaperData = extractWallpaper()
        applyDisplayNames(to: &layout)
        return layout
    }

    // MARK: - Item parsing

    /// Coerce a plist value into an array of items.
    private func parseList(_ value: Any?) -> [Any] {
        if let arr = value as? [Any] { return arr }
        if let dict = value as? [String: Any] { return [dict] }
        return []
    }

    /// Classify one slot per the verified schema.
    private func parseItem(_ value: Any) -> HomeScreenLayout.Item {
        if let string = value as? String {
            // Web clips appear as bare 32-hex-uppercase strings; everything
            // else is a bundle id (contains dots).
            if Self.looksLikeWebClipID(string) {
                return .webClip(id: string, displayName: nil)
            }
            return .app(bundleID: string, displayName: nil)
        }
        guard let dict = value as? [String: Any] else {
            return .unknown(type: String(describing: Swift.type(of: value)))
        }

        // Widget: elementType == "widget" (observed) or any dict with gridSize.
        if (dict["elementType"] as? String) == "widget" || dict["gridSize"] != nil {
            if let info = widgetInfo(from: dict) {
                return .widget(info)
            }
        }

        // Folder: listType == "folder" (observed) or displayName + iconLists.
        let isFolder = (dict["listType"] as? String) == "folder"
            || (dict["displayName"] != nil && dict["iconLists"] != nil)
        if isFolder {
            let name = (dict["displayName"] as? String) ?? "Folder"
            let folderPages = parseList(dict["iconLists"]).map { parseList($0).map(parseItem) }
            return .folder(name: name, pages: folderPages)
        }

        return .unknown(type: dict.keys.sorted().joined(separator: ","))
    }

    /// Build WidgetInfo from a widget dict (page or Today view — same shape).
    private func widgetInfo(from dict: [String: Any]) -> HomeScreenLayout.WidgetInfo? {
        let sizeRaw = (dict["gridSize"] as? String)?.lowercased() ?? "small"
        let size = HomeScreenLayout.WidgetSize(rawValue: sizeRaw)
            ?? (sizeRaw.contains("large") ? .large : sizeRaw.contains("medium") ? .medium : .small)
        return HomeScreenLayout.WidgetInfo(
            uniqueID: (dict["uniqueIdentifier"] as? String) ?? UUID().uuidString,
            extensionBundleID: dict["bundleIdentifier"] as? String,
            containerBundleID: dict["containerBundleIdentifier"] as? String,
            kind: dict["widgetIdentifier"] as? String,
            size: size
        )
    }

    /// Web clip ids in iconLists are 32 uppercase hex chars, no dots/dashes.
    static func looksLikeWebClipID(_ string: String) -> Bool {
        string.count == 32 && !string.contains(".") && string.allSatisfy { $0.isHexDigit }
    }

    // MARK: - Display names

    /// Fill app/web-clip display names from the backup's metadata:
    /// Manifest.plist Applications (App Store apps) and web clip Info.plist
    /// files (bookmark titles). Apple system apps are named by the static map
    /// at render time.
    private func applyDisplayNames(to layout: inout HomeScreenLayout) {
        var names: [String: String] = [:]
        for info in PlistParser.parseApplications(manifest.backupPath) {
            if let name = info.name { names[info.bundleID] = name }
        }
        let clipNames = webClipTitles()

        func rename(_ items: [HomeScreenLayout.Item]) -> [HomeScreenLayout.Item] {
            items.map { item in
                switch item {
                case .app(let bundleID, let existing):
                    return .app(bundleID: bundleID, displayName: existing ?? names[bundleID])
                case .folder(let name, let pages):
                    return .folder(name: name, pages: pages.map(rename))
                case .webClip(let id, let existing):
                    return .webClip(id: id, displayName: existing ?? clipNames[id])
                default:
                    return item
                }
            }
        }
        layout.dock = rename(layout.dock)
        for i in layout.pages.indices {
            layout.pages[i].items = rename(layout.pages[i].items)
        }
    }

    /// Map web-clip id -> Title from HomeDomain/Library/WebClips/<id>.webclip/Info.plist.
    private func webClipTitles() -> [String: String] {
        var titles: [String: String] = [:]
        guard let clips = try? manifest.files(matching: "%WebClips/%/Info.plist") else { return titles }
        for clip in clips {
            guard let data = try? manifest.fileData(for: clip),
                  let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
                  let title = plist["Title"] as? String,
                  let folder = clip.relativePath.components(separatedBy: "/").first(where: { $0.hasSuffix(".webclip") })
            else { continue }
            titles[String(folder.dropLast(".webclip".count))] = title
        }
        return titles
    }

    /// Web clip icon PNG (icon.png inside the .webclip folder), if backed up.
    func webClipIcon(id: String) -> Data? {
        guard let files = try? manifest.files(matching: "%WebClips/\(id).webclip/%") else { return nil }
        guard let icon = files.first(where: { $0.fileName.lowercased().hasSuffix(".png") }) else { return nil }
        return try? manifest.fileData(for: icon)
    }

    // MARK: - Wallpaper

    /// Wallpaper candidates, iOS-version-dependent. `cpbitmap` is a raw BGRA
    /// bitmap with a small header; plain images (png/jpg/heic) decode directly.
    private static let wallpaperPatterns = [
        "%HomeScreenBackground.cpbitmap",
        "%OriginalWallpaper%",
        "%Wallpaper%HomeScreen%",
        "%PosterBoard%home%",
    ]

    /// Best-effort wallpaper extraction. Returns PNG data for the first
    /// candidate that decodes to an image, else nil — the UI falls back to a
    /// gradient and never breaks.
    private func extractWallpaper() -> Data? {
        for pattern in Self.wallpaperPatterns {
            guard let matches = try? manifest.files(matching: pattern) else { continue }
            for entry in matches where entry.isFile {
                guard let data = try? manifest.fileData(for: entry) else { continue }
                if let png = decodeWallpaper(data: data, name: entry.fileName) {
                    return png
                }
            }
        }
        return nil
    }

    private func decodeWallpaper(data: Data, name: String) -> Data? {
        // Plain image formats decode directly.
        if let image = NSImage(data: data),
           let png = Self.pngData(of: image) {
            return png
        }
        // cpbitmap: header of variable size, then BGRA pixels.
        if name.hasSuffix(".cpbitmap"), let png = CPBitmapDecoder.decode(data) {
            return png
        }
        return nil
    }

    private static func pngData(of image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    /// Minimal decoder for iOS `cpbitmap` wallpapers: a small header followed
    /// by packed BGRA pixels. Variants differ, so try every plausible
    /// (width, height, offset) combination consistent with the data length.
    enum CPBitmapDecoder {
        static func decode(_ data: Data) -> Data? {
            guard data.count > 16 else { return nil }
            var candidates: [(w: Int, h: Int, offset: Int)] = []
            for offset in stride(from: 0, through: 48, by: 4) {
                let w = data.withUnsafeBytes { $0.load(fromByteOffset: offset, as: UInt32.self) }.littleEndian
                let h = data.withUnsafeBytes { $0.load(fromByteOffset: offset + 4, as: UInt32.self) }.littleEndian
                guard (256...10000).contains(Int(w)), (256...10000).contains(Int(h)) else { continue }
                let pixelBytes = Int(w) * Int(h) * 4
                let dataOffset = data.count - pixelBytes
                if dataOffset >= 0 {
                    candidates.append((Int(w), Int(h), dataOffset))
                }
            }
            for (w, h, offset) in candidates {
                let pixels = data.subdata(in: offset..<(offset + w * h * 4))
                if let png = renderBGRA(pixels, width: w, height: h) {
                    return png
                }
            }
            return nil
        }

        private static func renderBGRA(_ pixels: Data, width: Int, height: Int) -> Data? {
            guard let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: width,
                pixelsHigh: height,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .calibratedRGB,
                bitmapFormat: [.thirtyTwoBitLittleEndian],
                bytesPerRow: width * 4,
                bitsPerPixel: 32
            ), let buffer = rep.bitmapData else { return nil }
            pixels.copyBytes(to: buffer, count: pixels.count)
            return rep.representation(using: .png, properties: [:])
        }
    }
}
