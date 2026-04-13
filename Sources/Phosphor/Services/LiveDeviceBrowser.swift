import Foundation

/// Browse device content LIVE without needing a backup.
/// Primary: pymobiledevice3 AFC (no FUSE needed). Fallback: ifuse.
@MainActor
final class LiveDeviceBrowser: ObservableObject {

    @Published var photos: [LivePhoto] = []
    @Published var isLoading = false
    @Published var isMounted = false
    @Published var lastError: String?
    @Published var mountPath: String?
    @Published var photoCount: Int = 0

    private var deviceUDID: String?
    private var usesAFC = false

    struct LivePhoto: Identifiable, Hashable {
        let id: String
        let name: String
        let path: String
        let size: UInt64
        let modified: Date?
        let isVideo: Bool

        var sizeString: String { size.formattedFileSize }

        var sfSymbol: String {
            let ext = (name as NSString).pathExtension.lowercased()
            switch ext {
            case "mov", "mp4", "m4v": return "video.fill"
            case "png": return "photo"
            default: return "photo"
            }
        }

        var isScreenshot: Bool {
            name.lowercased().contains("screenshot") || name.hasPrefix("IMG_") && name.contains("PNG")
        }
    }

    // MARK: - Connect

    /// Connect to device via pymobiledevice3 AFC (primary) or ifuse (fallback).
    func mount(udid: String) async -> Bool {
        deviceUDID = udid

        // Primary: pymobiledevice3 AFC - scan DCIM structure first
        if PyMobileDevice.available() {
            // List DCIM subfolders to count photos before downloading
            let dcimContents = await PyMobileDevice.afcList(path: "/DCIM", udid: udid)
            if !dcimContents.isEmpty {
                usesAFC = true
                isMounted = true

                // Count photos across DCIM subfolders
                var count = 0
                for subfolder in dcimContents {
                    guard !subfolder.isEmpty, subfolder != ".", subfolder != ".." else { continue }
                    let subFiles = await PyMobileDevice.afcList(path: "/DCIM/\(subfolder)", udid: udid)
                    count += subFiles.filter { name in
                        let ext = (name as NSString).pathExtension.lowercased()
                        return ["jpg", "jpeg", "heic", "heif", "png", "gif", "mov", "mp4", "m4v"].contains(ext)
                    }.count
                }
                photoCount = count
                return true
            }
        }

        // Fallback: ifuse mount
        let tmpDir = NSTemporaryDirectory() + "phosphor-live-\(udid.prefix(8))"
        let fm = FileManager.default
        try? fm.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)

        let ifuseResult = await Shell.runAsync("ifuse", arguments: ["-u", udid, tmpDir])
        if ifuseResult.succeeded {
            mountPath = tmpDir
            usesAFC = false
            isMounted = true
            return true
        }

