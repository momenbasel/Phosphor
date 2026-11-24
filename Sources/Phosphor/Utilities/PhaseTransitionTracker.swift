import Foundation
import OSLog

/// Tracks phase transitions with timestamps, durations, and metadata
/// Provides phase timeline visualization and duration analysis
final class PhaseTransitionTracker: @unchecked Sendable {

    // MARK: - State

    private var _transitions: [PhaseTransitionRecord] = []
    private var phaseStartTimes: [String: Date] = [:]
    private let logger = Logger(subsystem: "com.phosphor.backup", category: "phase-tracker")

    // MARK: - Public API

    /// Record a phase transition
    func recordTransition(from: String, to: String, metadata: [String: String]? = nil) {
        let now = Date()
        let fromStartTime = phaseStartTimes[from] ?? Date()
        let duration = from == to ? nil : now.timeIntervalSince(fromStartTime)

        let transition = PhaseTransitionRecord(
            from: BackupPhase(rawValue: from) ?? .detecting,
            to: BackupPhase(rawValue: to) ?? .detecting,
            timestamp: now,
            duration: from == to ? nil : duration,
            metadata: metadata
        )

        // Update tracking
        if from != to {
            phaseStartTimes[to] = Date()
        }

        _transitions.append(transition)

        logger.info("Phase transition: \(from) → \(to)\(duration.map { " (\($0.formattedDuration))" } ?? "")")
    }

    /// Get all recorded transitions
    var transitions: [PhaseTransitionRecord] {
        _transitions
    }

    /// Duration stats for a phase, derived from the recorded transitions.
    ///
    /// Each transition carries the time spent in its `from` phase, so summing
    /// those is the real per-phase total. Sampling elapsed-since-phase-start
    /// repeatedly and summing that (which the metrics collector did) counts
    /// every prior second of the phase again on each sample.
    func durationStats(for phase: String) -> PhaseDurationStats? {
        let matches = _transitions.filter { $0.from.rawValue == phase && $0.duration != nil }
        let durations = matches.compactMap(\.duration)
        guard !durations.isEmpty else { return nil }
        let total = durations.reduce(0, +)
        return PhaseDurationStats(
            phase: phase,
            totalDuration: total,
            transitionCount: durations.count,
            averageDuration: total / Double(durations.count),
            minDuration: durations.min(),
            maxDuration: durations.max(),
            lastOccurrence: matches.last?.timestamp
        )
    }

    /// Get all phase durations
    var allPhaseDurations: [String: TimeInterval] {
        var result: [String: TimeInterval] = [:]
        for transition in _transitions {
            guard let duration = transition.duration else { continue }
            result[transition.from.rawValue, default: 0] += duration
        }
        return result
    }

    /// Get total backup duration
    var totalDuration: TimeInterval {
        _transitions.compactMap(\.duration).reduce(0, +)
    }

    /// Reset tracker for new backup session
    func reset() {
        _transitions.removeAll()
        phaseStartTimes.removeAll()
    }
}