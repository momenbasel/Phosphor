import Foundation

/// Tracks which async callers still authorize a deduplicated per-device backup.
///
/// The queue owns one request per UDID. Additional callers wait on that same job.
/// Cancelling the owner may cancel the job only when no waiter still authorizes it;
/// cancelling a waiter never cancels another caller's request.
struct BackupRequestTracker {
    enum CancellationAction: Equatable {
        case cancelJob
        case detachRequest
        case notFound
    }

    private var ownerByUDID: [String: UUID] = [:]
    private var waiterIDsByUDID: [String: Set<UUID>] = [:]
    private var abandonedOwnerIDs: Set<UUID> = []

    mutating func registerOwner(_ requestID: UUID, udid: String) {
        ownerByUDID[udid] = requestID
        abandonedOwnerIDs.remove(requestID)
    }

    mutating func registerWaiter(_ requestID: UUID, udid: String) {
        waiterIDsByUDID[udid, default: []].insert(requestID)
    }

    mutating func cancel(_ requestID: UUID, udid: String) -> CancellationAction {
        if ownerByUDID[udid] == requestID {
            let hasWaiters = !(waiterIDsByUDID[udid]?.isEmpty ?? true)
            if hasWaiters {
                abandonedOwnerIDs.insert(requestID)
                return .detachRequest
            }
            return .cancelJob
        }

        guard waiterIDsByUDID[udid]?.remove(requestID) != nil else {
            return .notFound
        }
        if waiterIDsByUDID[udid]?.isEmpty == true {
            waiterIDsByUDID.removeValue(forKey: udid)
        }

        if let ownerID = ownerByUDID[udid],
           abandonedOwnerIDs.contains(ownerID),
           waiterIDsByUDID[udid] == nil {
            return .cancelJob
        }
        return .detachRequest
    }

    mutating func finish(udid: String) {
        if let ownerID = ownerByUDID.removeValue(forKey: udid) {
            abandonedOwnerIDs.remove(ownerID)
        }
        waiterIDsByUDID.removeValue(forKey: udid)
    }
}
