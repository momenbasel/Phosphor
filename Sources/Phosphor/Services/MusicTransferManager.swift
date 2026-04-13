import Foundation

/// Transfers music, ringtones, and audio files to/from iOS devices via AFC.
/// Also extracts music from backups (MediaDomain/iTunes_Control/).
@MainActor
final class MusicTransferManager: ObservableObject {

    @Published var tracks: [MusicTrack] = []
    @Published var ringtones: [Ringtone] = []
    @Published var isLoading = false
    @Published var transferProgress: Double = 0
    @Published var lastError: String?

    struct MusicTrack: Identifiable, Hashable {
        let id: String
        let filename: String
        let relativePath: String
        let size: Int
        let domain: String

        var displayName: String {
            (filename as NSString).deletingPathExtension
        }

        var fileExtension: String {
            (filename as NSString).pathExtension.lowercased()
        }

        var isSupported: Bool {
            ["mp3", "m4a", "aac", "wav", "aiff", "alac", "flac"].contains(fileExtension)
        }
    }

    struct Ringtone: Identifiable, Hashable {
        let id: String
        let filename: String
        let relativePath: String
        let size: Int

        var displayName: String {
            (filename as NSString).deletingPathExtension
        }
    }

    // MARK: - From Backup

    func loadMusicFromBackup(backupPath: String) async {
        isLoading = true

        do {
            let manifest = try BackupManifest(backupPath: backupPath)

            // Music files in MediaDomain
            let mediaFiles = try manifest.files(inDomain: "MediaDomain")
            tracks = mediaFiles.filter { entry in
                entry.isFile && entry.relativePath.contains("iTunes_Control/Music/") &&
                ["mp3", "m4a", "aac", "wav", "aiff", "mp4"].contains(entry.fileExtension)
            }.map { entry in
                MusicTrack(
                    id: entry.id,
                    filename: entry.fileName,
                    relativePath: entry.relativePath,
                    size: entry.size,
                    domain: entry.domain
                )
            }

            // Ringtones
            let ringtoneFiles = try manifest.files(matching: "%Ringtones%")
            ringtones = ringtoneFiles.filter { $0.isFile && $0.fileExtension == "m4r" }.map { entry in
                Ringtone(
                    id: entry.id,
                    filename: entry.fileName,
                    relativePath: entry.relativePath,
                    size: entry.size
                )
            }

        } catch {
            lastError = error.localizedDescription
        }

        isLoading = false
    }

    // MARK: - Transfer to Device

    /// Copy audio files to device via AFC mount.
    func transferToDevice(
        files: [String],
        udid: String,
        destination: String = "/iTunes_Control/Music/"
    ) async -> Int {
        let tmpMount = NSTemporaryDirectory() + "phosphor-music-\(udid.prefix(8))"
        let fm = FileManager.default

        do {
            try fm.createDirectory(atPath: tmpMount, withIntermediateDirectories: true)
        } catch {
            lastError = "Failed to create mount point"
            return 0
        }

        // Mount media directory
        let mountResult = await Shell.runAsync("ifuse", arguments: ["-u", udid, tmpMount])
        guard mountResult.succeeded else {
            lastError = "Failed to mount device. Is ifuse installed?"
            return 0
        }

        defer {
            let _ = Shell.run("umount", arguments: [tmpMount])
            try? fm.removeItem(atPath: tmpMount)
        }

        // Create destination if needed
        let destPath = (tmpMount as NSString).appendingPathComponent(destination)
        try? fm.createDirectory(atPath: destPath, withIntermediateDirectories: true)

        var copied = 0
        for (index, file) in files.enumerated() {
            let filename = (file as NSString).lastPathComponent
            let dest = (destPath as NSString).appendingPathComponent(filename)

            do {
                if fm.fileExists(atPath: dest) { try fm.removeItem(atPath: dest) }
                try fm.copyItem(atPath: file, toPath: dest)
                copied += 1
            } catch {
                lastError = "Failed to copy \(filename): \(error.localizedDescription)"
            }

            transferProgress = Double(index + 1) / Double(files.count)
        }

        return copied
    }

    // MARK: - Extract from Backup

    func extractTracks(_ selectedTracks: [MusicTrack], from backupPath: String, to destination: String) async -> Int {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: destination, withIntermediateDirectories: true)

        do {
            let manifest = try BackupManifest(backupPath: backupPath)
            var extracted = 0

            for (index, track) in selectedTracks.enumerated() {
                let entry = BackupManifest.FileEntry(
                    id: track.id,
                    domain: track.domain,
                    relativePath: track.relativePath,
                    flags: 1,
                    size: track.size
                )

                let destPath = (destination as NSString).appendingPathComponent(track.filename)
                do {
                    try manifest.extractFile(entry, to: destPath)
                    extracted += 1
                } catch {
                    // Continue with others
                }

                transferProgress = Double(index + 1) / Double(selectedTracks.count)
            }

            return extracted
        } catch {
            lastError = error.localizedDescription
            return 0
        }
    }

    // MARK: - Ringtone Install

    /// Install a .m4r ringtone file on a connected device.
    func installRingtone(path: String, udid: String) async -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        guard ext == "m4r" else {
            lastError = "Ringtone must be .m4r format"
            return false
        }

        let tmpMount = NSTemporaryDirectory() + "phosphor-ringtone-\(udid.prefix(8))"
        let fm = FileManager.default
        try? fm.createDirectory(atPath: tmpMount, withIntermediateDirectories: true)

        let mountResult = await Shell.runAsync("ifuse", arguments: ["-u", udid, tmpMount])
        guard mountResult.succeeded else {
            lastError = "Failed to mount device"
            return false
        }

        defer {
            let _ = Shell.run("umount", arguments: [tmpMount])
            try? fm.removeItem(atPath: tmpMount)
        }

        let ringtonesDir = (tmpMount as NSString).appendingPathComponent("iTunes_Control/Ringtones")
        try? fm.createDirectory(atPath: ringtonesDir, withIntermediateDirectories: true)

        let filename = (path as NSString).lastPathComponent
        let dest = (ringtonesDir as NSString).appendingPathComponent(filename)

        do {
            if fm.fileExists(atPath: dest) { try fm.removeItem(atPath: dest) }
            try fm.copyItem(atPath: path, toPath: dest)
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }
}
