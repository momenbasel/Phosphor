import Foundation

/// Retains the last authoritative discovery snapshot across transient probe failures.
///
/// Successful scans replace the snapshot exactly, including with an empty result.
/// Failed or timed-out scans may refresh/add values they did observe, but cannot
/// immediately delete values merely because the incomplete scan omitted them.
/// The retention window is bounded so a permanently broken compatibility probe
/// cannot publish a disconnected device forever.
struct AuthoritativeSnapshotCache<Value> {
    private let maxStaleAge: TimeInterval
    private let maxNonAuthoritativeMerges: Int
    private var valuesByID: [String: Value] = [:]
    private var orderedIDs: [String] = []
    private var lastAuthoritativeSnapshotAt: Date?
    /// Stamped by every merge that produced entries, authoritative or not.
    /// Retention has to age against this rather than against the authoritative
    /// stamp: on a machine where one transport probe never succeeds inside its
    /// timeout, `lastAuthoritativeSnapshotAt` stays nil forever, so ageing
    /// against it made `retainedValues` reset on every routine poll and the
    /// compatibility-only device flickered - the exact bug this cache exists
    /// to prevent. Deletion authority still keys off the authoritative stamp.
    private var lastSnapshotAt: Date?
    private var consecutiveNonAuthoritativeMerges = 0

    init(maxStaleAge: TimeInterval = 30, maxNonAuthoritativeMerges: Int = 3) {
        self.maxStaleAge = max(0, maxStaleAge)
        self.maxNonAuthoritativeMerges = max(0, maxNonAuthoritativeMerges)
    }

    var values: [Value] {
        orderedIDs.compactMap { valuesByID[$0] }
    }

    /// Returns the retained snapshot without counting a skipped routine poll as
    /// another failed discovery. Expired entries are removed immediately even
    /// while the expensive compatibility probe is in backoff.
    mutating func retainedValues(now: Date = Date()) -> [Value] {
        guard let lastSnapshotAt,
              now.timeIntervalSince(lastSnapshotAt) <= maxStaleAge else {
            reset()
            return []
        }
        return values
    }

    mutating func merge(
        current: [(id: String, value: Value)],
        authoritative: Bool,
        now: Date = Date()
    ) -> [Value] {
        if authoritative {
            consecutiveNonAuthoritativeMerges = 0
        } else {
            consecutiveNonAuthoritativeMerges += 1
        }
        let canRetainPrevious = consecutiveNonAuthoritativeMerges <= maxNonAuthoritativeMerges
            && (lastSnapshotAt.map {
                now.timeIntervalSince($0) <= maxStaleAge
            } ?? false)
        if authoritative || !canRetainPrevious {
            valuesByID.removeAll(keepingCapacity: true)
            orderedIDs.removeAll(keepingCapacity: true)
        }
        if authoritative {
            lastAuthoritativeSnapshotAt = now
        }

        for (id, value) in current {
            if valuesByID[id] == nil {
                orderedIDs.append(id)
            }
            valuesByID[id] = value
        }

        if !valuesByID.isEmpty {
            lastSnapshotAt = now
        }

        return values
    }

    mutating func reset() {
        valuesByID.removeAll()
        orderedIDs.removeAll()
        lastAuthoritativeSnapshotAt = nil
        lastSnapshotAt = nil
        consecutiveNonAuthoritativeMerges = 0
    }
}
