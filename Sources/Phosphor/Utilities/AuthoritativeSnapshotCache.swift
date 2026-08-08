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
    private var consecutiveNonAuthoritativeMerges = 0

    init(maxStaleAge: TimeInterval = 30, maxNonAuthoritativeMerges: Int = 3) {
        self.maxStaleAge = max(0, maxStaleAge)
        self.maxNonAuthoritativeMerges = max(0, maxNonAuthoritativeMerges)
    }

    var values: [Value] {
        orderedIDs.compactMap { valuesByID[$0] }
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
            && (lastAuthoritativeSnapshotAt.map {
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

        return values
    }

    mutating func reset() {
        valuesByID.removeAll()
        orderedIDs.removeAll()
        lastAuthoritativeSnapshotAt = nil
        consecutiveNonAuthoritativeMerges = 0
    }
}
