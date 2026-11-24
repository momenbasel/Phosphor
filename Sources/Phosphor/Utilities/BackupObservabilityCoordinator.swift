import Foundation
import OSLog

/// Central coordinator for all backup observability components
/// Provides unified interface for metrics collection, phase tracking, and throughput analysis
@MainActor
final class BackupObservabilityCoordinator: ObservableObject {

    // MARK: - Published State

    @Published var currentPhase: BackupPhase = .detecting
    @Published var phaseMetrics: PhaseMetrics?
    @Published var throughputStats: ThroughputHistory.ThroughputStats
    @Published var predictiveETA: ThroughputHistory.PredictiveETA?
    @Published var phaseTransitions: [PhaseTransitionRecord] = []
    @Published var isStalled = false
    @Published var isQuiet = false
    @Published var isProcessAlive = true
    @Published var throughputTrend: ThroughputHistory.ThroughputTrend = .insufficient

    // MARK: - Private State

    private let logger = Logger(subsystem: "com.phosphor.backup", category: "observability")
    private let phaseTracker = PhaseTransitionTracker()
    private let throughputHistory = ThroughputHistory()

    // Phase tracking
    private var phaseStartTime = Date()
    private var lastSizeUpdate: Date?
    private var lastProgressUpdate = Date()

    // Process monitoring
    private var processAlive = true

    // Sampling
    // ponytail: nonisolated(unsafe) so deinit can invalidate the timer; all other
    // access stays on MainActor.
    nonisolated(unsafe) private var samplingTimer: Timer?
    private let samplingInterval: TimeInterval = 1.0

    // MARK: - Initialization

    init() {
        throughputStats = ThroughputHistory.ThroughputStats(
            currentBytesPerSecond: 0,
            averageBytesPerSecond: 0,
            peakBytesPerSecond: 0,
            minBytesPerSecond: 0,
            currentFilesPerSecond: nil,
            averageFilesPerSecond: nil,
            trend: .insufficient,
            samplesCount: 0,
            timeSpan: 0
        )
        predictiveETA = nil
        throughputTrend = .insufficient
    }

    nonisolated deinit {
        stopSampling()
    }

    // MARK: - Public API

    /// Start observing a backup operation
    func startObserving(udid: String, configuration: DeviceBackupConfiguration?) {
        logger.info("Starting observability for device \(udid)")

        // Reset state
        phaseTransitions = []
        throughputHistory.reset()
        currentPhase = .detecting
        phaseStartTime = Date()
        lastSizeUpdate = nil
        lastProgressUpdate = Date()
        processAlive = true
        isStalled = false
        isQuiet = false
        isProcessAlive = true

        // Start phase
        transitionToPhase(.detecting)

        // Start sampling
        startSampling()
    }

    /// Stop observing and invalidate the sampling timer
    func stopObserving() {
        stopSampling()
    }

    /// Update metrics from backup process
    func updateMetrics(
        phase: BackupPhase,
        progressFraction: Double?,
        bytesTransferred: Int64?,
        filesTransferred: Int?,
        totalBytes: Int64?,
        totalFiles: Int?,
        currentFile: String?,
        speedBytesPerSec: Double?,
        speedFilesPerSec: Double?,
        eta: TimeInterval?,
        isFinalizing: Bool,
        finalizationMetrics: FinalizationProgressTracker.Metrics?,
        context: PhaseContext = PhaseContext()
    ) {
        let now = Date()
        lastProgressUpdate = now
        processAlive = true

        // Detect phase change
        let newPhase = phase
        if newPhase != currentPhase {
            transitionToPhase(newPhase)
        }

        currentPhase = newPhase

        // Create phase metrics
        let metrics = PhaseMetrics(
            phase: currentPhase,
            timestamp: now,
            duration: Date().timeIntervalSince(phaseStartTime),
            progressFraction: progressFraction ?? 0,
            progressPercent: progressFraction.map { Int($0 * 100) } ?? 0,
            eta: eta,
            speedBytesPerSec: speedBytesPerSec,
            speedFilesPerSec: speedFilesPerSec,
            bytesTransferred: bytesTransferred,
            totalBytes: totalBytes,
            filesTransferred: filesTransferred,
            totalFiles: totalFiles,
            currentFile: currentFile,
            phaseDetail: buildPhaseDetail(
                finalizationMetrics: finalizationMetrics,
                bytesTransferred: bytesTransferred,
                totalBytes: totalBytes,
                context: context
            )
        )

        // Record throughput
        if let speed = speedBytesPerSec {
            throughputHistory.record(
                bytesPerSecond: speed,
                filesPerSecond: nil,
                phase: currentPhase.rawValue,
                bytesTransferred: 0,
                filesTransferred: nil
            )
        }

        // Update published state
        phaseMetrics = metrics
        throughputStats = throughputHistory.stats
        throughputTrend = throughputHistory.trend()
        // Only project an ETA when the transfer sizes are actually known and actual payload transfer has started.
        // With nil sizes or while still in pre-transfer manifest diffing, delta calculations yield 0 remaining,
        // producing a fabricated "0s" estimate for a backup that has barely started.
        if let totalBytes, let bytesTransferred, totalBytes > bytesTransferred, (speedBytesPerSec ?? 0) > 0 {
            predictiveETA = throughputHistory.predictiveETA(
                remainingBytes: totalBytes - bytesTransferred,
                currentPhase: currentPhase.rawValue
            )
        } else {
            predictiveETA = nil
        }

        if currentPhase == .completed || currentPhase == .cancelled || currentPhase == .failed {
            stopSampling()
            return
        }

        // Update stall detection
        updateStallDetection()

        // Update process liveness
        updateProcessLiveness()
    }

