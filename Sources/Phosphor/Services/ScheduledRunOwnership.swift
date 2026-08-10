import Foundation

/// Per-schedule run ownership for asynchronous scheduler work.
/// A completion may clear state only when it still owns the identity it started.
struct ScheduledRunOwnership {
    private var runIDByIdentity: [String: UUID] = [:]

    var isEmpty: Bool { runIDByIdentity.isEmpty }

    func isOwned(identity: String) -> Bool {
        runIDByIdentity[identity] != nil
    }

    func owns(identity: String, runID: UUID) -> Bool {
        runIDByIdentity[identity] == runID
    }

    mutating func claim(identity: String, runID: UUID) -> Bool {
        guard runIDByIdentity[identity] == nil else { return false }
        runIDByIdentity[identity] = runID
        return true
    }

    @discardableResult
    mutating func finish(identity: String, runID: UUID) -> Bool {
        guard runIDByIdentity[identity] == runID else { return false }
        runIDByIdentity.removeValue(forKey: identity)
        return true
    }

    mutating func removeAll() {
        runIDByIdentity.removeAll()
    }
}
