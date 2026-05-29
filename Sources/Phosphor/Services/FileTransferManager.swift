import Foundation

/// File transfer between Mac and iOS device using AFC (Apple File Conduit) protocol.
/// Primary: pymobiledevice3 AFC (no FUSE/ifuse needed, works on macOS Sonoma+).
/// Fallback: ifuse mount (requires macFUSE).
@MainActor
final class FileTransferManager: ObservableObject {

    @Published var currentPath: String = "/"
    @Published var entries: [FileEntry] = []
    @Published var isLoading = false
    @Published var isMounted = false
    @Published var lastError: String?

    /// Device UDID for AFC operations (pymobiledevice3 mode).
    private var deviceUDID: String?
    /// Local mount point (ifuse legacy mode only).
    private var mountPoint: String?
    /// Whether using pymobiledevice3 AFC (true) or ifuse mount (false).
    private var usesAFC = false

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

    // MARK: - Connect / Disconnect

    /// Connect to device filesystem via pymobiledevice3 AFC (primary) or ifuse (fallback).
    /// Verifies access by probing the root directory before declaring the mount successful.
    func mount(udid: String) async -> Bool {
        lastError = nil
        isLoading = true
        defer { isLoading = false }

        // Primary: pymobiledevice3 AFC - stateless, but probe root to confirm device access.
        if PyMobileDevice.available() {
            let probe = await PyMobileDevice.afcListRaw(path: "/", udid: udid)
            if !probe.succeeded {
                let detail = probe.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                lastError = """
                AFC access failed. Unlock the iPhone, tap 'Trust' if prompted, then retry.

                Verify manually:
                  pymobiledevice3 afc ls / --udid \(udid)
                \(detail.isEmpty ? "" : "\nDetails: \(detail)")
                """
                deviceUDID = nil
                isMounted = false
                return false
            }

            let items = probe.entries
            deviceUDID = udid
            usesAFC = true
            currentPath = "/"
            entries = items
                .filter { $0 != "." && $0 != ".." }
                .map { FileEntry(name: $0, path: "/\($0)", isDirectory: true, size: 0, modified: nil) }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            isMounted = true
            return true
        }

        guard Shell.which("ifuse") != nil else {
            lastError = "Could not access device filesystem. Install or repair pymobiledevice3 with: pipx install pymobiledevice3"
            return false
        }

        // Optional legacy fallback: ifuse mount
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
            deviceUDID = udid
            usesAFC = false
            isMounted = true
            currentPath = "/"
            await browse(path: "/")
            return true
        }

