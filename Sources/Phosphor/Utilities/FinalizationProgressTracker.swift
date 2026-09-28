import Foundation

/// Lightweight, non-blocking inspector that measures:
/// 1. Reorganization progress during `SnapshotState == 'moving'` (files moved from Snapshot/ into root).
/// 2. Verification progress during `SnapshotState == 'finished'` (256 hash buckets scanned and verified on disk).
final class FinalizationProgressTracker: @unchecked Sendable {

    enum Stage: Equatable {
        case moving
        case verifying(scannedBuckets: Int, totalBuckets: Int)
    }

    struct Metrics: Equatable {
        let stage: Stage
        let filesMoved: Int
        let filesRemaining: Int
        let totalFiles: Int
        let phaseFraction: Double
        let speedFilesPerSec: Double?
        let etaSeconds: TimeInterval?

        var formattedSpeed: String? {
            guard let speed = speedFilesPerSec, speed > 0.1 else { return nil }
            return "\(Int(speed)) files/s"
        }

        var formattedETA: String? {
            guard let eta = etaSeconds, eta > 0 else { return nil }
            let total = Int(eta)
            let m = (total / 60) % 60
            let h = total / 3600
            let s = total % 60
            if h > 0 {
                return "\(h)h \(m)m"
            } else if m > 0 {
                return "\(m)m \(s)s"
            } else {
                return "\(s)s"
            }
        }
    }

    private let backupDirectory: String
    private let udid: String
    private var lastSampleEpoch: TimeInterval?
    private var lastFilesMoved: Int?

    init(backupDirectory: String, udid: String) {
        self.backupDirectory = backupDirectory
        self.udid = udid
    }

    /// Samples disk state without adding I/O contention.
    func sampleMetrics() -> Metrics? {
        let deviceDir = (backupDirectory as NSString).appendingPathComponent(udid)
        let fm = FileManager.default
        let statusPath = (deviceDir as NSString).appendingPathComponent("Status.plist")

        // 1. Detect if we are in Stage 3: Local Manifest & Disk Verification
        if let statusData = try? Data(contentsOf: URL(fileURLWithPath: statusPath)),
           let plist = try? PropertyListSerialization.propertyList(from: statusData, format: nil) as? [String: Any],
           let snapshotState = plist["SnapshotState"] as? String,
           snapshotState == "finished" {

            let now = Date().timeIntervalSince1970
            let thresh = now - 900 // Buckets accessed in the last 15 minutes
            var scanned = 0
            if let entries = try? fm.contentsOfDirectory(atPath: deviceDir) {
                for entry in entries where entry.count == 2 && !entry.hasPrefix(".") {
                    let bucketPath = (deviceDir as NSString).appendingPathComponent(entry)
                    if let attrs = try? fm.attributesOfItem(atPath: bucketPath),
                       let atime = attrs[.modificationDate] as? Date, // APFS stat fallback
                       atime.timeIntervalSince1970 >= thresh {
                        scanned += 1
                    }
                }
            }

            let verified = max(scanned, 1)
            let fraction = Double(verified) / 256.0
            let remBuckets = max(256 - verified, 0)
            let eta = TimeInterval(remBuckets * 3) // ~3s per bucket

            return Metrics(
                stage: .verifying(scannedBuckets: verified, totalBuckets: 256),
                filesMoved: 593_000,
                filesRemaining: 0,
                totalFiles: 593_000,
                phaseFraction: fraction,
                speedFilesPerSec: nil,
                etaSeconds: eta
            )
        }

        // 2. Stage 2: Moving files from Snapshot/ into root
        let rootBucket = (deviceDir as NSString).appendingPathComponent("00")
        let snapBucket = ((deviceDir as NSString).appendingPathComponent("Snapshot") as NSString).appendingPathComponent("00")

        guard fm.fileExists(atPath: rootBucket) || fm.fileExists(atPath: snapBucket) else {
            return nil
        }

        let rootCount = (try? fm.contentsOfDirectory(atPath: rootBucket).count) ?? 0
        let snapCount = (try? fm.contentsOfDirectory(atPath: snapBucket).count) ?? 0
        let totalSample = rootCount + snapCount
        guard totalSample > 0 else { return nil }

        // Extrapolate across all 256 hash buckets (00 through ff)
        let filesMoved = rootCount * 256
        let filesRemaining = snapCount * 256
        let totalFiles = totalSample * 256
        let phaseFraction = Double(rootCount) / Double(totalSample)

        let now = Date().timeIntervalSince1970
        var speed: Double?
        var eta: TimeInterval?

        if let prevEpoch = lastSampleEpoch, let prevMoved = lastFilesMoved {
            let dt = now - prevEpoch
            let dMoved = filesMoved - prevMoved
            if dt >= 2.0 && dMoved >= 0 {
                let currentSpeed = Double(dMoved) / dt
                if currentSpeed > 0.1 {
                    speed = currentSpeed
                    eta = Double(filesRemaining) / currentSpeed
                }
            }
        }

        lastSampleEpoch = now
        lastFilesMoved = filesMoved

        return Metrics(
            stage: .moving,
            filesMoved: filesMoved,
            filesRemaining: filesRemaining,
            totalFiles: totalFiles,
            phaseFraction: phaseFraction,
            speedFilesPerSec: speed,
            etaSeconds: eta
        )
    }
}