        lastError = "Could not access device. Install pymobiledevice3: pip3 install pymobiledevice3"
        return false
    }

    func unmount() async {
        if let mount = mountPath, !usesAFC {
            let _ = await Shell.runAsync("umount", arguments: [mount])
            try? FileManager.default.removeItem(atPath: mount)
        }
        mountPath = nil
        deviceUDID = nil
        isMounted = false
        usesAFC = false
        photos = []
        photoCount = 0
    }

    // MARK: - Photo Scanning

    /// Scan and selectively pull photos from device.
    func scanPhotos() async {
        isLoading = true
        photos = []

        if usesAFC {
            await scanPhotosViaAFC()
        } else {
            await scanPhotosViaMount()
        }

        isLoading = false
    }

    /// Scan photos via pymobiledevice3 AFC - list only, no download until export.
    private func scanPhotosViaAFC() async {
        guard let udid = deviceUDID else { return }

        let photoExtensions = Set(["jpg", "jpeg", "heic", "heif", "png", "gif", "webp",
                                    "mov", "mp4", "m4v", "3gp"])

        let dcimContents = await PyMobileDevice.afcList(path: "/DCIM", udid: udid)
        var found: [LivePhoto] = []

        for subfolder in dcimContents.sorted() {
            guard !subfolder.isEmpty else { continue }

            // Just list files - don't download them yet
            let files = await PyMobileDevice.afcList(path: "/DCIM/\(subfolder)", udid: udid)

            for file in files {
                let ext = (file as NSString).pathExtension.lowercased()
                guard photoExtensions.contains(ext) else { continue }

                let remotePath = "/DCIM/\(subfolder)/\(file)"
                let isVideo = ["mov", "mp4", "m4v", "3gp"].contains(ext)

                found.append(LivePhoto(
                    id: remotePath, name: file, path: remotePath,
                    size: 0, modified: nil, isVideo: isVideo
                ))
            }
        }

        photos = found
        photoCount = found.count
    }

    /// Pull a single photo from device to local temp for viewing/export.
    func pullPhoto(_ photo: LivePhoto) async -> String? {
        guard let udid = deviceUDID else { return nil }
        let tmpDir = NSTemporaryDirectory() + "phosphor-photos-\(udid.prefix(8))"
        let fm = FileManager.default
        try? fm.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)

        let localPath = (tmpDir as NSString).appendingPathComponent(photo.name)
        if fm.fileExists(atPath: localPath) { return localPath } // Already downloaded

        let success = await PyMobileDevice.afcPull(remotePath: photo.path, localPath: localPath, udid: udid)
        return success ? localPath : nil
    }

    /// Scan photos via ifuse mount (legacy).
    private func scanPhotosViaMount() async {
        guard let mount = mountPath else { return }

        let dcimPath = (mount as NSString).appendingPathComponent("DCIM")
        let fm = FileManager.default

        guard fm.fileExists(atPath: dcimPath) else {
            lastError = "DCIM folder not found on device"
            return
        }

        let photoExtensions = Set(["jpg", "jpeg", "heic", "heif", "png", "gif", "webp",
                                    "mov", "mp4", "m4v", "3gp"])
        var found: [LivePhoto] = []

        if let subfolders = try? fm.contentsOfDirectory(atPath: dcimPath) {
            for subfolder in subfolders.sorted() {
                let subPath = (dcimPath as NSString).appendingPathComponent(subfolder)
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: subPath, isDirectory: &isDir), isDir.boolValue else { continue }

                if let files = try? fm.contentsOfDirectory(atPath: subPath) {
                    for file in files {
                        let ext = (file as NSString).pathExtension.lowercased()
                        guard photoExtensions.contains(ext) else { continue }

                        let fullPath = (subPath as NSString).appendingPathComponent(file)
                        let attrs = try? fm.attributesOfItem(atPath: fullPath)
                        let size = (attrs?[.size] as? UInt64) ?? 0
                        let modified = attrs?[.modificationDate] as? Date
                        let isVideo = ["mov", "mp4", "m4v", "3gp"].contains(ext)

                        found.append(LivePhoto(
                            id: fullPath, name: file, path: fullPath,
                            size: size, modified: modified, isVideo: isVideo
                        ))
                    }
                }
            }
        }

        photos = found.sorted { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
    }

    // MARK: - Export

    func exportPhoto(_ photo: LivePhoto, to destination: String) async throws {
        let fm = FileManager.default
        let destDir = (destination as NSString).deletingLastPathComponent
        try fm.createDirectory(atPath: destDir, withIntermediateDirectories: true)

        if usesAFC {
            // AFC mode: pull from device directly to destination
            guard let udid = deviceUDID else { throw CocoaError(.fileNoSuchFile) }
            let success = await PyMobileDevice.afcPull(remotePath: photo.path, localPath: destination, udid: udid)
            if !success { throw CocoaError(.fileWriteUnknown) }
        } else {
            // Mount mode: local copy
            if fm.fileExists(atPath: destination) { try fm.removeItem(atPath: destination) }
            try fm.copyItem(atPath: photo.path, toPath: destination)
        }
    }

    func exportPhotos(_ selectedPhotos: [LivePhoto], to directory: String) async -> Int {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: directory, withIntermediateDirectories: true)
        var count = 0
        for photo in selectedPhotos {
            let dest = (directory as NSString).appendingPathComponent(photo.name)
            do { try await exportPhoto(photo, to: dest); count += 1 } catch { continue }
        }
        return count
    }

    /// Convert HEIC photos to JPG using macOS sips.
    func convertHEICtoJPG(inputPath: String, outputPath: String) async -> Bool {
        let result = await Shell.runAsync("sips", arguments: [
            "--setProperty", "format", "jpeg", inputPath, "--out", outputPath
        ])
        return result.succeeded
    }

    // MARK: - General File Listing

    func listFiles(at relativePath: String) -> [(name: String, isDir: Bool, size: UInt64)] {
        guard let mount = mountPath else { return [] }
        let fullPath = (mount as NSString).appendingPathComponent(relativePath)
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(atPath: fullPath) else { return [] }
        return contents.sorted().compactMap { name in
            let itemPath = (fullPath as NSString).appendingPathComponent(name)
            var isDir: ObjCBool = false
            fm.fileExists(atPath: itemPath, isDirectory: &isDir)
            let attrs = try? fm.attributesOfItem(atPath: itemPath)
            let size = (attrs?[.size] as? UInt64) ?? 0
            return (name: name, isDir: isDir.boolValue, size: size)
        }
    }

    func getTopLevelFolders() -> [String] {
        guard let mount = mountPath else { return [] }
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(atPath: mount) else { return [] }
        return contents.sorted().filter { name in
            var isDir: ObjCBool = false
            let path = (mount as NSString).appendingPathComponent(name)
            return fm.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
        }
    }
}
