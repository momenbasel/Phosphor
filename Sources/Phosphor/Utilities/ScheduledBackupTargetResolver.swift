import Foundation

/// Resolves a scheduled-backup target without depending on discovery ordering.
/// A legacy schedule without a saved target may continue when exactly one device
/// is eligible, but it must fail closed when multiple devices are available.
enum ScheduledBackupTargetResolver {
    struct Candidate: Equatable {
        let udid: String
        let preferNetwork: Bool
    }

    enum Resolution: Equatable {
        case target(Candidate)
        case noneAvailable
        case selectionRequired
    }

    static func resolve(
        candidates: [Candidate],
        targetUDID: String?
    ) -> Resolution {
        let uniqueCandidates = deduplicated(candidates)

        if let targetUDID {
            guard let target = uniqueCandidates.first(where: { $0.udid == targetUDID }) else {
                return .noneAvailable
            }
            return .target(target)
        }

        switch uniqueCandidates.count {
        case 0:
            return .noneAvailable
        case 1:
            return .target(uniqueCandidates[0])
        default:
            return .selectionRequired
        }
    }

    private static func deduplicated(_ candidates: [Candidate]) -> [Candidate] {
        var orderedUDIDs: [String] = []
        var candidatesByUDID: [String: Candidate] = [:]

        for candidate in candidates {
            if candidatesByUDID[candidate.udid] == nil {
                orderedUDIDs.append(candidate.udid)
            }
            if candidatesByUDID[candidate.udid]?.preferNetwork != false || !candidate.preferNetwork {
                candidatesByUDID[candidate.udid] = candidate
            }
        }

        return orderedUDIDs.compactMap { candidatesByUDID[$0] }
    }
}
