import Foundation

/// Transfers music, ringtones, and audio files to/from iOS devices via AFC.
/// Primary: pymobiledevice3 AFC push/pull. Fallback: ifuse mount.
@MainActor
final class MusicTransferManager: ObservableObject {

    @Published var tracks: [MusicTrack] = []
    @Published var ringtones: [Ringtone] = []
    @Published var isLoading = false
    @Published var transferProgress: Double = 0
    @Published var lastError: String?

    struct MusicTrack: Identifiable, Hashable, Sendable {
        let id: String
        let filename: String
        let relativePath: String
        let size: Int
        let domain: String

        var displayName: String { (filename as NSString).deletingPathExtension }
        var fileExtension: String { (filename as NSString).pathExtension.lowercased() }
        var isSupported: Bool {
            ["mp3", "m4a", "aac", "wav", "aiff", "alac", "flac"].contains(fileExtension)
        }
    }

    struct Ringtone: Identifiable, Hashable {
        let id: String
        let filename: String
        let relativePath: String
        let size: Int

        var displayName: String { (filename as NSString).deletingPathExtension }
    }

    // MARK: - From Backup

    func loadMusicFromBackup(backupPath: String) async {
        isLoading = true

        do {
            let manifest = try BackupManifest(backupPath: backupPath)

            let mediaFiles = try manifest.files(inDomain: "MediaDomain")
            tracks = manifest.resolvingSizes(for: mediaFiles.filter { entry in
                entry.isFile && entry.relativePath.contains("iTunes_Control/Music/") &&
                ["mp3", "m4a", "aac", "wav", "aiff", "mp4"].contains(entry.fileExtension)
            }).map { entry in
                MusicTrack(id: entry.id, filename: entry.fileName, relativePath: entry.relativePath, size: entry.size, domain: entry.domain)
            }

            let ringtoneFiles = try manifest.files(matching: "%Ringtones%")
            ringtones = manifest.resolvingSizes(for: ringtoneFiles.filter { $0.isFile && $0.fileExtension == "m4r" }).map { entry in
                Ringtone(id: entry.id, filename: entry.fileName, relativePath: entry.relativePath, size: entry.size)
            }
        } catch {
            lastError = error.localizedDescription
        }

        isLoading = false
    }

    // MARK: - Transfer to Device

