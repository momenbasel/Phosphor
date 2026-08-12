import Foundation

/// Clone-local cancellation state. This remains independent of BackupViewModel's
/// source-backup job so a late cancellation can still stop clone continuation.
struct CloneCancellationGate {
    private(set) var isCancellationRequested = false

    mutating func requestCancellation() {
        isCancellationRequested = true
    }

    mutating func reset() {
        isCancellationRequested = false
    }
}
