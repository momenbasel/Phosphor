import Foundation

public extension TimeInterval {
    var formattedDuration: String {
        let total = max(1, Int(rounded()))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return "\(h)h \(m)m \(s)s" }
        if m > 0 { return "\(m)m \(s)s" }
        return "\(s)s"
    }
}

// MARK: - Shared Observability Types

/// Phase of backup operation
public enum BackupPhase: String, CaseIterable, Codable, Sendable {
    case detecting = "detecting"
    case sanitization = "sanitization"
    case incrementalResume = "incrementalResume"
    case fullBackup = "fullBackup"
    case fallbackIdevicebackup2 = "fallbackIdevicebackup2"
    case finalization = "finalization"
    case verification = "verification"
    case completed = "completed"
    case failed = "failed"
    case cancelled = "cancelled"

    public var displayName: String {
        switch self {
        case .detecting: return "Detecting"
        case .sanitization: return "Sanitizing"
        case .incrementalResume: return "Resuming Backup"
        case .fullBackup: return "Full Backup"
        case .fallbackIdevicebackup2: return "Fallback Backup"
        case .finalization: return "Finalizing"
        case .verification: return "Verifying"
        case .completed: return "Completed"
        case .failed: return "Failed"
        case .cancelled: return "Paused"
        }
    }

    public var systemImage: String {
        switch self {
        case .detecting: return "magnifyingglass"
        case .sanitization: return "gearshape.2.fill"
        case .incrementalResume: return "arrow.clockwise.circle.fill"
        case .fullBackup: return "externaldrive.badge.plus"
        case .fallbackIdevicebackup2: return "exclamationmark.triangle.fill"
        case .finalization: return "arrow.triangle.2.circlepath.circle.fill"
        case .verification: return "checkmark.shield.fill"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .cancelled: return "pause.circle.fill"
        }
    }

    public var color: String {
        switch self {
        case .detecting: return "blue"
        case .sanitization: return "blue"
        case .incrementalResume: return "orange"
        case .fullBackup: return "brandAccent"
        case .fallbackIdevicebackup2: return "yellow"
        case .finalization: return "purple"
        case .verification: return "green"
        case .completed: return "green"
        case .failed: return "red"
        case .cancelled: return "orange"
        }
    }

    public var description: String {
        switch self {
        case .detecting: return "Detecting backup phase..."
        case .sanitization: return "Cleaning corrupted plists, checkpointing SQLite WAL"
        case .incrementalResume: return "Delta resume - transferring changed files only"
        case .fullBackup: return "Initial full backup of all selected domains"
        case .fallbackIdevicebackup2: return "Using idevicebackup2 fallback"
        case .finalization: return "Writing Manifest.db, sealing backup"
        case .verification: return "Verifying backup integrity"
        case .completed: return "Backup completed successfully"
        case .failed: return "Backup failed"
        case .cancelled: return "Backup paused - progress saved"
        }
    }
}

/// Record of a phase transition with timing and metadata
public struct PhaseTransitionRecord: Codable, Sendable {
    public let from: BackupPhase
    public let to: BackupPhase
    public let timestamp: Date
    public let duration: TimeInterval?
    public let metadata: [String: String]?

    public init(from: BackupPhase, to: BackupPhase, timestamp: Date, duration: TimeInterval?, metadata: [String: String]?) {
        self.from = from
        self.to = to
        self.timestamp = timestamp
        self.duration = duration
        self.metadata = metadata
    }

    public var description: String {
        "\(from.displayName) → \(to.displayName)\(duration.map { " (\($0.formattedDuration))" } ?? "")"
    }
}

/// Statistics for a phase duration
public struct PhaseDurationStats: Codable, Sendable {
    public let phase: String
    public let totalDuration: TimeInterval
    public let transitionCount: Int
    public let averageDuration: TimeInterval
    public let minDuration: TimeInterval?
    public let maxDuration: TimeInterval?
    public let lastOccurrence: Date?

    public var formattedTotal: String {
        totalDuration.formattedDuration
    }

    public var formattedAverage: String {
        averageDuration.formattedDuration
    }
}