    /// Copy audio files to device via pymobiledevice3 AFC push (primary) or ifuse (fallback).
    func transferToDevice(
        files: [String],
        udid: String,
        destination: String = "/iTunes_Control/Music/"
    ) async -> Int {
        // Primary: pymobiledevice3 AFC push
        if PyMobileDevice.available() {
            var copied = 0
            for (index, file) in files.enumerated() {
                let filename = (file as NSString).lastPathComponent
                let remotePath = "\(destination)\(filename)"
                let success = await PyMobileDevice.afcPush(localPath: file, remotePath: remotePath, udid: udid)
                if success { copied += 1 }
                transferProgress = Double(index + 1) / Double(files.count)
            }
            return copied
        }

        guard Shell.which("ifuse") != nil else {
            lastError = "Failed to access device music storage. Install or repair pymobiledevice3 with: pipx install pymobiledevice3"
            return 0
        }

        // Optional legacy fallback: ifuse mount
        let tmpMount = NSTemporaryDirectory() + "phosphor-music-\(udid.prefix(8))"
        let fm = FileManager.default
        try? fm.createDirectory(atPath: tmpMount, withIntermediateDirectories: true)

        let mountResult = await Shell.runAsync("ifuse", arguments: ["-u", udid, tmpMount])
        guard mountResult.succeeded else {
            lastError = "Failed to mount device. Install pymobiledevice3: pipx install pymobiledevice3"
            return 0
        }

        defer {
            let _ = Shell.run("umount", arguments: [tmpMount])
            try? fm.removeItem(atPath: tmpMount)
        }

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

    struct ExtractionOutcome: Sendable {
        let extracted: Int
        let total: Int
        let processed: Int
        let cancelled: Bool
        let lastError: String?
    }

    func extractTracks(
        _ selectedTracks: [MusicTrack],
        from backupPath: String,
        to destination: String
    ) async -> ExtractionOutcome {
        lastError = nil
        transferProgress = 0
        let worker = Task.detached(priority: .userInitiated) {
            Self.performExtraction(selectedTracks, from: backupPath, to: destination)
        }
        let outcome = await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
        lastError = outcome.lastError
        if outcome.total > 0 {
            transferProgress = Double(outcome.processed) / Double(outcome.total)
        }
        return outcome
    }

    private nonisolated static func performExtraction(
        _ selectedTracks: [MusicTrack],
        from backupPath: String,
        to destination: String
    ) -> ExtractionOutcome {
        let fm = FileManager.default
        do {
            try fm.createDirectory(atPath: destination, withIntermediateDirectories: true)
        } catch {
            return ExtractionOutcome(
                extracted: 0, total: selectedTracks.count, processed: 0, cancelled: false,
                lastError: "Could not prepare the destination folder: \(error.localizedDescription)"
            )
        }

        do {
            try Task.checkCancellation()
            let manifest = try BackupManifest(backupPath: backupPath)
            let destinationURL = URL(fileURLWithPath: destination, isDirectory: true)
            var extracted = 0
            var processed = 0
            var lastFailure: String?

            for track in selectedTracks {
                let entry = BackupManifest.FileEntry(
                    id: track.id, domain: track.domain, relativePath: track.relativePath,
                    flags: 1, size: track.size
                )
                do {
                    try Task.checkCancellation()
                    _ = try CollisionSafeFilePublisher.publish(
                        preferredFilename: track.filename,
                        in: destinationURL
                    ) { staging in
                        try Task.checkCancellation()
                        try manifest.extractFile(entry, to: staging.path)
                        try Task.checkCancellation()
                    }
                    extracted += 1
                } catch is CancellationError {
                    return ExtractionOutcome(
                        extracted: extracted, total: selectedTracks.count, processed: processed,
                        cancelled: true, lastError: "Music extraction was cancelled."
                    )
                } catch {
                    lastFailure = "Failed to extract \(track.filename): \(error.localizedDescription)"
                }
                processed += 1
            }
            return ExtractionOutcome(
                extracted: extracted, total: selectedTracks.count, processed: processed,
                cancelled: false, lastError: lastFailure
            )
        } catch is CancellationError {
            return ExtractionOutcome(
                extracted: 0, total: selectedTracks.count, processed: 0,
                cancelled: true, lastError: "Music extraction was cancelled."
            )
        } catch {
            return ExtractionOutcome(
                extracted: 0, total: selectedTracks.count, processed: 0,
                cancelled: false, lastError: error.localizedDescription
            )
        }
    }

    // MARK: - Ringtone Install

    /// Install a .m4r ringtone via pymobiledevice3 AFC push (primary) or ifuse (fallback).
    func installRingtone(path: String, udid: String) async -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        guard ext == "m4r" else {
            lastError = "Ringtone must be .m4r format"
            return false
        }

        let filename = (path as NSString).lastPathComponent

        // Primary: pymobiledevice3 AFC push
        if PyMobileDevice.available() {
            return await PyMobileDevice.afcPush(
                localPath: path,
                remotePath: "/iTunes_Control/Ringtones/\(filename)",
                udid: udid
            )
        }

        guard Shell.which("ifuse") != nil else {
            lastError = "Failed to access device ringtone storage. Install or repair pymobiledevice3 with: pipx install pymobiledevice3"
            return false
        }

        // Optional legacy fallback: ifuse mount
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

    // MARK: - Ringtone Creator

    /// Convert any audio file to .m4r ringtone format using macOS afconvert.
    func createRingtone(from inputPath: String, outputDir: String) async -> String? {
        let inputName = ((inputPath as NSString).lastPathComponent as NSString).deletingPathExtension
        let outputPath = (outputDir as NSString).appendingPathComponent("\(inputName).m4r")

        let result = await Shell.runAsync("afconvert", arguments: [
            "-f", "m4af", "-d", "aac", "-b", "256000",
            inputPath, outputPath
        ], timeout: 60)

        if result.succeeded { return outputPath }
        lastError = result.stderr.nilIfEmpty ?? "Failed to convert audio"
        return nil
    }
}