        let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        lastError = """
        Could not access device filesystem.

        Install pymobiledevice3:
          pipx upgrade pymobiledevice3

        On macOS, ifuse is not installed by Homebrew; install/repair pymobiledevice3 instead.
        \(stderr.isEmpty ? "" : "\nifuse: \(stderr)")
        """
        return false
    }

    /// Mount a specific app's container.
    func mountAppContainer(udid: String, bundleId: String) async -> Bool {
        // pymobiledevice3: apps afc <bundleId>
        if PyMobileDevice.available() {
            deviceUDID = udid
            usesAFC = true
            isMounted = true
            currentPath = "/"
            // For app containers, we use a different AFC method
            await browseAppContainer(bundleId: bundleId, path: "/")
            return true
        }

        guard Shell.which("ifuse") != nil else {
            lastError = "Failed to access app container. Install or repair pymobiledevice3 with: pipx install pymobiledevice3"
            return false
        }

        // Optional legacy fallback: ifuse --container
        let tmpDir = NSTemporaryDirectory() + "phosphor-app-\(bundleId.replacingOccurrences(of: ".", with: "-"))"
        let fm = FileManager.default
        try? fm.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)

        let result = await Shell.runAsync("ifuse", arguments: ["-u", udid, "--container", bundleId, tmpDir])
        if result.succeeded {
            mountPoint = tmpDir
            deviceUDID = udid
            usesAFC = false
            isMounted = true
            currentPath = "/"
            await browse(path: "/")
            return true
        }

        lastError = "Failed to access app container"
        return false
    }

    /// Disconnect from device filesystem.
    func unmount() async {
        if let mount = mountPoint, !usesAFC {
            let _ = await Shell.runAsync("umount", arguments: [mount])
            try? FileManager.default.removeItem(atPath: mount)
        }
        mountPoint = nil
        deviceUDID = nil
        isMounted = false
        usesAFC = false
        entries = []
        currentPath = "/"
    }

    // MARK: - Browse

    /// List directory contents at the given path.
    func browse(path: String) async {
        isLoading = true

        if usesAFC {
            await browseViaAFC(path: path)
        } else {
            await browseViaMount(path: path)
        }

        isLoading = false
    }

    /// Browse via pymobiledevice3 AFC ls.
    private func browseViaAFC(path: String) async {
        guard let udid = deviceUDID else { return }
        let items = await PyMobileDevice.afcList(path: path, udid: udid)

        var fileEntries: [FileEntry] = []
        for name in items {
            guard name != "." && name != ".." else { continue }
            let itemPath = path == "/" ? "/\(name)" : "\(path)/\(name)"

            // Check if directory by trying to list it
            let subItems = await PyMobileDevice.afcList(path: itemPath, udid: udid)
            let isDir = !subItems.isEmpty && subItems.first != name

            fileEntries.append(FileEntry(
                name: name,
                path: itemPath,
                isDirectory: isDir,
                size: 0,
                modified: nil
            ))
        }

        entries = fileEntries.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
        currentPath = path
    }

    /// Browse app container via pymobiledevice3.
    private func browseAppContainer(bundleId: String, path: String) async {
        guard let udid = deviceUDID else { return }
        let result = await PyMobileDevice.runAsync(["apps", "afc", bundleId, "ls", path, "--udid", udid])
        guard result.succeeded else { return }

        var fileEntries: [FileEntry] = []
        for name in result.output.components(separatedBy: "\n") {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed != ".", trimmed != ".." else { continue }
            let itemPath = path == "/" ? "/\(trimmed)" : "\(path)/\(trimmed)"

            fileEntries.append(FileEntry(
                name: trimmed,
                path: itemPath,
                isDirectory: false, // Can't easily determine without another call
                size: 0,
                modified: nil
            ))
        }

        entries = fileEntries
        currentPath = path
    }

    /// Browse via ifuse mount (legacy).
    private func browseViaMount(path: String) async {
        guard let mount = mountPoint else { return }

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

            entries = items.sorted { lhs, rhs in
                if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
            currentPath = path
        } catch {
            lastError = error.localizedDescription
        }
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
    func copyToLocal(entry: FileEntry, destination: String) async throws {
        if usesAFC {
            let fm = FileManager.default
            let destDir = (destination as NSString).deletingLastPathComponent
            try fm.createDirectory(atPath: destDir, withIntermediateDirectories: true)

            let success = await PyMobileDevice.afcPull(
                remotePath: entry.path,
                localPath: destination,
                udid: deviceUDID
            )
            if !success { throw CocoaError(.fileWriteUnknown) }
        } else {
            guard let mount = mountPoint else { throw CocoaError(.fileNoSuchFile) }
            let source = (mount as NSString).appendingPathComponent(entry.path)
            let fm = FileManager.default
            let destDir = (destination as NSString).deletingLastPathComponent
            try fm.createDirectory(atPath: destDir, withIntermediateDirectories: true)
            if fm.fileExists(atPath: destination) { try fm.removeItem(atPath: destination) }
            try fm.copyItem(atPath: source, toPath: destination)
        }
    }

    /// Copy a local file to the device.
    func copyToDevice(localPath: String, devicePath: String) async throws {
        if usesAFC {
            let success = await PyMobileDevice.afcPush(
                localPath: localPath,
                remotePath: devicePath,
                udid: deviceUDID
            )
            if !success { throw CocoaError(.fileWriteUnknown) }
        } else {
            guard let mount = mountPoint else { throw CocoaError(.fileNoSuchFile) }
            let destination = (mount as NSString).appendingPathComponent(devicePath)
            let fm = FileManager.default
            let destDir = (destination as NSString).deletingLastPathComponent
            try fm.createDirectory(atPath: destDir, withIntermediateDirectories: true)
            if fm.fileExists(atPath: destination) { try fm.removeItem(atPath: destination) }
            try fm.copyItem(atPath: localPath, toPath: destination)
        }
    }

    /// Delete a file on the device.
    func deleteFile(_ entry: FileEntry) async throws {
        if usesAFC {
            let success = await PyMobileDevice.afcRemove(path: entry.path, udid: deviceUDID)
            if !success { throw CocoaError(.fileWriteUnknown) }
        } else {
            guard let mount = mountPoint else { throw CocoaError(.fileNoSuchFile) }
            let fullPath = (mount as NSString).appendingPathComponent(entry.path)
            try FileManager.default.removeItem(atPath: fullPath)
        }
        entries.removeAll { $0.id == entry.id }
    }
}
