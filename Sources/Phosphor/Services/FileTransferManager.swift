import Foundation

/// File transfer between Mac and iOS device using AFC (Apple File Conduit) protocol.
/// Requires ifuse for filesystem mounting, falls back to idevicebackup2 for sandbox access.
@MainActor
final class FileTransferManager: ObservableObject {

    @Published var currentPath: String = "/"
    @Published var entries: [FileEntry] = []
    @Published var isLoading = false
    @Published var isMounted = false
    @Published var lastError: String?

    private var mountPoint: String?

    struct FileEntry: Identifiable, Hashable {
        let id = UUID()
        let name: String
        let path: String
        let isDirectory: Bool
        let size: UInt64
        let modified: Date?

        var sizeString: String { size.formattedFileSize }
        var sfSymbol: String {
            if isDirectory { return "folder.fill" }
            let ext = (name as NSString).pathExtension.lowercased()
            switch ext {
            case "jpg", "jpeg", "png", "heic", "gif": return "photo"
            case "mp4", "mov", "m4v": return "video"
            case "mp3", "m4a", "aac", "wav": return "music.note"
            case "pdf": return "doc.richtext"
            case "txt", "md": return "doc.text"
            case "sqlite", "db": return "cylinder"
            case "plist", "xml", "json": return "curlybraces"
            default: return "doc"
            }
        }
    }

    // MARK: - Mount/Unmount

    /// Mount the device filesystem using ifuse.
    func mount(udid: String) async -> Bool {
        let tmpDir = NSTemporaryDirectory() + "phosphor-mount-\(udid.prefix(8))"
        let fm = FileManager.default

        do {
            try fm.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
        } catch {
            lastError = "Failed to create mount point: \(error.localizedDescription)"
            return false
        }

        let result = await Shell.runAsync("ifuse", arguments: ["-u", udid, tmpDir])
        if result.succeeded {
            mountPoint = tmpDir
            isMounted = true
            currentPath = "/"
            await browse(path: "/")
            return true
        } else {
            lastError = result.stderr.nilIfEmpty ?? "ifuse mount failed. Is ifuse installed?"
            return false
        }
    }

    /// Mount a specific app's container.
    func mountAppContainer(udid: String, bundleId: String) async -> Bool {
        let tmpDir = NSTemporaryDirectory() + "phosphor-app-\(bundleId.replacingOccurrences(of: ".", with: "-"))"
        let fm = FileManager.default

        do {
            try fm.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
        } catch {
            lastError = "Failed to create mount point"
            return false
        }

        let result = await Shell.runAsync(
            "ifuse",
            arguments: ["-u", udid, "--container", bundleId, tmpDir]
        )
        if result.succeeded {
            mountPoint = tmpDir
            isMounted = true
            currentPath = "/"
            await browse(path: "/")
            return true
        } else {
            lastError = result.stderr.nilIfEmpty ?? "Failed to mount app container"
            return false
        }
    }

    /// Unmount the device filesystem.
    func unmount() async {
        guard let mount = mountPoint else { return }

        // macOS uses umount, Linux uses fusermount
        let _ = await Shell.runAsync("umount", arguments: [mount])
        try? FileManager.default.removeItem(atPath: mount)

        mountPoint = nil
        isMounted = false
        entries = []
        currentPath = "/"
    }

    // MARK: - Browse

    /// List directory contents at the given path.
    func browse(path: String) async {
        guard let mount = mountPoint else { return }
        isLoading = true

        let fullPath = (mount as NSString).appendingPathComponent(path)
        let fm = FileManager.default

        do {
            let contents = try fm.contentsOfDirectory(atPath: fullPath)
            var items: [FileEntry] = []

            for name in contents.sorted() {
                let itemPath = (fullPath as NSString).appendingPathComponent(name)
                let relativePath = (path as NSString).appendingPathComponent(name)

                var isDir: ObjCBool = false
                fm.fileExists(atPath: itemPath, isDirectory: &isDir)

                let attrs = try? fm.attributesOfItem(atPath: itemPath)
                let size = (attrs?[.size] as? UInt64) ?? 0
                let modified = attrs?[.modificationDate] as? Date

                items.append(FileEntry(
                    name: name,
                    path: relativePath,
                    isDirectory: isDir.boolValue,
                    size: size,
                    modified: modified
                ))
            }

            // Directories first, then files, both alphabetical
            entries = items.sorted { lhs, rhs in
                if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
            currentPath = path
        } catch {
            lastError = error.localizedDescription
        }

        isLoading = false
    }

    /// Navigate into a subdirectory.
    func navigateInto(_ entry: FileEntry) async {
        guard entry.isDirectory else { return }
        await browse(path: entry.path)
    }

    /// Navigate up to parent directory.
    func navigateUp() async {
        let parent = (currentPath as NSString).deletingLastPathComponent
        await browse(path: parent.isEmpty ? "/" : parent)
    }

    // MARK: - File Operations

    /// Copy a file from the device to a local path.
    func copyToLocal(entry: FileEntry, destination: String) throws {
        guard let mount = mountPoint else { throw CocoaError(.fileNoSuchFile) }
        let source = (mount as NSString).appendingPathComponent(entry.path)
        let fm = FileManager.default

        let destDir = (destination as NSString).deletingLastPathComponent
        try fm.createDirectory(atPath: destDir, withIntermediateDirectories: true)

        if fm.fileExists(atPath: destination) {
            try fm.removeItem(atPath: destination)
        }
        try fm.copyItem(atPath: source, toPath: destination)
    }

    /// Copy a local file to the device.
    func copyToDevice(localPath: String, devicePath: String) throws {
        guard let mount = mountPoint else { throw CocoaError(.fileNoSuchFile) }
        let destination = (mount as NSString).appendingPathComponent(devicePath)
        let fm = FileManager.default

        let destDir = (destination as NSString).deletingLastPathComponent
        try fm.createDirectory(atPath: destDir, withIntermediateDirectories: true)

        if fm.fileExists(atPath: destination) {
            try fm.removeItem(atPath: destination)
        }
        try fm.copyItem(atPath: localPath, toPath: destination)
    }

    /// Delete a file on the device.
    func deleteFile(_ entry: FileEntry) throws {
        guard let mount = mountPoint else { throw CocoaError(.fileNoSuchFile) }
        let fullPath = (mount as NSString).appendingPathComponent(entry.path)
        try FileManager.default.removeItem(atPath: fullPath)
        entries.removeAll { $0.id == entry.id }
    }
}