    /// Get exportable snapshot for debugging
    func exportSnapshot() -> BackupObservabilitySnapshot {
        BackupObservabilitySnapshot(
            timestamp: Date(),
            currentPhase: currentPhase,
            phaseMetrics: phaseMetrics,
            throughputStats: throughputStats,
            predictiveETA: predictiveETA,
            phaseTransitions: phaseTransitions,
            phaseDurations: phaseTracker.allPhaseDurations,
            throughputHistory: throughputHistory.allSamples,
            isStalled: isStalled,
            isQuiet: isQuiet,
            isProcessAlive: isProcessAlive,
            throughputTrend: throughputTrend
        )
    }

    // MARK: - Private Implementation

    private func transitionToPhase(_ newPhase: BackupPhase) {
        guard newPhase != currentPhase else { return }
        let previousPhase = currentPhase
        let now = Date()
        let duration = previousPhase != .detecting ? now.timeIntervalSince(phaseStartTime) : nil

        let transition = PhaseTransitionRecord(
            from: previousPhase,
            to: newPhase,
            timestamp: now,
            duration: duration,
            metadata: nil
        )

        phaseTransitions.append(transition)
        phaseTracker.recordTransition(from: previousPhase.rawValue, to: newPhase.rawValue)

        currentPhase = newPhase
        phaseStartTime = now

        if newPhase == .completed || newPhase == .cancelled || newPhase == .failed {
            stopSampling()
        }

        logger.info("Phase transition: \(previousPhase.displayName) → \(newPhase.displayName)\(duration.map { " (\($0.formattedDuration))" } ?? "")")
    }

    /// Detail for the current phase, using only data the coordinator actually
    /// has. It previously returned zero-filled cases for every phase, so a full
    /// backup announced "0 bytes of 0 bytes" in the row and to VoiceOver.
    /// Returning nil falls back to the phase name, which is honest.
    private func buildPhaseDetail(
        finalizationMetrics: FinalizationProgressTracker.Metrics?,
        bytesTransferred: Int64?,
        totalBytes: Int64?,
        context: PhaseContext
    ) -> PhaseDetail? {
        switch currentPhase {
        case .fullBackup:
            // Sizes come from the parsed tqdm progress line.
            guard let bytesTransferred, let totalBytes, totalBytes > 0 else { return nil }
            return .fullBackup(bytesTransferred: bytesTransferred, totalBytes: totalBytes, currentDomain: context.currentDomain)
        case .incrementalResume:
            guard let filesResumed = context.filesResumed,
                  let baseline = context.resumeBaselineFraction else { return nil }
            return .incrementalResume(filesResumed: filesResumed, baselineFraction: baseline)
        case .sanitization:
            guard let scanned = context.sanitizationScanned,
                  let cleaned = context.sanitizationCleaned,
                  let wal = context.sanitizationWalCheckpointed else { return nil }
            return .sanitization(filesScanned: scanned, filesCleaned: cleaned, walCheckpointed: wal)
        case .fallbackIdevicebackup2:
            guard let reason = context.fallbackReason, !reason.isEmpty else { return nil }
            return .fallbackIdevicebackup2(reason: reason)
        case .finalization:
            guard let metrics = finalizationMetrics else { return nil }
            return .finalization(filesMoved: metrics.filesMoved, totalFiles: metrics.totalFiles, currentStage: "\(metrics.stage)")
        case .verification:
            guard let metrics = finalizationMetrics,
                  case .verifying(let scanned, let total) = metrics.stage else { return nil }
            return .verification(bucketsScanned: scanned, totalBuckets: total, currentBucket: nil)
        case .completed:
            guard let bytes = context.terminalBytes,
                  let files = context.terminalFiles,
                  let duration = context.terminalDuration else { return nil }
            return .completed(totalBytes: bytes, totalFiles: files, duration: duration)
        case .failed, .cancelled, .detecting:
            return nil
        }
    }

    private func startSampling() {
        stopSampling()
        samplingTimer = Timer.scheduledTimer(withTimeInterval: samplingInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkStallAndLiveness()
            }
        }
    }

    nonisolated private func stopSampling() {
        samplingTimer?.invalidate()
        samplingTimer = nil
    }

    private func updateStallDetection() {
        let staleInterval = Date().timeIntervalSince(lastProgressUpdate)
        isStalled = staleInterval > 300 // 5 minutes
        isQuiet = staleInterval > 30 && !isStalled // 30 seconds quiet
    }

    private func updateProcessLiveness() {
        let staleInterval = Date().timeIntervalSince(lastProgressUpdate)
        isProcessAlive = processAlive && staleInterval < 60 // 60 seconds
    }

    private func checkStallAndLiveness() {
        if currentPhase == .completed || currentPhase == .cancelled || currentPhase == .failed {
            stopSampling()
            return
        }

        updateStallDetection()
        updateProcessLiveness()

        if isStalled {
            logger.warning("Backup stalled - no progress for 5+ minutes")
        }

        if !isProcessAlive {
            logger.warning("Backup process appears dead - no progress updates for 60+ seconds")
        }
    }
}

/// Snapshot of observability state for debugging/export
struct BackupObservabilitySnapshot: Codable, Sendable {
    let timestamp: Date
    let currentPhase: BackupPhase
    let phaseMetrics: PhaseMetrics?
    let throughputStats: ThroughputHistory.ThroughputStats
    let predictiveETA: ThroughputHistory.PredictiveETA?
    let phaseTransitions: [PhaseTransitionRecord]
    /// Real elapsed time per phase, summed from the transition timeline.
    let phaseDurations: [String: TimeInterval]
    let throughputHistory: [ThroughputHistory.VelocitySample]
    let isStalled: Bool
    let isQuiet: Bool
    let isProcessAlive: Bool
    let throughputTrend: ThroughputHistory.ThroughputTrend
}