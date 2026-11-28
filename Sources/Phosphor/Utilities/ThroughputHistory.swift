import Foundation
import OSLog

/// Throughput history with velocity tracking and predictive ETA
/// Provides velocity history, trend analysis, and predictive ETA
final class ThroughputHistory: @unchecked Sendable {

    // MARK: - Types

    /// Single throughput measurement
    public struct VelocitySample: Codable, Sendable {
        public let timestamp: Date
        public let bytesPerSecond: Double
        public let filesPerSecond: Double?
        public let phase: String
        public let bytesTransferred: Int64
        public let filesTransferred: Int?

        public var formattedSpeed: String {
            ByteCountFormatter.string(fromByteCount: Int64(bytesPerSecond), countStyle: .file) + "/s"
        }
    }

    /// Throughput trend analysis
    public enum ThroughputTrend: String, Codable, Sendable {
        case accelerating = "accelerating"
        case stable = "stable"
        case decelerating = "decelerating"
        case insufficient = "insufficient"

        public var description: String {
            switch self {
            case .accelerating: return "Accelerating"
            case .stable: return "Stable"
            case .decelerating: return "Decelerating"
            case .insufficient: return "Insufficient data"
            }
        }

        public var icon: String {
            switch self {
            case .accelerating: return "arrow.up.right"
            case .stable: return "minus"
            case .decelerating: return "arrow.down.right"
            case .insufficient: return "questionmark"
            }
        }

        public var color: String {
            switch self {
            case .accelerating: return "green"
            case .stable: return "blue"
            case .decelerating: return "orange"
            case .insufficient: return "gray"
            }
        }
    }

    /// Predictive ETA result
    public struct PredictiveETA: Codable, Sendable {
        public let estimatedSeconds: TimeInterval
        public let confidence: Confidence
        public let basedOnSamples: Int
        public let throughputTrend: ThroughputTrend

        public enum Confidence: String, Codable, Sendable {
            case high = "high"
            case medium = "medium"
            case low = "low"
            case none = "none"
        }

        public var formattedETA: String {
            estimatedSeconds > 0 ? estimatedSeconds.formattedDuration : "Unknown"
        }
    }

    /// Throughput statistics summary
    public struct ThroughputStats: Codable, Sendable {
        public let currentBytesPerSecond: Double
        public let averageBytesPerSecond: Double
        public let peakBytesPerSecond: Double
        public let minBytesPerSecond: Double
        public let currentFilesPerSecond: Double?
        public let averageFilesPerSecond: Double?
        public let trend: ThroughputTrend
        public let samplesCount: Int
        public let timeSpan: TimeInterval

        public var formattedCurrent: String {
            ByteCountFormatter.string(fromByteCount: Int64(currentBytesPerSecond), countStyle: .file) + "/s"
        }

        public var formattedAverage: String {
            ByteCountFormatter.string(fromByteCount: Int64(averageBytesPerSecond), countStyle: .file) + "/s"
        }

        public var formattedPeak: String {
            ByteCountFormatter.string(fromByteCount: Int64(peakBytesPerSecond), countStyle: .file) + "/s"
        }
    }

    // MARK: - State

    private var samples: [VelocitySample] = []
    private let maxSamples: Int
    private let logger = Logger(subsystem: "com.phosphor.backup", category: "throughput")

    // MARK: - Public API

    init(maxSamples: Int = 300) {
        self.maxSamples = maxSamples
    }

    /// Record a velocity sample
    func record(_ sample: VelocitySample) {
        samples.append(sample)
        if samples.count > maxSamples {
            samples.removeFirst(samples.count - maxSamples)
        }
    }

    /// Record a throughput sample
    func record(bytesPerSecond: Double, filesPerSecond: Double?, phase: String, bytesTransferred: Int64, filesTransferred: Int?) {
        let sample = VelocitySample(
            timestamp: Date(),
            bytesPerSecond: bytesPerSecond,
            filesPerSecond: filesPerSecond,
            phase: phase,
            bytesTransferred: bytesTransferred,
            filesTransferred: filesTransferred
        )
        record(sample)
    }

    /// Get current throughput stats
    var stats: ThroughputStats {
        let samples = self.samples
        guard !samples.isEmpty else {
            return ThroughputStats(
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
        }

        let bytesPerSec = samples.map { $0.bytesPerSecond }
        let current = bytesPerSec.last ?? 0
        let average = bytesPerSec.reduce(0, +) / Double(bytesPerSec.count)
        let peak = bytesPerSec.max() ?? 0
        let min = bytesPerSec.min() ?? 0

        let filesPerSec = samples.compactMap { $0.filesPerSecond }
        let avgFiles = filesPerSec.isEmpty ? nil : filesPerSec.reduce(0, +) / Double(filesPerSec.count)
        let currentFiles = filesPerSec.last

        let timeSpan = samples.last!.timestamp.timeIntervalSince(samples.first!.timestamp)

        return ThroughputStats(
            currentBytesPerSecond: current,
            averageBytesPerSecond: average,
            peakBytesPerSecond: peak,
            minBytesPerSecond: min,
            currentFilesPerSecond: currentFiles,
            averageFilesPerSecond: avgFiles,
            trend: trend(),
            samplesCount: samples.count,
            timeSpan: timeSpan
        )
    }

    /// Get throughput trend
    func trend() -> ThroughputTrend {
        let recent = samples.suffix(30)
        guard recent.count >= 5 else { return .insufficient }

        let first = recent.first!.bytesPerSecond
        let last = recent.last!.bytesPerSecond
        let change = (last - first) / max(first, 1)

        if change > 0.15 { return .accelerating }
        if change < -0.15 { return .decelerating }
        return .stable
    }

    /// Get predictive ETA based on velocity history
    func predictiveETA(remainingBytes: Int64, currentPhase: String) -> PredictiveETA? {
        let relevantSamples = samples.suffix(60).filter { $0.phase == currentPhase }
        guard relevantSamples.count >= 5 else {
            return PredictiveETA(
                estimatedSeconds: 0,
                confidence: .none,
                basedOnSamples: samples.count,
                throughputTrend: trend()
            )
        }

        // Weighted average with exponential decay
        let samples = relevantSamples
        let weights = (1...samples.count).map { Double($0) }
        let totalWeight = weights.reduce(0, +)
        let weightedSum = zip(samples, weights).reduce(0) { sum, pair in
            sum + pair.0.bytesPerSecond * pair.1
        }
        let weightedAvg = weightedSum / totalWeight

        guard weightedAvg > 0 else {
            return PredictiveETA(
                estimatedSeconds: 0,
                confidence: .none,
                basedOnSamples: samples.count,
                throughputTrend: trend()
            )
        }

        let estimatedSeconds = TimeInterval(Double(remainingBytes) / weightedAvg)

        // Confidence based on sample count and variance
        let mean = samples.map { $0.bytesPerSecond }.reduce(0, +) / Double(samples.count)
        let variance = samples.map { ($0.bytesPerSecond - mean).magnitude }.reduce(0, +) / Double(samples.count)
        let cv = variance / max(mean, 1)
        let confidence: PredictiveETA.Confidence = cv < 0.2 ? .high : cv < 0.5 ? .medium : .low

        return PredictiveETA(
            estimatedSeconds: estimatedSeconds,
            confidence: confidence,
            basedOnSamples: samples.count,
            throughputTrend: trend()
        )
    }

    /// Clear history
    func reset() {
        samples.removeAll()
    }

    /// Get all samples
    var allSamples: [VelocitySample] {
        samples
    }
}