public struct PhaseContext: Sendable {
    public var filesResumed: Int?
    public var resumeBaselineFraction: Double?
    public var sanitizationScanned: Int?
    public var sanitizationCleaned: Int?
    public var sanitizationWalCheckpointed: Bool?
    public var fallbackReason: String?
    public var currentDomain: String?
    public var terminalBytes: Int64?
    public var terminalFiles: Int?
    public var terminalDuration: TimeInterval?

    public init() {}
}

/// Metadata for a specific backup phase
public struct PhaseMetrics: Codable, Sendable {
    public let phase: BackupPhase
    public let timestamp: Date
    public let duration: TimeInterval
    public let progressFraction: Double
    public let progressPercent: Int
    public let eta: TimeInterval?
    public let speedBytesPerSec: Double?
    public let speedFilesPerSec: Double?
    public let bytesTransferred: Int64?
    public let totalBytes: Int64?
    public let filesTransferred: Int?
    public let totalFiles: Int?
    public let currentFile: String?
    public let phaseDetail: PhaseDetail?

    public init(
        phase: BackupPhase,
        timestamp: Date,
        duration: TimeInterval,
        progressFraction: Double,
        progressPercent: Int,
        eta: TimeInterval?,
        speedBytesPerSec: Double?,
        speedFilesPerSec: Double?,
        bytesTransferred: Int64?,
        totalBytes: Int64?,
        filesTransferred: Int?,
        totalFiles: Int?,
        currentFile: String?,
        phaseDetail: PhaseDetail?
    ) {
        self.phase = phase
        self.timestamp = timestamp
        self.duration = duration
        self.progressFraction = progressFraction
        self.progressPercent = progressPercent
        self.eta = eta
        self.speedBytesPerSec = speedBytesPerSec
        self.speedFilesPerSec = speedFilesPerSec
        self.bytesTransferred = bytesTransferred
        self.totalBytes = totalBytes
        self.filesTransferred = filesTransferred
        self.totalFiles = totalFiles
        self.currentFile = currentFile
        self.phaseDetail = phaseDetail
    }

    public var phaseDescription: String {
        phaseDetail?.description ?? phase.displayName
    }
}

/// Detailed phase-specific metadata
public enum PhaseDetail: Codable, Sendable {
    case sanitization(filesScanned: Int, filesCleaned: Int, walCheckpointed: Bool)
    case incrementalResume(filesResumed: Int, baselineFraction: Double)
    case fullBackup(bytesTransferred: Int64, totalBytes: Int64, currentDomain: String?)
    case fallbackIdevicebackup2(reason: String)
    case finalization(filesMoved: Int, totalFiles: Int, currentStage: String)
    case verification(bucketsScanned: Int, totalBuckets: Int, currentBucket: String?)
    case completed(totalBytes: Int64, totalFiles: Int, duration: TimeInterval)
    case failed(error: String)
    case cancelled(savedProgress: Double)

    public var description: String {
        switch self {
        case .sanitization(let filesScanned, let filesCleaned, let walCheckpointed):
            return "Scanned \(filesScanned) files, cleaned \(filesCleaned), WAL checkpointed: \(walCheckpointed)"
        case .incrementalResume(let filesResumed, let baseline):
            return "\(filesResumed.formatted()) files already present (baseline: \(Int(baseline * 100))%)"
        case .fullBackup(let bytesTransferred, let totalBytes, let domain):
            let domainStr = domain.map { " in \($0)" } ?? ""
            return "\(ByteCountFormatter.string(fromByteCount: bytesTransferred, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file))\(domainStr)"
        case .fallbackIdevicebackup2(let reason):
            return "Fallback: \(reason)"
        case .finalization(let filesMoved, let totalFiles, let stage):
            return "Finalizing: \(filesMoved)/\(totalFiles) files - \(stage)"
        case .verification(let scanned, let total, let bucket):
            let bucketStr = bucket.map { " - bucket \($0)" } ?? ""
            return "Verifying \(scanned)/\(total) buckets\(bucketStr)"
        case .completed(let bytes, let files, let duration):
            return "Completed: \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)), \(files) files in \(duration.formattedDuration)"
        case .failed(let error):
            return "Failed: \(error)"
        case .cancelled(let progress):
            return "Paused at \(Int(progress * 100))% - progress saved"
        }
    }
}