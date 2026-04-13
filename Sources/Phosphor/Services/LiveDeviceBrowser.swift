import Foundation

/// Browse device content LIVE without needing a backup.
/// Uses AFC (Apple File Conduit) via ifuse to mount and browse the device directly.
/// Accessible folders: DCIM (Camera Roll), Downloads, Books, iTunes_Control, etc.
@MainActor
final class LiveDeviceBrowser: ObservableObject {

    @Published var photos: [LivePhoto] = []
    @Published var isLoading = false
    @Published var isMounted = false
    @Published var lastError: String?
    @Published var mountPath: String?

    struct LivePhoto: Identifiable, Hashable {
        let id: String // full path
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
            case "png": return "photo" // likely screenshot
            default: return "photo"
            }
        }

        var isScreenshot: Bool {
            name.lowercased().contains("screenshot") || name.hasPrefix("IMG_") && name.contains("PNG")
        }
    }

    // MARK: - Mount

    /// Pull device photos using pymobiledevice3 AFC (no FUSE/ifuse needed).
    func mount(udid: String) async -> Bool {
        let tmpDir = NSTemporaryDirectory() + "phosphor-live-\(udid.prefix(8))"
        let fm = FileManager.default

        do {
            try fm.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
        } catch {
            lastError = "Failed to create temp directory: \(error.localizedDescription)"
            return false
        }

        // Use pymobiledevice3 AFC to pull DCIM
        let checkPy = await Shell.runAsync("python3", arguments: ["-c", "import pymobiledevice3"], timeout: 10)
        if checkPy.succeeded {
            // Pull entire DCIM via pymobiledevice3
            let dcimDest = (tmpDir as NSString).appendingPathComponent("DCIM")
            try? fm.createDirectory(atPath: dcimDest, withIntermediateDirectories: true)

            let result = await Shell.runAsync(
                "python3",
                arguments: ["-m", "pymobiledevice3", "afc", "pull", "/DCIM", dcimDest],
                timeout: 300
            )
            if result.succeeded || fm.fileExists(atPath: dcimDest) {
                mountPath = tmpDir
                isMounted = true
                return true
            }
        }

        // Fallback: try ifuse (works on older macOS or if macFUSE installed)
        let ifuseResult = await Shell.runAsync("ifuse", arguments: ["-u", udid, tmpDir])
        if ifuseResult.succeeded {
            mountPath = tmpDir
            isMounted = true
            return true
        }

        lastError = "Could not access device photos. Install pymobiledevice3: pip3 install pymobiledevice3"
        return false
    }

    func unmount() async {
        guard let mount = mountPath else { return }
        // Try umount for ifuse, otherwise just clean up temp dir
        let _ = await Shell.runAsync("umount", arguments: [mount])
        try? FileManager.default.removeItem(atPath: mount)
        mountPath = nil
        isMounted = false
        photos = []
    }

    // MARK: - Photo Scanning

    /// Scan DCIM folder for all photos and videos on the device.
    func scanPhotos() async {
        guard let mount = mountPath else { return }
        isLoading = true
        photos = []

        let dcimPath = (mount as NSString).appendingPathComponent("DCIM")
        let fm = FileManager.default

        guard fm.fileExists(atPath: dcimPath) else {
            lastError = "DCIM folder not found on device"
            isLoading = false
            return
        }

        var found: [LivePhoto] = []
        let photoExtensions = Set(["jpg", "jpeg", "heic", "heif", "png", "gif", "webp",
                                    "mov", "mp4", "m4v", "3gp"])

        // DCIM contains subfolders like 100APPLE, 101APPLE, etc.
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
                            id: fullPath,
                            name: file,
                            path: fullPath,
                            size: size,
                            modified: modified,
                            isVideo: isVideo
                        ))
                    }
                }
            }
        }

        // Sort newest first
        photos = found.sorted { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
        isLoading = false
    }

    // MARK: - Export

    /// Copy a photo from device to local path.
    func exportPhoto(_ photo: LivePhoto, to destination: String) throws {
        let fm = FileManager.default
        let destDir = (destination as NSString).deletingLastPathComponent
        try fm.createDirectory(atPath: destDir, withIntermediateDirectories: true)
        if fm.fileExists(atPath: destination) {
            try fm.removeItem(atPath: destination)
        }
        try fm.copyItem(atPath: photo.path, toPath: destination)
    }

    /// Batch export photos to a directory.
    func exportPhotos(_ photos: [LivePhoto], to directory: String) -> Int {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: directory, withIntermediateDirectories: true)
        var count = 0
        for photo in photos {
            let dest = (directory as NSString).appendingPathComponent(photo.name)
            do {
                try exportPhoto(photo, to: dest)
                count += 1
            } catch {
                continue
            }
        }
        return count
    }

    // MARK: - General File Listing

    /// List files at a specific path on the mounted device.
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

    /// Get available top-level folders on device.
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
